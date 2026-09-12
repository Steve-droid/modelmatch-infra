#!/usr/bin/env bash
# Tests only a new, labelled disposable namespace on the explicit HOME cluster.
# No app resources, AWS credentials, LLM requests or production data are used.
set -euo pipefail
# kubectl does not need the root-only K3s server configuration.
export K3S_CONFIG_FILE=/dev/null
config=/home/steve/.kube/driftplain-home.yaml
k=(/usr/local/bin/k3s kubectl --kubeconfig "$config" --context driftplain-home --request-timeout=20s)
[[ $(hostname) == home-server ]] || { echo 'Wrong host' >&2; exit 1; }
[[ $(stat -c %a "$config") == 600 ]] || { echo 'Unsafe kubeconfig mode' >&2; exit 1; }
[[ $("${k[@]}" config view --minify -o jsonpath='{.clusters[0].cluster.server}') == https://127.0.0.1:6443 ]] || exit 1
"${k[@]}" get nodes -o json | python3 -c '
import json,sys
n=json.load(sys.stdin)["items"]
assert len(n)==1 and n[0]["metadata"]["name"]=="driftplain-home", "Unexpected cluster"
assert n[0]["status"]["nodeInfo"]["kubeletVersion"]=="v1.36.4+k3s1"
assert any(c["type"]=="Ready" and c["status"]=="True" for c in n[0]["status"]["conditions"])
'
"${k[@]}" get --raw /api/v1/nodes/driftplain-home/proxy/configz | python3 -c '
import json,sys
c=json.load(sys.stdin)["kubeletconfig"]
assert c["failSwapOn"] is False
assert c["memorySwap"]["swapBehavior"]=="NoSwap"
print("Verified effective NoSwap configuration")
'
"${k[@]}" -n kube-system rollout status deploy/coredns --timeout=180s
"${k[@]}" -n kube-system rollout status deploy/local-path-provisioner --timeout=180s
"${k[@]}" -n kube-system rollout status deploy/metrics-server --timeout=180s
ns="home-smoke-$(date +%s)-$$"
"${k[@]}" create namespace "$ns"
"${k[@]}" label namespace "$ns" driftplain.dev/purpose=bootstrap-smoke \
  pod-security.kubernetes.io/enforce=restricted pod-security.kubernetes.io/enforce-version=v1.36
cleanup() {
  rc=$?
  if (( rc != 0 )); then
    "${k[@]}" -n "$ns" get pods,pvc,events || true
    echo "Smoke failed; retained namespace $ns for diagnosis." >&2
  elif [[ $("${k[@]}" get namespace "$ns" -o jsonpath='{.metadata.labels.driftplain\.dev/purpose}') == bootstrap-smoke ]]; then
    "${k[@]}" delete namespace "$ns" --wait=true --timeout=120s
  fi
}
trap cleanup EXIT
"${k[@]}" -n "$ns" apply -f - <<'YAML'
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: proof
spec:
  storageClassName: local-path
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 128Mi
---
apiVersion: v1
kind: Service
metadata:
  name: proof
spec:
  selector:
    app: proof
  ports:
    - port: 8080
      targetPort: 8080
YAML
pod() {
  name=$1
  action=$2
  "${k[@]}" -n "$ns" apply -f - <<YAML
apiVersion: v1
kind: Pod
metadata:
  name: $name
  labels:
    app: proof
spec:
  automountServiceAccountToken: false
  restartPolicy: Never
  terminationGracePeriodSeconds: 5
  securityContext:
    runAsNonRoot: true
    runAsUser: 1000
    runAsGroup: 1000
    fsGroup: 1000
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: proof
      image: docker.io/library/busybox:1.37.0@sha256:7a3ebe5bfd1a4a19797d20b0c0bb39d44393e9a03fd852c0865b0f540d868df0
      command: [sh, -ec]
      args: ['$action; exec httpd -f -p 8080 -h /data']
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities:
          drop: [ALL]
      resources:
        requests:
          cpu: 10m
          memory: 16Mi
        limits:
          cpu: 100m
          memory: 64Mi
      readinessProbe:
        httpGet:
          port: 8080
          path: /index.html
        periodSeconds: 2
      livenessProbe:
        httpGet:
          port: 8080
          path: /index.html
        periodSeconds: 5
      volumeMounts:
        - name: data
          mountPath: /data
  volumes:
    - name: data
      persistentVolumeClaim:
        claimName: proof
YAML
  "${k[@]}" -n "$ns" wait "pod/$name" --for=condition=Ready --timeout=180s
}
pod writer 'echo persistent-proof > /data/index.html; sync'
pv=$("${k[@]}" -n "$ns" get pvc proof -o jsonpath='{.spec.volumeName}')
"${k[@]}" -n "$ns" exec writer -- nslookup kubernetes.default.svc.cluster.local
"${k[@]}" -n "$ns" exec writer -- nslookup github.com
"${k[@]}" -n "$ns" exec writer -- wget -T 15 -q -O /dev/null http://example.com
[[ $("${k[@]}" -n "$ns" exec writer -- wget -T 15 -qO- http://proof:8080/index.html) == persistent-proof ]]
# Expand inside the container, not on the operator's host.
# shellcheck disable=SC2016
"${k[@]}" -n "$ns" exec writer -- sh -ec 'test "$(cat /sys/fs/cgroup/memory.swap.max)" = 0'
"${k[@]}" -n "$ns" delete pod writer --wait=true --timeout=60s
# Reader must find the original value; it never writes or recreates it.
# shellcheck disable=SC2016
pod reader 'test "$(cat /data/index.html)" = persistent-proof'
[[ $("${k[@]}" -n "$ns" get pvc proof -o jsonpath='{.spec.volumeName}') == "$pv" ]]
[[ $("${k[@]}" -n "$ns" exec reader -- wget -T 15 -qO- http://proof:8080/index.html) == persistent-proof ]]
"${k[@]}" top nodes
echo 'PASS: node, DNS, Service routing, effective NoSwap, metrics and PVC survival across pod replacement.'
