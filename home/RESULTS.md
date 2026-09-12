# Home bootstrap verification — September 12, 2026

## Preparation complete

- Current infra source fetched and isolated at `ef638ceff176915c9c3280ba032e5fda02c4b685`.
- Strict-key SSH, unprivileged host inventory and user-run privileged read-only inventory pass.
- Bash syntax + ShellCheck 0.11.0 pass for `preflight-root.sh`, `prepare.sh`, `bootstrap.sh`,
  `finish-bootstrap.sh`, `verify.sh`.
- Ubuntu downloaded pinned K3s binary/install script; both official SHA256 pins match.
- Real Ubuntu `bootstrap.sh --check` passes, creates no cluster/config/runtime files.
- Corrupted-checksum negative test rejected the binary before host writes (after fixing
  checksum file resolution with a symlinked downloads directory).
- First-slice files uploaded under `/home/steve/home-server-setup/k3s/`.

## Runtime status

**Installed and runtime smoke passed.** Steve ran the installer and finish-only step.
K3s v1.36.4+k3s1 is active and boot-enabled; one `driftplain-home` node is Ready.
Containerd reports `2.3.4-k3s1.36`; cluster-secret encryption Enabled, hashes match.
UFW is active with the scoped rules in bootstrap. The separate user kubeconfig is 0600,
context `driftplain-home`, server `https://127.0.0.1:6443`.

The initial readiness command raced node registration and returned NotFound; corrected
by waiting for node existence first. The finish-only step completed successfully without
reinstalling/restarting. User CLI warnings about root-only config are avoided with
`K3S_CONFIG_FILE=/dev/null`; explicit kubeconfig still supplies the connection/identity.

Smoke verified:

- CoreDNS, local-path provisioner and metrics-server ready.
- Kubernetes DNS and external DNS resolution; outbound HTTP from the pod.
- ClusterIP HTTP routing through `proof` Service.
- Effective kubelet NoSwap setting and actual container `memory.swap.max=0`.
- A non-root writer created data on a bound PVC. A replacement reader pod found the
  exact content on the same PV without recreating it; HTTP read passed after replacement.
- Metrics available (`kubectl top nodes`); successful disposable namespace cleanup.
- Fresh strict-key SSH succeeds; Mac TCP checks: 22 open, 6443/10250/2379/2380 not reachable.
- Post-install `bootstrap.sh --check` correctly refuses the existing cluster before writes.
- Final inventory has no smoke namespaces or PVs remaining; Mac's original AWS context
  is unchanged and the public API still reports ready/db ok.

The first smoke was interrupted by replacing its script during execution. Its labelled
namespace was safely removed; the full rerun used an immutable script copy and passed.
Result log on Ubuntu: `/home/steve/home-server-setup/k3s/smoke-result.txt`.
Firewall/encryption report: `/home/steve/home-server-setup/k3s/finish-result.txt`.

**Still unverified:** controlled reboot/service recovery and off-machine backup/restore.
Boot enablement alone does not prove reboot recovery. Local-path smoke volume is disposable;
production storage must use an explicit Retain/restore design in the next slice.
No production backup, restored database or home application deployment exists.

## Production preservation

Only read-only AWS/API/DB inventory performed. No cloud mutation, public routing change,
secret export, paid LLM request, data migration or seed operation. Existing AWS kubeconfig
context unchanged. No commits, pushes, merges or tags. Unrelated worktrees preserved.

## Administrator access update

Steve installed `/etc/sudoers.d/99-steve-nopasswd` with
`steve ALL=(ALL:ALL) NOPASSWD: ALL`, then reported successful `visudo -c`, `sudo -k`
and `sudo -n whoami`. Codex independently ran `sudo -n whoami` through a fresh
strict-host-key, batch-mode SSH connection: output `root`, exit 0, no password prompt.
Authorized home-server administration can now proceed with `sudo -n`. No password
was shared, retrieved, or stored by Codex. Existing commit/cutover/teardown review gates
are unchanged.

## Workspace consolidation

The active migration files were copied byte-for-byte from the home worktree into the
canonical `modelmatch-infra/home/` directory before removing that worktree. The same
`feature/home-k3s-bootstrap` branch now runs there. Completed power setup was promoted
from the ignored `.codex/home-server/` folder into `home/configure-power.sh` and `home/POWER.md`.
No host changes or rerun of the completed power setup occurred during consolidation.
The authoritative upcoming plan is E21 / HM1–HM8 in the umbrella showcase backlog.

## Review approval — September 12, 2026

Steve approved the completed cleanup/plan and consolidated migration foundation, then
requested a fresh session. This approves committing the current local slice; it does not
authorize public cutover or AWS teardown. The next implementation slice is E21/HM2.
