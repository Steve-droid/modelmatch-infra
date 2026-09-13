"""Disposable local issuer/leaf fixtures; no real Keychain, SSH, S3 or cluster calls."""

import base64
from datetime import datetime, timedelta, timezone
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import shutil
import subprocess
import unittest
from unittest.mock import patch

from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.x509.oid import NameOID

ROOT = Path(__file__).resolve().parent


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


renew = load("home_server_renew", ROOT / "home-server-renew.py")
leaf = load("home_server_leaf", ROOT / "home-server-leaf.py")


class HomeServerRenewalTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.instant = datetime.now(timezone.utc)
        cls.key = rsa.generate_private_key(public_exponent=65537, key_size=3072)
        cls.leaf_key = rsa.generate_private_key(public_exponent=65537, key_size=3072)
        cls.ca_name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "driftplain-home-server-issuer-v1")])
        cls.issuer = (x509.CertificateBuilder().subject_name(cls.ca_name).issuer_name(cls.ca_name)
                      .public_key(cls.key.public_key()).serial_number(x509.random_serial_number())
                      .not_valid_before(cls.instant - timedelta(days=300)).not_valid_after(cls.instant + timedelta(days=400))
                      .add_extension(x509.BasicConstraints(True, 0), True)
                      .add_extension(x509.KeyUsage(False, False, False, False, False, True, True, False, False), True)
                      .sign(cls.key, hashes.SHA256()))

    def csr(self, identity="bedrock", request_ca=False):
        builder = x509.CertificateSigningRequestBuilder().subject_name(x509.Name([
            x509.NameAttribute(NameOID.COMMON_NAME, "driftplain-home-server-" + identity)]))
        if request_ca:
            builder = builder.add_extension(x509.BasicConstraints(True, 0), True)
        return builder.sign(self.leaf_key, hashes.SHA256()).public_bytes(serialization.Encoding.PEM).decode()

    def setUp(self):
        self.ledger = {"version": 2, "signing": dict(renew.issuer_tools.SIGNING),
                       "ca_sha256": self.issuer.fingerprint(hashes.SHA256()).hex(),
                       "issuer_certificate": renew.issuer_tools.pem(self.issuer),
                       "crl_number": 0, "pending": {}, "issued": [], "revoked": []}
        self.current = renew.issue(self.csr(), "bedrock", self.key, self.issuer, self.instant - timedelta(days=61))
        self.ledger["issued"].append({"identity": "bedrock", "certificate": self.current})
        self.backups = []
        self.installs = []
        self.saves = []

    def remote(self, operation, identity, cert=None):
        if operation == "status":
            return {"certificate": self.current}
        if operation == "prepare":
            return {"csr": self.csr(identity)}
        if operation == "install":
            self.installs.append(cert)
            self.current = cert
            return {"installed": True}
        raise AssertionError(operation)

    def save(self, value):
        self.saves.append(json.loads(json.dumps(value)))

    def backup(self, value):
        self.backups.append(json.loads(json.dumps(value)))

    def run_renewal(self, remote=None, backup=None):
        return renew.renew_identity("bedrock", self.ledger, self.save, remote or self.remote,
                                    backup or self.backup, self.key, self.issuer, self.instant)

    def test_not_due_does_not_issue_backup_or_install(self):
        self.current = renew.issue(self.csr(), "bedrock", self.key, self.issuer, self.instant - timedelta(days=59))
        self.ledger["issued"] = [{"identity": "bedrock", "certificate": self.current}]
        self.assertEqual(self.run_renewal(), "not-due")
        self.assertFalse(self.installs or self.backups or self.saves)

    def test_due_renews_and_repeat_run_is_noop(self):
        self.assertEqual(self.run_renewal(), "renewed")
        cert = x509.load_pem_x509_certificate(self.current.encode())
        self.assertAlmostEqual((cert.not_valid_after_utc - self.instant).total_seconds(), 90 * 86400, delta=1)
        self.assertEqual(len(self.ledger["issued"]), 2)
        self.assertFalse(self.ledger["pending"])
        self.assertIn("bedrock", self.backups[0]["pending"])
        self.assertEqual(self.run_renewal(), "not-due")
        self.assertEqual(len(self.installs), 1)

    def test_backup_failure_prevents_delivery_and_retry_reuses_serial(self):
        with self.assertRaises(RuntimeError):
            self.run_renewal(backup=lambda _: (_ for _ in ()).throw(RuntimeError("S3 unavailable")))
        self.assertFalse(self.installs)
        pending = self.ledger["pending"]["bedrock"]["certificate"]
        self.assertEqual(self.run_renewal(), "renewed")
        self.assertEqual(self.installs, [pending])
        self.assertEqual(len(self.ledger["issued"]), 2)

    def test_lost_install_response_reconciles_without_reissue(self):
        def lost(operation, identity, cert=None):
            result = self.remote(operation, identity, cert)
            if operation == "install":
                raise RuntimeError("SSH response lost")
            return result
        with self.assertRaises(RuntimeError):
            self.run_renewal(remote=lost)
        issued = self.current
        self.assertEqual(self.run_renewal(), "renewed")
        self.assertEqual(self.current, issued)
        self.assertEqual(len(self.ledger["issued"]), 2)

    def test_final_backup_failure_is_marked_for_retry(self):
        def backup(value):
            self.backup(value)
            if len(self.backups) == 2:
                raise RuntimeError("S3 unavailable")
        with self.assertRaises(RuntimeError):
            self.run_renewal(backup=backup)
        self.assertTrue(self.ledger["backup_required"])
        self.assertFalse(self.ledger["pending"])
        self.assertEqual(len(self.installs), 1)

    def test_stale_journal_cannot_replace_a_different_new_certificate(self):
        with self.assertRaises(RuntimeError):
            self.run_renewal(backup=lambda _: (_ for _ in ()).throw(RuntimeError("offline")))
        self.current = renew.issue(self.csr(), "bedrock", self.key, self.issuer, self.instant)
        self.ledger["issued"].append({"identity": "bedrock", "certificate": self.current})
        with self.assertRaises(ValueError):
            self.run_renewal()
        self.assertFalse(self.installs)

    def test_wrong_subject_rejected_and_csr_ca_extension_ignored(self):
        with self.assertRaises(ValueError):
            renew.issue(self.csr("backup"), "bedrock", self.key, self.issuer, self.instant)
        cert = x509.load_pem_x509_certificate(renew.issue(self.csr(request_ca=True), "bedrock", self.key, self.issuer, self.instant).encode())
        self.assertFalse(cert.extensions.get_extension_for_class(x509.BasicConstraints).value.ca)

    def test_insufficient_issuer_validity_rejected(self):
        with self.assertRaises(ValueError):
            renew.issue(self.csr(), "bedrock", self.key, self.issuer, self.instant + timedelta(days=311))

    def test_locked_keychain_records_failure_and_notifies_without_secret_output(self):
        with tempfile.TemporaryDirectory() as folder:
            state = Path(folder) / "ledger.json"
            state.write_text(json.dumps(self.ledger))
            config = Path(folder) / "config.json"
            config.write_text(json.dumps({"enabled": True, "ledger": str(state),
                                         "backup_bucket": "modelmatch-home-server-backups-957261948820",
                                         "recovery_recipient": (ROOT / "recovery-key-v1.recipient").read_text().strip()}))
            with patch("sys.argv", ["renew", "--config", str(config)]), patch.object(renew, "read_issuer", side_effect=RuntimeError("PRIVATE_SENTINEL")), patch.object(renew.subprocess, "run") as notify, patch("sys.stderr") as stderr:
                self.assertEqual(renew.main(), 1)
            self.assertEqual(json.loads(state.with_suffix(".status.json").read_text())["status"], "failed")
            self.assertEqual(notify.call_count, 1)
            self.assertNotIn("PRIVATE_SENTINEL", str(stderr.write.call_args_list))

    def test_issuer_bundle_is_encrypted_and_exact_s3_version_verified(self):
        # Fresh disposable age key, unrelated to the completed recovery-key custody.
        age = shutil.which("age")
        age_keygen = shutil.which("age-keygen")
        self.assertIsNotNone(age)
        private = subprocess.run([age_keygen], capture_output=True, check=True).stdout
        recipient = subprocess.run([age_keygen, "-y"], input=private, capture_output=True, check=True).stdout.decode().strip()
        objects = {}
        class FakeAWS:
            def client(self, service):
                return self
            def get_caller_identity(self):
                return {"Arn": "arn:aws:iam::957261948820:user/steve"}
            def put_object(self, **request):
                objects[request["Key"]] = request["Body"]
                return {"VersionId": "fixture-version"}
            def get_object(self, **request):
                if request["VersionId"] != "fixture-version":
                    raise AssertionError("version not pinned")
                return {"Body": io.BytesIO(objects[request["Key"]])}
        with tempfile.TemporaryDirectory() as folder:
            config = {"encrypted_backup_directory": folder, "recovery_recipient": recipient,
                      "age_binary": age, "aws_profile": "fixture", "backup_bucket": "fixture"}
            operation = renew.HomeServerOperations(config, self.key, self.issuer)
            with patch("boto3.Session", return_value=FakeAWS()):
                operation.backup(self.ledger)
                operation.backup(self.ledger)
            self.assertEqual(len(objects), 1)
            archive = next(Path(folder).glob("*.age"))
            bundle = json.loads(subprocess.run([age, "--decrypt", "-i", "-", str(archive)],
                                              input=private, capture_output=True, check=True).stdout)
            restored_key = serialization.load_pem_private_key(bundle["issuer_private_key"].encode(), password=None)
            self.assertEqual(restored_key.private_numbers(), self.key.private_numbers())
            self.assertEqual(bundle["ledger"], self.ledger)
            for path in Path(folder).iterdir():
                self.assertNotIn(b"BEGIN PRIVATE KEY", path.read_bytes())

    def test_home_delivery_pairs_keys_and_retries_failed_rollout(self):
        # Real local OpenSSL generates pending key/CSR and verifies the signed leaf.
        # Kubernetes API is an in-memory fake, never the home or AWS cluster.
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            (root / "issuer.crt").write_bytes(self.issuer.public_bytes(serialization.Encoding.PEM))
            secret = {"metadata": {"name": "home-server-bedrock-identity", "resourceVersion": "1"},
                      "data": {"tls.crt": base64.b64encode(self.current.encode()).decode(), "tls.key": "RklYVFVSRQ=="}}
            fail_rollout = [True]
            def kubectl(namespace, *args, payload=None):
                self.assertEqual(namespace, "app")
                if args[0] == "get":
                    return json.dumps(secret).encode()
                if args[0] == "replace":
                    secret.update(json.loads(payload))
                elif args[0] == "rollout" and fail_rollout[0]:
                    raise RuntimeError("rollout delayed")
                return b"{}"
            with patch.object(leaf, "HOME_SERVER_ROOT", root), patch.object(leaf, "kubectl", side_effect=kubectl):
                csr = leaf.leaf("prepare", "bedrock")["csr"]
                wrong_key = renew.issue(self.csr(), "bedrock", self.key, self.issuer, self.instant).encode()
                with self.assertRaises(ValueError):
                    leaf.leaf("install", "bedrock", wrong_key)
                self.assertEqual(leaf.leaf("status", "bedrock")["certificate"], self.current)
                signed = renew.issue(csr, "bedrock", self.key, self.issuer, self.instant).encode()
                with self.assertRaises(RuntimeError):
                    leaf.leaf("install", "bedrock", signed)
                self.assertTrue((root / "bedrock/pending.key").exists())
                fail_rollout[0] = False
                self.assertTrue(leaf.leaf("install", "bedrock", signed)["installed"])
                self.assertFalse((root / "bedrock/pending.key").exists())
                self.assertEqual(leaf.leaf("status", "bedrock")["certificate"], signed.decode())


if __name__ == "__main__":
    unittest.main()
