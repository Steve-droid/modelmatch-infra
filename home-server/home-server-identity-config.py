#!/usr/bin/env python3
"""Render public AWS process configuration, or run a workload with only that source.

Installation paths are part of the staged home image contract. No secrets are rendered.
"""

import argparse
import configparser
import json
import os
from pathlib import Path
import re
import shlex
import sys

HOME_SERVER_HELPER_SHA256 = "beec9ed1c492d93db809890f16713e3556353294b823c2184ad4e891f1b2b54d"
HOME_SERVER_ROOT = "/run/home-server-identity"
HOME_SERVER_PROFILES = ("backup", "bedrock")


def home_server_config(metadata, identity):
    if identity not in HOME_SERVER_PROFILES:
        raise ValueError("unknown identity")
    item = metadata[identity]
    role = re.fullmatch(r"arn:aws:iam::([0-9]{12}):role/modelmatch-home-server-" + identity, item["role_arn"])
    if not role or item["region"] != "ap-south-1":
        raise ValueError("wrong role or region")
    prefix = "arn:aws:rolesanywhere:ap-south-1:" + role[1] + ":"
    for field, resource in (("profile_arn", "profile"), ("trust_anchor_arn", "trust-anchor")):
        if not re.fullmatch(re.escape(prefix + resource + "/") + r"[a-f0-9-]{36}", item[field]):
            raise ValueError("wrong Roles Anywhere ARN")
    command = [
        "/usr/local/bin/python3", "/opt/home-server/home-server-credentials.py",
        "--helper", "/usr/local/bin/aws_signing_helper",
        "--helper-sha256", HOME_SERVER_HELPER_SHA256,
        "--certificate", HOME_SERVER_ROOT + "/tls.crt",
        "--private-key", HOME_SERVER_ROOT + "/tls.key",
        "--trust-anchor-arn", item["trust_anchor_arn"],
        "--profile-arn", item["profile_arn"], "--role-arn", item["role_arn"],
    ]
    return (f"[profile home-server-{identity}]\nregion = ap-south-1\n"
            f"credential_process = {shlex.join(command)}\n")


def home_server_environment(config, identity, environ):
    """Reject other identity sources; isolate default SDK discovery from operator creds."""
    conflicts = [name for name in environ if name.startswith("AWS_") and (
        any(part in name for part in ("ACCESS_KEY", "SECRET_KEY", "SESSION_TOKEN", "SECURITY_TOKEN"))
        or name.startswith(("AWS_CONTAINER_", "AWS_WEB_IDENTITY_"))
        or name in ("AWS_ROLE_ARN", "AWS_ROLE_SESSION_NAME")
    )]
    if conflicts:
        raise ValueError("conflicting AWS credential source")
    path = Path(config)
    if not path.is_absolute():
        raise ValueError("AWS config path must be absolute")
    # Only the generated, single-profile config is admitted (no SSO/source_profile).
    parsed = configparser.ConfigParser(interpolation=None)
    parsed.read_string(path.read_text())
    section = "profile home-server-" + identity
    if parsed.sections() != [section] or parsed.defaults() or set(parsed[section]) != {"region", "credential_process"}:
        raise ValueError("unexpected AWS config content")
    result = dict(environ)
    # Also close old boto2 config and host/container metadata fallback paths.
    result.update(AWS_CONFIG_FILE=str(path), AWS_SHARED_CREDENTIALS_FILE="/dev/null",
                  AWS_PROFILE="home-server-" + identity, AWS_DEFAULT_PROFILE="home-server-" + identity,
                  AWS_EC2_METADATA_DISABLED="true", BOTO_CONFIG="/dev/null",
                  AWS_DEFAULT_REGION="ap-south-1", AWS_REGION="ap-south-1")
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="operation", required=True)
    render = sub.add_parser("render")
    render.add_argument("--metadata", required=True, help="raw home_server_identity Terraform output JSON")
    render.add_argument("--identity", choices=HOME_SERVER_PROFILES, required=True)
    run = sub.add_parser("run")
    run.add_argument("--config", required=True)
    run.add_argument("--identity", choices=HOME_SERVER_PROFILES, required=True)
    run.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    try:
        if args.operation == "render":
            print(home_server_config(json.loads(Path(args.metadata).read_text()), args.identity), end="")
        else:
            command = args.command[1:] if args.command[:1] == ["--"] else args.command
            if not command:
                raise ValueError("workload command required")
            environment = home_server_environment(args.config, args.identity, os.environ)
            os.execvpe(command[0], command, environment)
    except (ValueError, KeyError, OSError):
        print("home-server identity configuration failed", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
