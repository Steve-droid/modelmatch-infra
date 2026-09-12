#!/usr/bin/env bash
# Fresh-host installation only. Existing clusters/configuration are never adopted.
set -euo pipefail
export LC_ALL=C
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
cd -- "$(dirname -- "${BASH_SOURCE[0]}")"
source_dir=$PWD
die() { echo "STOP: $*" >&2; exit 1; }
mode=${1:---check}
[[ $mode == --check || $mode == --apply ]] || die 'Use --check or --apply.'
[[ $(hostname) == home-server && $(uname -m) == x86_64 ]] || die 'Wrong host.'
[[ $(stat -fc %T /sys/fs/cgroup) == cgroup2fs ]] || die 'cgroup v2 required.'
ip -4 -o address show dev eno1 | grep -q '192.168.1.93/24' || die 'LAN address changed; review config.'
[[ $(findmnt -no UUID /) == 9ce972e8-f060-45fc-97fe-296664de6a7c ]] || die 'Unexpected root filesystem.'
for tool in curl python3 ufw iptables ip6tables nft nmcli systemctl modprobe sha256sum; do
  command -v "$tool" >/dev/null || die "Missing $tool."
done
for path in /etc/rancher/k3s /var/lib/rancher/k3s /etc/kubernetes /var/lib/kubelet \
  /etc/systemd/system/k3s.service /usr/local/bin/k3s \
  /etc/sysctl.d/90-driftplain-k3s.conf /etc/modules-load.d/90-driftplain-k3s.conf \
  /etc/NetworkManager/conf.d/90-driftplain-k3s.conf /home/steve/.kube/driftplain-home.yaml; do
  [[ ! -e $path && ! -L $path ]] || die "Existing $path; do not overwrite."
done
for runtime in k3s kubelet docker containerd; do
  ! command -v "$runtime" >/dev/null || die "Existing runtime: $runtime."
done
python3 - <<'PY'
import ipaddress, json, subprocess
networks = [ipaddress.ip_network(x) for x in ('10.42.0.0/16','10.43.0.0/16')]
for route in json.loads(subprocess.check_output(['ip','-j','-4','route'])):
    dst = route.get('dst','default')
    if dst != 'default' and any(ipaddress.ip_network(dst).overlaps(n) for n in networks):
        raise SystemExit('STOP: pod/service CIDR conflicts with existing route: '+dst)
PY
(cd downloads && sha256sum --check "$source_dir/SHA256SUMS")
[[ $mode == --apply ]] || { echo 'Unprivileged checks passed. --apply additionally checks effective firewall as root.'; exit 0; }
[[ $EUID -eq 0 ]] || die '--apply requires sudo.'
[[ ${SUDO_USER:-} == steve ]] || die 'Run through steve sudo, not a root login.'
[[ $(ufw status) == 'Status: inactive' ]] || die 'Firewall state changed; review before installation.'
[[ -z $(nft list ruleset) ]] || die 'Existing native nftables rules; review first.'
# Fail closed if rules were added since the read-only inventory (IPv4 or IPv6).
for binary in iptables ip6tables; do
  for table in filter nat mangle raw; do
    rules=$($binary -t "$table" -S)
    [[ -z $(printf '%s\n' "$rules" | grep -vE '^(-P [A-Z]+ ACCEPT|$)' || true) ]] || die "Existing $binary $table rules."
  done
done
ss -H -lnt | awk '{print $4}' | grep -Eq ':(6443|6444|2379|2380|10250)$' && die 'Cluster ports already in use.'
backup=$(mktemp -d /var/backups/driftplain-k3s.XXXXXXXX)
chmod 700 "$backup"
mkdir "$backup/default"
cp -a /etc/ufw "$backup/ufw"
cp -a /etc/default/ufw "$backup/default/ufw"
# Take a root-owned copy before verifying and executing the upstream installer.
install -m 600 downloads/install.sh "$backup/install.sh"
install -m 600 downloads/k3s "$backup/k3s"
(cd "$backup" && sha256sum --check "$source_dir/SHA256SUMS")
iptables-save > "$backup/iptables.before"
ip6tables-save > "$backup/ip6tables.before"
sysctl -n net.ipv4.ip_forward > "$backup/ip-forward.before"
printf '%s\n' "$backup" > /var/backups/driftplain-k3s-last-backup

install -d -m 755 /etc/modules-load.d /etc/sysctl.d /etc/NetworkManager/conf.d
printf 'overlay\nbr_netfilter\n' > /etc/modules-load.d/90-driftplain-k3s.conf
modprobe overlay
modprobe br_netfilter
printf 'net.ipv4.ip_forward=1\nnet.bridge.bridge-nf-call-iptables=1\n' > /etc/sysctl.d/90-driftplain-k3s.conf
sysctl -p /etc/sysctl.d/90-driftplain-k3s.conf
# Reload configuration only; never restart NetworkManager/drop the SSH connection.
printf '[keyfile]\nunmanaged-devices=interface-name:cni0;interface-name:flannel.1;interface-name:veth*\n' \
  > /etc/NetworkManager/conf.d/90-driftplain-k3s.conf
nmcli general reload conf
ufw default deny incoming
ufw default allow outgoing
ufw default deny routed
ufw allow in on eno1 from 192.168.1.0/24 to any port 22 proto tcp comment 'Driftplain LAN SSH'
ufw allow in on cni0 from 10.42.0.0/16 comment 'Driftplain pods to host'
ufw allow in on flannel.1 from 10.42.0.0/16 comment 'Driftplain overlay to host'
ufw route allow in on cni0 out on eno1 from 10.42.0.0/16 comment 'Driftplain pod egress'
ufw route allow in on cni0 out on cni0 from 10.42.0.0/16 to 10.42.0.0/16 comment 'Driftplain local pods'
ufw --force enable
install -d -m 700 /etc/rancher/k3s
install -m 600 k3s.yaml /etc/rancher/k3s/config.yaml
install -d -m 755 /var/lib/rancher/k3s/agent/etc/kubelet.conf.d
install -m 600 kubelet.conf /var/lib/rancher/k3s/agent/etc/kubelet.conf.d/10-home.conf
install -m 755 "$backup/k3s" /usr/local/bin/k3s
env -i PATH="$PATH" HOME=/root INSTALL_K3S_SKIP_DOWNLOAD=true \
  INSTALL_K3S_EXEC='server' sh "$backup/install.sh"
bash "$source_dir/finish-bootstrap.sh"
echo "Installed. Host backup: $backup."
