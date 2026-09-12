#!/usr/bin/env bash
# Run once with sudo on home-server. Keeps the host awake when idle or closed.
# No disk, package, SSH authentication, or network settings are changed.
set -euo pipefail

if [[ $(id -u) -ne 0 ]]; then
  echo 'Run this script with sudo on the Ubuntu laptop.' >&2
  exit 1
fi
if [[ $(hostname) != home-server || ! -f /etc/os-release ]]; then
  echo 'This script is intended only for the Ubuntu laptop named home-server.' >&2
  exit 1
fi
if [[ $(systemctl show systemd-logind.service --property=CanReload --value) != yes ]]; then
  echo 'logind does not support reload; no changes were made.' >&2
  exit 1
fi

config=/etc/systemd/logind.conf.d/90-modicum-home-server.conf
backup_dir=/var/backups/modicum-power
targets=(sleep.target suspend.target hibernate.target hybrid-sleep.target suspend-then-hibernate.target)
install -d -m 0700 "$backup_dir"

# Save the original state once, so rerunning does not overwrite rollback evidence.
if [[ ! -f "$backup_dir/prepared" ]]; then
  if [[ -e "$config" ]]; then
    cp -p "$config" "$backup_dir/logind.conf.before"
  else
    touch "$backup_dir/logind.conf.did-not-exist"
  fi
  for target in "${targets[@]}"; do
    state=$(systemctl is-enabled "$target" 2>/dev/null || true)
    printf '%s %s\n' "$target" "$state" >> "$backup_dir/targets.before"
  done
  touch "$backup_dir/prepared"
fi

install -d -m 0755 /etc/systemd/logind.conf.d
cat > "$config" <<'CONF'
# Modicum home server: maintain availability with the lid closed.
[Login]
HandleLidSwitch=ignore
HandleLidSwitchExternalPower=ignore
HandleLidSwitchDocked=ignore
IdleAction=ignore
CONF
chmod 0644 "$config"

# Blocking these targets also prevents desktop or manual sleep requests.
# Normal shutdown, reboot, and hardware protections remain available.
systemctl mask "${targets[@]}"
systemctl reload systemd-logind.service

for target in "${targets[@]}"; do
  if [[ $(systemctl is-enabled "$target" 2>/dev/null || true) != masked ]]; then
    printf 'Verification failed: %s is not masked.\n' "$target" >&2
    exit 1
  fi
done
systemctl is-active --quiet systemd-logind.service
systemctl is-active --quiet ssh.service
printf '\nPower setup complete: sleep is blocked and closing the lid is ignored.\n'
printf 'SSH remains active. Original system settings are in %s.\n' "$backup_dir"
