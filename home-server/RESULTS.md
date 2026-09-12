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

**At HM1 completion, still unverified:** controlled reboot/service recovery and off-machine backup/restore.
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

## HM2 recovery slice — September 12, 2026 (ready for review)

Fresh read-only inventory at 23:15–23:18 Asia/Jerusalem confirmed home Ready/active/enabled,
no failed system units, UFW/secret encryption intact, Samsung root 422 GiB free and no app/PVs.
AWS has three Ready nodes, two healthy CNPG instances and 14 Synced/Healthy ArgoCD apps.
Public API ready/db ok. Budget remains armed at $99 with reported actual $45.709 and
forecast $101.66; no cloud mutation occurred. See [operating design](OPERATING-DESIGN.md).

Implemented `recovery-check.py`; immutable uploaded copy:
`/home/steve/home-server-setup/recovery-check-hm2-v1.py`.
Witness `home-recovery-99fa98d483f9` was prepared at 23:19:23.
Python syntax and live baseline checks passed. Negative checks correctly rejected the wrong
host (Mac), a repeated prepare, claiming service recovery without a restart, and claiming
reboot recovery without a reboot. No production data is in the witness.

**Service interruption passed.** At 23:20:06, sent SIGKILL only to K3s's main process.
The existing `Restart=always`/5-second-delay policy recovered automatically; no manual start.
API readiness returned at 23:20:20 and the complete witness check passed at 23:20:22.922
(approximately 17 seconds from interruption). Same kernel boot ID, node/namespace/PVC/PV UIDs
and original marker hash; changed K3s invocation ID. Node/system deployments, Service HTTP,
cluster DNS, external DNS and HTTP egress passed. This does not prove reboot/disk-loss recovery.

Steve explicitly approved the Desktop reboot after saving work. Fresh witness status and AC
power checks passed, then `sudo -n systemctl reboot` was requested at **23:23:07**.
**Reboot recovery passed at 23:25:36.542** (approximately 150 seconds after the request).
Fresh strict-key SSH first succeeded in the recorded polling at 23:25:16. A first witness
check saw transient Service DNS failure; the bounded retry at 23:25:34 passed fully without
recreating any object or rewriting the marker. Boot ID changed from
`89004b4c-4ddb-447c-ac89-17400163c9ef` to `17e19f2b-e421-420e-b4fa-be1524ecf4c4`.
Node/namespace/PVC/PV UIDs and original file hash match. The witness container restarted once.

Shutdown journal records one containerd scope timing out at 23:24:37 (90 seconds after
the request); it was killed by systemd. Boot itself reported 33.908 seconds and K3s active
at 23:25:14. Recovery succeeded within the planned five minutes. Do not hide the shutdown
delay or shorten global stop timeouts blindly; HM3/HM5 must validate graceful PostgreSQL
shutdown with actual CNPG data before treating this as an application recovery guarantee.

Post-reboot checks passed: SSH service/socket enabled and active; `sudo -n`; zero failed
system units; UFW active with original scoped rules; encryption enabled/hashes match;
effective kubelet NoSwap and container swap limit 0; all five sleep targets masked;
AC connected, lid physically closed, logind ignore-lid settings and both GNOME idle settings
retained. Mac TCP 22 reachable; 6443/10250/2379/2380 not reachable. Address remained `.93`
through this host reboot, but router reservation/restart is still unverified.
AWS API stayed ready/db ok and Mac's default context stayed on the AWS cluster.

Machine-readable IDs/hash/timestamps: [hm2-recovery-evidence.json](hm2-recovery-evidence.json).
Local script and executed remote copy SHA256 both
`eb010af981d64d6af9f978af8172070a5184d1f1b0f9c661d3bff1af9f76a181`.
The witness evidence was copied off-host before its scoped cleanup. Python syntax,
home-document relative links and diff whitespace pass. No unchanged application suite rerun.
Cleanup succeeded: only the four system/default namespaces remain and there are no PVs.
The original remote witness JSON was archived, not discarded.

Remaining HM2 choices: router reservation/WAN facts, chosen backup provider/retention/key custody,
public tunnel/DNS setup, external identity/image distribution, budget safeguard and rollback
window. Steve selected small paid off-site backup storage; no account/subscription was created.
The operating design is a review draft, not a deployed configuration or finalized cost total.
No production export, paid LLM call, cloud/routing mutation, commit or push occurred.

## HM2 DHCP reservation and router recovery — September 12, 2026

Steve's screenshots show the saved static lease on bridge `brlan0`: Ethernet MAC
`A8:B1:3B:73:F8:7A` → `192.168.1.93`, with the router's save-success notification.
Steve then power-cycled the router in the agreed household outage window, leaving home-server on.

NetworkManager logged link/DHCP interruption and a new `.93` lease at **23:42:23**
Asia/Jerusalem. Fresh strict-key SSH succeeded at **23:42:36**. Root host boot ID and K3s
invocation ID are unchanged from the earlier reboot; no host/K3s/pod restart was performed
to recover this outage. Default gateway is `.1`, UFW remains active, and the node is Ready.

Metrics-server briefly reported no metrics during recovery and returned to 1/1 automatically.
A restricted digest-pinned disposable BusyBox pod verified cluster DNS, external DNS and
HTTP internet access. `kubectl top nodes` returned metrics. All three system pods are 1/1
with their original post-host-reboot restart counts. A home-host HTTPS GET to the production
API returned ready/db ok. The test namespace `home-network-1ab9517b2f` was deleted after
its ownership check; only the existing system namespaces/pods remain.

This verifies automatic network recovery and renewed address assignment after the real
router power cycle. The router's saved configuration was established by Steve's screenshots;
its management UI was not independently reopened after the cycle. Exact outage duration
was not measured. WAN/CGNAT/provider-route decisions remain separate from this LAN test.
Evidence also recorded in `hm2-recovery-evidence.json`; no production/cloud changes or commits.

## HM2 budget safeguard proposal — September 12, 2026

Prepared a full bootstrap Terraform plan after a fresh AWS inventory. Reported actual spend
is now $48.833 (forecast $101.66); Lambda remains armed at $99. Both recorded CodeBuild
teardown runs are completed dry runs; no teardown was running during preparation.

The initial plan exposed an existing omission in `ecr_repository_names`: the state-managed
`modelmatch-agent-security` repository was not declared and would have been deleted. Added
it to the list. Revised full plan: 0 creates, 2 in-place updates, 0 deletes — Lambda DRY_RUN
0→1 and the existing registry ownership tag manual-p38d→bootstrap. Registry contents,
lifecycle policies and all other Lambda environment variables are unchanged. Terraform
validate passed; parsed plan assertions verified this exact scope. Sanitized evidence is
`hm2-budget-plan.json`; private binary plan stays outside Git.

Explicit cloud approval requested before applying; no commit/push authorized.
A separate read-only database-size query found `modelmatch` at 9716 kB (~9.5 MiB); this
is allocated database size, not a backup export or measured encrypted archive size.

## HM2 approved budget safeguard applied — September 13, 2026

Steve explicitly approved the two reviewed AWS updates. Rechecked account, saved-plan and
tfvars hashes and absence of running teardown builds; captured pre-change budget notifications
and complete ECR image identifier lists privately. Applied the approved saved plan with normal
Terraform locking: **0 added, 2 changed, 0 destroyed**.

Verified Lambda Active/Successful with DRY_RUN=1 and unchanged other variables; registry tag
stack=bootstrap; gross $110 budget configuration and all notifications/subscribers unchanged;
all image identifiers unchanged across four ECR repositories. No active teardown builds.
AWS remains healthy: three Ready nodes, 14 Synced/Healthy ArgoCD apps, two healthy CNPG
instances and public API ready/db ok. Full follow-up Terraform plan returned no changes
(detailed exit code 0). Evidence: [hm2-budget-applied.json](hm2-budget-applied.json).

No resources destroyed, public routing changed, paid LLM calls, synthetic budget triggers,
commits or pushes. The $110 budget is an alert, not a compute billing cap; this trade-off
was explicitly approved. Remaining HM2 provider/identity/routing/retention decisions and
actual production backup/restore remain open.

## HM2 S3 bucket foundation prepared — September 13, 2026

Provider selected by Steve: S3. Recovery targets accepted: hourly copies retained one day,
daily copies 30 days, four-hour restore with working hardware/internet; deletion timing is
asynchronous. Implemented the separate persistent bucket configuration with versioning,
private ownership/public-access blocks, SSE-S3, TLS-only policy, destroy prevention and
teardown-role denial in both resource and identity policies. No expiry rules enabled yet.

Four mocked contracts passed after supplying valid placeholder JSON for unrelated existing
IAM data sources; the first mock run failed on those placeholders before exercising tests.
The actual refreshed AWS plan and nine IAM simulations separately verified the real policies.
Plan: 6 creates, 1 in-place guardrail update, 0 deletes; previous guardrail statements unchanged.
No changes to the applied DRY_RUN=1 setting or existing registries.

[Scope/recovery design](S3-BACKUPS.md) and [sanitized plan](hm2-s3-plan.json) are ready for
review; bucket creation/guardrail apply still require explicit cloud approval. No production
backup, home identity installation, S3 upload, commit or push performed.

## Explicit home-server naming — September 13, 2026

Renamed canonical source directory `home/` → `home-server/` and updated current instructions
and documentation links. Terraform input/output/local/resource identifiers now use
`home_server`; backup Terraform/test filenames, future smoke namespace prefixes and the
proposed S3 bucket use `home-server`. The unapproved bucket plan was regenerated for the
new name; no existing bucket/resource was renamed or destroyed.

Terraform validate, four mocked tests, shell/Python syntax and nine IAM simulations pass.
Fresh full plan remains 6 creates, 1 protective role-policy update, 0 deletes. Historical
live-check object names/hashes above remain unchanged and refer to the prior immutable
script uploads. Installed K3s node/context/kubeconfig/drop-in identifiers are intentionally
preserved runtime compatibility values. No cloud apply, host reconfiguration or commit.

## Approved S3 bucket foundation applied — September 13, 2026

Steve approved continuing with the reviewed renamed bucket/protection scope. Account, source
and saved-plan hashes matched; no teardown build was running and the Lambda stayed DRY_RUN=1.
Applied the exact saved plan with normal Terraform locking: **6 added, 1 changed, 0 destroyed**.
This is one S3 bucket plus five settings and an added deny in the existing teardown-role policy.

Live read-only checks verified `modelmatch-home-server-backups-957261948820` in ap-south-1,
versioning Enabled, all four public-access blocks, BucketOwnerEnforced, AES256 SSE-S3,
non-public bucket-policy status, TLS deny and explicit teardown-role bucket/object deny.
The bucket contains no versions or delete markers. Nine simulations against the actual
updated role confirm backup operations are denied and required state Get/Put remains allowed.

Production API is ready/db ok and both CNPG instances are healthy. No new teardown build;
DRY_RUN=1 unchanged. Full follow-up Terraform plan: no changes, detailed exit code 0.
[Applied evidence](hm2-s3-applied.json). No production export, scheduled backup, actual S3
data upload/restore, IAM uploader credentials, commit or push. Key custody and remaining
HM2 external-identity/public-route/operating decisions remain open.

## Recovery-key custody — September 13, 2026

Steve selected AWS Secrets Manager plus a local-only macOS Keychain copy. Created the native
age v1 identity in memory and stored it in this Mac's existing login keychain; only its public
recipient is a source file. Installed age 1.3.2 locally. No private identity went to the home server.

Applied the full scope-checked bootstrap plan: **2 creates, 1 update, 0 deletes** — one recovery
secret, its resource policy and an added teardown-role deny. Every existing guardrail is unchanged.
AWS resource-policy validation passed; live policies match the plan. Five live-principal IAM
simulations deny teardown Get/Put/Delete/policy changes, while the two required state Get/Put
permissions remain allowed. The private value was stored separately, outside Terraform/state.

Independent decryption with the Mac Keychain copy passed at 01:30:27 Asia/Jerusalem, and with
the AWS-only copy at 01:36:52. Each used a new disposable encrypted challenge; the local proof
made no AWS call and the AWS proof never opened Keychain. Correct-key/wrong-key/corruption,
retry/no-overwrite and secret-argument checks pass (6 tests); all 7 backup/custody mocked
Terraform contracts pass. Full follow-up Terraform plan returned no changes, exit code 0.

An initial key-length fixture check and mocked-plan unknown-value assertion were corrected
before real provisioning. The first AWS upload attempt failed during non-secret metadata
JSON parsing, before upload; changed the CLI transport to pass only SecretString via stdin.
No plaintext file/process-argument fallback was used. The single AWS value's readback matches
Keychain; its stable version ID is recorded in [custody evidence](hm2-recovery-key-evidence.json).

The S3 backup bucket remains empty, AWS API is ready/db ok, and the kill switch remains DRY_RUN=1.
No production export/restore, public routing, host disruption, paid LLM call, commit or push.
The added secret costs approximately $0.40/month plus retrieval requests. The Mac copy is
offline-capable local storage, not removable media. [Runbook](RECOVERY-KEY.md).
Remaining HM2 choices: external identity, images, app secrets, routing, rollback/legacy URLs
and the accepted operating plan. HM2 remains in progress.
