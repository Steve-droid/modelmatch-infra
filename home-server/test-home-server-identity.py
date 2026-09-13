"""Offline SDK/process integration: real boto3 signing, fake helper, no AWS traffic."""

from datetime import datetime, timedelta, timezone
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shlex
import socket
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

import boto3
from botocore.awsrequest import AWSRequest
from botocore.exceptions import CredentialRetrievalError

ROOT = Path(__file__).resolve().parent
BACKEND = ROOT.parent.parent / "driftplain-backend"
sys.path.insert(0, str(BACKEND))
from app.llm.bedrock_client import BedrockClient

spec = importlib.util.spec_from_file_location("home_server_identity_config", ROOT / "home-server-identity-config.py")
config_module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(config_module)


class HomeServerIdentityTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="home-server-identity-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.helper = self.root / "fake-helper"
        self.control = self.root / "control.json"
        self.counter = self.root / "calls"
        self.counter.write_text("0")
        self.now = datetime.now(timezone.utc)
        self.set_control("ok", self.now + timedelta(minutes=16))
        self.helper.write_text(f"#!{sys.executable}\n" + '''
import json, pathlib, sys
root = pathlib.Path(__file__).parent
control = json.loads((root / "control.json").read_text())
counter = root / "calls"
n = int(counter.read_text()) + 1
counter.write_text(str(n))
if control["mode"] == "fail":
    print("PRIVATE_DIAGNOSTIC_SENTINEL", file=sys.stderr)
    sys.exit(1)
if control["mode"] == "malformed":
    print("PRIVATE_DIAGNOSTIC_SENTINEL")
    sys.exit(0)
value = {"Version": 1, "AccessKeyId": f"ASIAEXAMPLE{n:09d}",
         "SecretAccessKey": "FAKE_SECRET", "SessionToken": "FAKE_TOKEN",
         "Expiration": control["expiry"]}
if control["mode"] == "no-expiry":
    del value["Expiration"]
print(json.dumps(value))
''')
        self.helper.chmod(0o700)
        self.cert = self.root / "tls.crt"
        self.key = self.root / "tls.key"
        self.cert.write_text("NOT A REAL CERTIFICATE: fake helper fixture")
        self.key.write_text("NOT A REAL PRIVATE KEY: fake helper fixture")
        self.key.chmod(0o600)
        self.digest = hashlib.sha256(self.helper.read_bytes()).hexdigest()
        self.metadata = {name: {
            "role_arn": "arn:aws:iam::957261948820:role/modelmatch-home-server-" + name,
            "profile_arn": "arn:aws:rolesanywhere:ap-south-1:957261948820:profile/22222222-2222-2222-2222-222222222222",
            "trust_anchor_arn": "arn:aws:rolesanywhere:ap-south-1:957261948820:trust-anchor/11111111-1111-1111-1111-111111111111",
            "region": "ap-south-1",
        } for name in ("backup", "bedrock")}
        self.command = [sys.executable, str(ROOT / "home-server-credentials.py"),
                        "--helper", str(self.helper), "--helper-sha256", self.digest,
                        "--certificate", str(self.cert), "--private-key", str(self.key)]
        for name in ("role_arn", "profile_arn", "trust_anchor_arn"):
            self.command += ["--" + name.replace("_", "-"), self.metadata["bedrock"][name]]
        self.config = self.root / "aws-config"
        rendered = config_module.home_server_config(self.metadata, "bedrock")
        self.config.write_text(rendered.split("credential_process =")[0] + "credential_process = " + shlex.join(self.command) + "\n")

    def set_control(self, mode, expiry):
        self.control.write_text(json.dumps({"mode": mode, "expiry": expiry.isoformat()}))

    def invoke(self):
        return subprocess.run(self.command, capture_output=True, text=True, timeout=10)

    def test_same_backend_client_refreshes_and_signs_without_network(self):
        env = config_module.home_server_environment(str(self.config), "bedrock", {})
        # Clear the Mac's AWS environment and prevent every network connection.
        with patch.dict(os.environ, env, clear=True), patch.object(socket.socket, "connect", side_effect=AssertionError("network forbidden")):
            session = boto3.Session()
            with patch("boto3.client", side_effect=session.client):
                adapter = BedrockClient("apac.amazon.nova-lite-v1:0", region="ap-south-1")
                client = adapter._ensure_client()
            credentials = client._request_signer._credentials
            self.assertEqual(credentials.method, "custom-process")
            clock = [self.now]
            credentials._time_fetcher = lambda: clock[0]

            def sign():
                request = AWSRequest(method="POST", url="https://bedrock-runtime.ap-south-1.amazonaws.com/model/test/converse", data=b"{}")
                client._request_signer.sign("Converse", request)
                return request.headers["Authorization"]

            first = sign()
            self.assertIn("ASIAEXAMPLE000000001", first)
            self.assertEqual(self.counter.read_text(), "1")
            clock[0] += timedelta(minutes=2)  # 14 minutes remaining -> SDK refresh.
            self.set_control("ok", self.now + timedelta(minutes=60))
            second = sign()
            self.assertIn("ASIAEXAMPLE000000002", second)
            self.assertIs(adapter._ensure_client(), client)
            self.assertEqual(self.counter.read_text(), "2")
            self.set_control("fail", self.now + timedelta(minutes=60))
            clock[0] = self.now + timedelta(minutes=61)
            with self.assertRaises(CredentialRetrievalError) as error:
                sign()
            self.assertNotIn("PRIVATE_DIAGNOSTIC_SENTINEL", str(error.exception))

    def test_helper_error_and_invalid_credentials_are_redacted(self):
        for mode in ("fail", "malformed", "no-expiry"):
            with self.subTest(mode=mode):
                self.set_control(mode, self.now + timedelta(minutes=60))
                result = self.invoke()
                self.assertEqual(result.returncode, 1)
                self.assertEqual(result.stdout, "")
                self.assertEqual(result.stderr, "home-server credential refresh failed\n")

    def test_expired_or_excessively_long_credentials_fail(self):
        for minutes in (-1, 120):
            with self.subTest(minutes=minutes):
                self.set_control("ok", self.now + timedelta(minutes=minutes))
                self.assertEqual(self.invoke().returncode, 1)

    def test_tampered_helper_is_not_executed(self):
        self.helper.write_text(self.helper.read_text() + "\n# modified\n")
        self.assertEqual(self.invoke().returncode, 1)
        self.assertEqual(self.counter.read_text(), "0")

    def test_world_readable_or_missing_key_fails(self):
        self.key.chmod(0o644)
        self.assertEqual(self.invoke().returncode, 1)
        self.key.unlink()
        self.assertEqual(self.invoke().returncode, 1)
        self.assertEqual(self.counter.read_text(), "0")

    def test_no_admin_irsa_or_container_credentials(self):
        for key in ("AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY", "AWS_SESSION_TOKEN",
                    "AWS_WEB_IDENTITY_TOKEN_FILE", "AWS_CONTAINER_CREDENTIALS_FULL_URI", "AWS_ROLE_ARN"):
            with self.subTest(key=key), self.assertRaises(ValueError):
                config_module.home_server_environment(str(self.config), "bedrock", {key: "fixture"})
        env = config_module.home_server_environment(str(self.config), "bedrock", {"AWS_PROFILE": "saa"})
        self.assertEqual(env["AWS_PROFILE"], "home-server-bedrock")
        self.assertEqual(env["AWS_SHARED_CREDENTIALS_FILE"], "/dev/null")
        self.assertEqual(env["AWS_EC2_METADATA_DISABLED"], "true")

    def test_config_cannot_mix_profiles_or_use_source_profile(self):
        with self.assertRaises(ValueError):
            config_module.home_server_environment(str(self.config), "backup", {})
        self.config.write_text(self.config.read_text() + "source_profile = saa\n")
        with self.assertRaises(ValueError):
            config_module.home_server_environment(str(self.config), "bedrock", {})

    def test_render_rejects_swapped_role_account_and_injection(self):
        for field, value in (("role_arn", self.metadata["backup"]["role_arn"]),
                             ("profile_arn", self.metadata["bedrock"]["profile_arn"].replace("957261948820", "111111111111")),
                             ("trust_anchor_arn", "fake\ncredential_process = command")):
            with self.subTest(field=field):
                item = {**self.metadata["bedrock"], field: value}
                with self.assertRaises(ValueError):
                    config_module.home_server_config({"bedrock": item}, "bedrock")


if __name__ == "__main__":
    unittest.main()
