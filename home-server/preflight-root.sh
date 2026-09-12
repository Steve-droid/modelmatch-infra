#!/usr/bin/env bash
# Read-only privileged inventory. No installs, firewall changes or credentials.
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo 'Run with sudo.' >&2; exit 1; }
export LC_ALL=C
hostname
ufw status verbose
iptables -S
iptables -t nat -S
ip6tables -S
swapon --show
ss -lntup
systemctl is-enabled ufw
for module in overlay br_netfilter vxlan; do
  modprobe --dry-run "$module"
done
stat -fc %T /sys/fs/cgroup
cat /sys/fs/cgroup/cgroup.controllers
sysctl net.ipv4.ip_forward net.bridge.bridge-nf-call-iptables 2>/dev/null || true
echo 'Read-only privileged preflight complete.'
