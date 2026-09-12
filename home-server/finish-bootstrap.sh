#!/usr/bin/env bash
# Safe completion after startup: no install, firewall changes or service restart.
set -euo pipefail
[[ $EUID -eq 0 && ${SUDO_USER:-} == steve && $(hostname) == home-server ]] || exit 1
[[ $(/usr/local/bin/k3s --version | head -1) == 'k3s version v1.36.4+k3s1 '* ]] || exit 1
systemctl is-active --quiet k3s
k=(/usr/local/bin/k3s kubectl --kubeconfig /etc/rancher/k3s/k3s.yaml --request-timeout=5s)
# systemd's startup notification can precede node registration. First await existence.
registered=false
for ((attempt=0; attempt<60; attempt++)); do
  if "${k[@]}" get node driftplain-home >/dev/null 2>&1; then registered=true; break; fi
  sleep 2
done
[[ $registered == true ]] || { echo 'Node did not register; inspect k3s logs.' >&2; exit 1; }
"${k[@]}" wait node/driftplain-home --for=condition=Ready --timeout=180s
"${k[@]}" get nodes -o wide
config=/home/steve/.kube/driftplain-home.yaml
[[ ! -e $config && ! -L $config && ! -L /home/steve/.kube ]] || {
  echo 'Refuse to replace an existing user kubeconfig or symlink.' >&2; exit 1;
}
if [[ ! -d /home/steve/.kube ]]; then install -d -o steve -g steve -m 700 /home/steve/.kube; fi
install -o steve -g steve -m 600 /etc/rancher/k3s/k3s.yaml "$config"
runuser -u steve -- env K3S_CONFIG_FILE=/dev/null /usr/local/bin/k3s kubectl \
  --kubeconfig "$config" config rename-context default driftplain-home
/usr/local/bin/k3s secrets-encrypt status
ufw status verbose
echo 'Bootstrap complete. Run verify.sh as steve; no sudo needed.'
