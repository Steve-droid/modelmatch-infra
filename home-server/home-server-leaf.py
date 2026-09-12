#!/usr/bin/env python3
"""Root-only home half of renewal. Outputs public certificates/CSRs, never keys.

Install only after identity deployment review. Reads/writes only the two configured
identity Secrets; GitOps owns workloads and references these operator-managed Secrets.
"""

import argparse
import base64
import fcntl
import json
import os
from pathlib import Path
import subprocess
import sys

HOME_SERVER_TARGETS = {
    "backup": ("home-server-backups", "home-server-backup-identity", None),
    "bedrock": ("app", "home-server-bedrock-identity", "modelmatch-backend"),
}
HOME_SERVER_ROOT = Path("/var/lib/driftplain/home-server-identity")


def run(command, payload=None):
    result = subprocess.run(command, input=payload, capture_output=True, timeout=180)
    if result.returncode:
        raise RuntimeError("home-server leaf operation failed")
    return result.stdout


def kubectl(namespace, *args, payload=None):
    # Never consult the Mac/default AWS context or K3s config environment.
    return run(["/usr/bin/env", "K3S_CONFIG_FILE=/dev/null", "/usr/local/bin/k3s", "kubectl",
                "--kubeconfig=/home/steve/.kube/driftplain-home.yaml",
                "--context=driftplain-home", "--server=https://127.0.0.1:6443",
                "-n", namespace, *args], payload)


def leaf(operation, identity, certificate=None):
    namespace, secret, deployment = HOME_SERVER_TARGETS[identity]
    directory = HOME_SERVER_ROOT / identity
    directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    with (directory / "lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        current = json.loads(kubectl(namespace, "get", "secret", secret, "-o", "json"))
        current_cert = base64.b64decode(current["data"]["tls.crt"], validate=True)
        if operation == "status":
            return {"certificate": current_cert.decode()}
        key_path, csr_path = directory / "pending.key", directory / "pending.csr"
        if operation == "prepare":
            if not key_path.exists():
                key = run(["openssl", "genpkey", "-algorithm", "RSA", "-pkeyopt", "rsa_keygen_bits:3072"])
                with key_path.open("xb") as stream:
                    stream.write(key)
            if not csr_path.exists():
                csr = run(["openssl", "req", "-new", "-sha256", "-key", str(key_path),
                           "-subj", "/CN=driftplain-home-server-" + identity])
                with csr_path.open("xb") as stream:
                    stream.write(csr)
            return {"csr": csr_path.read_text()}
        if operation != "install" or not certificate:
            raise ValueError("invalid operation")
        # Idempotent after response loss: reconcile the pod rollout even if the
        # Secret update already succeeded, without needing the removed old key.
        if certificate != current_cert:
            candidate = directory / "candidate.crt"
            candidate.write_bytes(certificate)  # public material only
            run(["openssl", "verify", "-CAfile", str(HOME_SERVER_ROOT / "issuer.crt"), str(candidate)])
            subject = run(["openssl", "x509", "-in", str(candidate), "-noout", "-subject", "-nameopt", "RFC2253"]).decode().strip().replace("subject= ", "subject=")
            if subject != "subject=CN=driftplain-home-server-" + identity:
                raise ValueError("wrong certificate identity")
            public_cert = run(["openssl", "x509", "-in", str(candidate), "-pubkey", "-noout"])
            public_key = run(["openssl", "pkey", "-in", str(key_path), "-pubout"])
            if public_cert != public_key:
                raise ValueError("certificate/key mismatch")
            # Preserve resourceVersion and unrelated metadata/data; replace one
            # existing Secret atomically, refusing concurrent updates.
            current["data"]["tls.crt"] = base64.b64encode(certificate).decode()
            current["data"]["tls.key"] = base64.b64encode(key_path.read_bytes()).decode()
            current["metadata"].pop("managedFields", None)
            kubectl(namespace, "replace", "-f", "-", payload=json.dumps(current).encode())
        if deployment:
            # A public certificate fingerprint in the pod template gives an
            # idempotent rollout. Never a blind rollout restart on every retry.
            import hashlib
            fingerprint = hashlib.sha256(certificate).hexdigest()
            patch = {"spec": {"template": {"metadata": {"annotations": {
                "driftplain.dev/home-server-certificate-sha256": fingerprint
            }}}}}
            kubectl(namespace, "patch", "deployment", deployment, "--type=merge", "-p", json.dumps(patch))
            kubectl(namespace, "rollout", "status", "deployment/" + deployment, "--timeout=120s")
        observed = json.loads(kubectl(namespace, "get", "secret", secret, "-o", "json"))
        if base64.b64decode(observed["data"]["tls.crt"]) != certificate:
            raise ValueError("certificate delivery did not persist")
        for path in (key_path, csr_path, directory / "candidate.crt"):
            path.unlink(missing_ok=True)
        return {"installed": True}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("operation", choices=("status", "prepare", "install"))
    parser.add_argument("identity", choices=HOME_SERVER_TARGETS)
    args = parser.parse_args()
    if os.geteuid() != 0:
        parser.error("requires sudo -n")
    os.umask(0o077)
    try:
        payload = sys.stdin.buffer.read(16384) if args.operation == "install" else None
        print(json.dumps(leaf(args.operation, args.identity, payload)))
    except Exception:
        print("home-server leaf operation failed; private output suppressed", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
