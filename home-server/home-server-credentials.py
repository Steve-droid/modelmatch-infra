#!/usr/bin/env python3
"""Bounded credential_process bridge. Stdout is PRIVATE: consume only via an SDK.

No issuer/key creation, cloud administration, credential files or credential cache.
The verified AWS helper reads the leaf key and exchanges it for a temporary session.
"""

import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys


def home_server_credentials(args):
    helper = Path(args.helper)
    if not helper.is_absolute() or not re.fullmatch(r"[a-f0-9]{64}", args.helper_sha256):
        raise ValueError("invalid helper configuration")
    if hashlib.sha256(helper.read_bytes()).hexdigest() != args.helper_sha256:
        raise ValueError("helper checksum mismatch")
    for name in ("certificate", "private_key"):
        path = Path(getattr(args, name))
        if not path.is_absolute() or not path.is_file():
            raise ValueError("missing identity file")
    # Allow an owning group for Kubernetes Secret volumes; never world-readable.
    if Path(args.private_key).stat().st_mode & 0o007:
        raise ValueError("private key accessible to other users")
    completed = subprocess.run(
        [str(helper), "credential-process", "--certificate", args.certificate,
         "--private-key", args.private_key, "--trust-anchor-arn", args.trust_anchor_arn,
         "--profile-arn", args.profile_arn, "--role-arn", args.role_arn,
         "--session-duration", "3600"],
        stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        timeout=30, check=True,
    )
    value = json.loads(completed.stdout)
    names = ("AccessKeyId", "SecretAccessKey", "SessionToken", "Expiration")
    if value.get("Version") != 1 or any(
        not isinstance(value.get(name), str) or not value[name] for name in names
    ):
        raise ValueError("invalid temporary credentials")
    expires = datetime.fromisoformat(value["Expiration"].replace("Z", "+00:00"))
    remaining = (expires - datetime.now(timezone.utc)).total_seconds()
    if not 60 < remaining <= 3700:
        raise ValueError("invalid session expiry")
    return {"Version": 1, **{name: value[name] for name in names}}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("helper", "helper-sha256", "certificate", "private-key",
                 "trust-anchor-arn", "profile-arn", "role-arn"):
        parser.add_argument("--" + name, required=True)
    args = parser.parse_args()
    try:
        value = home_server_credentials(args)
    except Exception:
        # SDKs include stderr in exceptions. Never relay helper output or exception
        # text: it can contain private credentials, paths or provider diagnostics.
        print("home-server credential refresh failed", file=sys.stderr)
        return 1
    print(json.dumps(value))
    return 0


if __name__ == "__main__":
    sys.exit(main())
