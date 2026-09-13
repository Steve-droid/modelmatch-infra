"""Offline issuer transactions with disposable keys; live network/Keychain forbidden."""

import copy
import base64
import ctypes
from datetime import timedelta
import importlib.util
import io
import json
from pathlib import Path
import shutil
import socket
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.x509.oid import NameOID

ROOT = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("home_server_issuer", ROOT / "home-server-issuer.py")
issuer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(issuer)
renew = issuer.load("home_server_renew", "home-server-renew.py")


class FakeKeychain:
    def __init__(self, value=None):
        self.value, self.adds = value, 0

    def get(self):
        return self.value

    def add(self, value):
        if self.value is not None:
            raise ValueError("duplicate item")
        self.value, self.adds = value, self.adds + 1


class FakeAWS:
    def __init__(self):
        self.objects, self.reads, self.writes = {}, [], 0
        self.corrupt, self.fail = False, False

    def client(self, service):
        if service not in ("sts", "s3"):
            raise AssertionError("unapproved service")
        return self

    def get_caller_identity(self):
        return {"Arn": issuer.OPERATOR}

    def put_object(self, **request):
        if self.fail:
            raise RuntimeError("PRIVATE_SENTINEL")
        self.writes += 1
        version = "fixture-version-" + str(self.writes)
        self.objects[(request["Bucket"], request["Key"], version)] = request["Body"]
        return {"VersionId": version}

    def get_object(self, **request):
        self.reads.append(request)
        data = self.objects[(request["Bucket"], request["Key"], request["VersionId"])]
        return {"Body": io.BytesIO(b"corrupt" if self.corrupt else data)}


class HomeServerIssuerTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.instant = issuer.now()
        cls.age = shutil.which("age")
        cls.age_private = issuer.custody.run([shutil.which("age-keygen")])
        cls.recipient = issuer.custody.recipient(cls.age_private)
        cls.leaf_key = rsa.generate_private_key(public_exponent=65537, key_size=3072)

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="home-server-issuer-test-")
        self.addCleanup(self.tmp.cleanup)
        self.folder = Path(self.tmp.name)
        self.config = {"ledger": str(self.folder / "ledger.json"),
                       "ca_certificate": str(self.folder / "issuer.crt"),
                       "ca_sha256": "REPLACE_WITH_VERIFIED_PUBLIC_CA_FINGERPRINT",
                       "encrypted_backup_directory": str(self.folder / "encrypted"),
                       "age_binary": self.age, "recovery_recipient": self.recipient,
                       "backup_bucket": issuer.BUCKET, "aws_profile": "fixture", "keychain": "fixture"}
        self.keychain, self.aws = FakeKeychain(), FakeAWS()
        self.addCleanup(patch.stopall)
        patch.object(socket.socket, "connect", side_effect=AssertionError("network forbidden")).start()
        patch.object(issuer.custody.LocalKeychain, "__init__", side_effect=AssertionError("real Keychain forbidden")).start()
        patch("boto3.Session", return_value=self.aws).start()

    def enroll(self):
        self.key, self.ca, self.ledger = issuer.enroll(self.config, self.keychain, self.instant)
        self.config["ca_sha256"] = self.ledger["ca_sha256"]
        return self.ledger

    def issue_leaf(self, identity="backup"):
        csr = (x509.CertificateSigningRequestBuilder().subject_name(x509.Name([
            x509.NameAttribute(NameOID.COMMON_NAME, "driftplain-home-server-" + identity)]))
            .sign(self.leaf_key, hashes.SHA256()).public_bytes(serialization.Encoding.PEM).decode())
        cert = renew.issue(csr, identity, self.key, self.ca, self.instant)
        self.ledger["issued"].append({"identity": identity, "certificate": cert,
                                      "previous_serial": None, "created_at": self.instant.isoformat()})
        return x509.load_pem_x509_certificate(cert.encode())

    def archive(self, ledger=None):
        value = self.ledger if ledger is None else ledger
        return renew.HomeServerOperations(self.config, self.key, self.ca).backup(value)

    def recovered(self, receipt, digest=None):
        data = issuer.fetch_bundle(self.aws, receipt, self.config)
        return issuer.recover_bundle(data, self.age_private, self.config,
                                     digest or receipt["ledger_sha256"], self.instant)

    def test_enroll_retry_recovers_missing_public_files_same_ca(self):
        self.enroll()
        original = self.keychain.value
        Path(self.config["ca_certificate"]).unlink()
        Path(self.config["ca_certificate"]).with_suffix(".sha256").unlink()
        key, ca, ledger = issuer.enroll(self.config, self.keychain, self.instant + timedelta(hours=1))
        self.assertEqual(issuer.private_pem(key), original)
        self.assertEqual(issuer.pem(ca), issuer.pem(self.ca))
        self.assertEqual(ledger, self.ledger)
        self.assertEqual(self.keychain.adds, 1)

    def test_missing_key_with_surviving_ledger_or_config_pin_never_generates(self):
        self.enroll()
        self.keychain.value = None
        with patch.object(issuer.rsa, "generate_private_key", side_effect=AssertionError("must not regenerate")):
            with self.assertRaises(ValueError):
                issuer.enroll(self.config, self.keychain, self.instant)
            for path in (Path(self.config["ledger"]), Path(self.config["ca_certificate"]),
                         Path(self.config["ca_certificate"]).with_suffix(".sha256")):
                path.unlink()
            with self.assertRaises(ValueError):
                issuer.enroll(self.config, self.keychain, self.instant)

    def test_missing_ledger_with_key_cannot_reset_history(self):
        self.enroll()
        Path(self.config["ledger"]).unlink()
        with self.assertRaises(FileNotFoundError):
            issuer.enroll(self.config, self.keychain, self.instant)
        self.assertEqual(self.keychain.adds, 1)

    def test_custody_response_loss_retries_same_key(self):
        add = self.keychain.add
        def lost(value):
            add(value)
            raise RuntimeError("response lost")
        with patch.object(self.keychain, "add", side_effect=lost):
            with self.assertRaises(RuntimeError):
                issuer.enroll(self.config, self.keychain, self.instant)
        original = self.keychain.value
        self.enroll()
        self.assertEqual(self.keychain.value, original)
        self.assertEqual(self.keychain.adds, 1)

    def test_failed_custody_preserves_journal_and_stops_without_replacement(self):
        with patch.object(self.keychain, "add", side_effect=RuntimeError("locked")):
            with self.assertRaises(RuntimeError):
                issuer.enroll(self.config, self.keychain, self.instant)
        self.assertTrue(Path(self.config["ledger"]).exists())
        with self.assertRaises(ValueError):
            issuer.enroll(self.config, self.keychain, self.instant)
        self.assertIsNone(self.keychain.value)

    def test_existing_public_mismatch_not_overwritten(self):
        self.enroll()
        path = Path(self.config["ca_certificate"])
        path.write_text("different")
        with self.assertRaises(ValueError):
            issuer.enroll(self.config, self.keychain, self.instant)
        self.assertEqual(path.read_text(), "different")

    def test_native_api_missing_locked_duplicate_and_free_content(self):
        # Exercise the actual ctypes adapter against fake native calls, not Keychain.
        native = object.__new__(issuer.IssuerKeychain)
        native.ref, native.service, native.account = None, issuer.ISSUER_SERVICE.encode(), b"steve"
        from unittest.mock import Mock
        native.api = Mock()
        native.api.SecKeychainFindGenericPassword.return_value = -25300
        self.assertIsNone(native.get())
        native.api.SecKeychainFindGenericPassword.return_value = -25308
        with self.assertRaises(issuer.custody.CustodyError):
            native.get()
        self.enroll()
        buffer = ctypes.create_string_buffer(self.keychain.value)
        def find(*args):
            ctypes.cast(args[5], ctypes.POINTER(ctypes.c_uint32))[0] = len(self.keychain.value)
            ctypes.cast(args[6], ctypes.POINTER(ctypes.c_void_p))[0] = ctypes.addressof(buffer)
            return 0
        native.api.SecKeychainFindGenericPassword.side_effect = find
        self.assertEqual(native.get(), self.keychain.value)
        native.api.SecKeychainItemFreeContent.assert_called_once()
        native.api.SecKeychainAddGenericPassword.return_value = -25299
        with self.assertRaises(issuer.custody.CustodyError):
            native.add(self.keychain.value)
        with self.assertRaises(ValueError):
            native.add(self.age_private)

    def test_ca_pair_fingerprint_constraints_validity_and_strict_pem(self):
        self.enroll()
        with self.assertRaises(ValueError):
            issuer.validate_ca(self.leaf_key, self.ca, self.ledger["ca_sha256"], self.instant)
        with self.assertRaises(ValueError):
            issuer.validate_ca(self.key, self.ca, "0" * 64, self.instant)
        with self.assertRaises(ValueError):
            issuer.validate_ca(self.key, self.ca, self.ledger["ca_sha256"], self.instant + timedelta(days=731))
        with self.assertRaises(ValueError):
            issuer.private_key(self.keychain.value + self.keychain.value)
        bad = (x509.CertificateBuilder().subject_name(self.ca.subject).issuer_name(self.ca.subject)
               .public_key(self.key.public_key()).serial_number(123)
               .not_valid_before(self.instant).not_valid_after(self.instant + timedelta(days=730))
               .add_extension(x509.BasicConstraints(True, 1), True)
               .add_extension(x509.KeyUsage(False, False, False, False, False, True, False, False, False), True)
               .sign(self.key, hashes.SHA256()))
        with self.assertRaises(ValueError):
            issuer.validate_ca(self.key, bad, bad.fingerprint(hashes.SHA256()).hex(), self.instant)

    def test_full_recovery_independent_of_original_keychain_and_files(self):
        self.enroll()
        first = self.issue_leaf()
        self.issue_leaf("bedrock")
        issuer.make_crl(self.ledger, self.key, self.ca, self.instant, str(first.serial_number))
        receipt = self.archive()
        original_key, original_ledger = self.keychain.value, copy.deepcopy(self.ledger)
        self.keychain.value = None
        for path in (Path(self.config["ledger"]), Path(self.config["ca_certificate"]),
                     Path(self.config["ca_certificate"]).with_suffix(".sha256")):
            path.unlink()
        key, ca, ledger = self.recovered(receipt)
        replacement = FakeKeychain()
        issuer.restore(self.config, replacement, key, ca, ledger)
        issuer.restore(self.config, replacement, key, ca, ledger)
        self.assertEqual(replacement.value, original_key)
        self.assertEqual(replacement.adds, 1)
        self.assertEqual(ledger, original_ledger)
        self.assertEqual(json.loads(Path(self.config["ledger"]).read_text()), original_ledger)
        self.assertEqual(self.aws.reads[-1]["VersionId"], receipt["version_id"])
        for path in self.folder.rglob("*"):
            if path.is_file():
                self.assertNotIn(b"BEGIN PRIVATE KEY", path.read_bytes())

    def test_wrong_recovery_identity_and_stale_checkpoint_rejected(self):
        self.enroll()
        receipt = self.archive()
        data = issuer.fetch_bundle(self.aws, receipt, self.config)
        wrong = issuer.custody.run([shutil.which("age-keygen")])
        with self.assertRaises(ValueError):
            issuer.recover_bundle(data, wrong, self.config, receipt["ledger_sha256"], self.instant)
        self.issue_leaf()
        with self.assertRaises(ValueError):
            self.recovered(receipt, issuer.sha(issuer.canonical(self.ledger)))

    def test_surviving_newer_ledger_or_other_key_blocks_restore(self):
        self.enroll()
        receipt = self.archive()
        recovered = self.recovered(receipt)
        self.issue_leaf()
        issuer.save_ledger(Path(self.config["ledger"]), self.ledger)
        with self.assertRaises(ValueError):
            issuer.restore(self.config, self.keychain, *recovered)
        Path(self.config["ledger"]).unlink()
        other = FakeKeychain(issuer.private_pem(self.leaf_key))
        with self.assertRaises(ValueError):
            issuer.restore(self.config, other, *recovered)
        self.assertEqual(other.adds, 0)

    def test_ledger_tampering_and_unknown_revocation_rejected(self):
        self.enroll()
        cert = self.issue_leaf()
        for change in (lambda value: value["issued"].append(value["issued"][0]),
                       lambda value: value["issued"][0].update(identity="bedrock"),
                       lambda value: value["signing"].update(leaf_days=365),
                       lambda value: value["revoked"].append({"serial": "123", "reason": "key_compromise"})):
            value = copy.deepcopy(self.ledger)
            change(value)
            with self.assertRaises(ValueError):
                issuer.validate_ledger(value, self.ca)
        with self.assertRaises(ValueError):
            issuer.make_crl(self.ledger, self.key, self.ca, self.instant, str(cert.serial_number + 1))

    def test_backup_failure_retry_receipt_and_corruption(self):
        self.enroll()
        self.aws.fail = True
        with self.assertRaises(RuntimeError):
            self.archive()
        self.assertEqual(len(list((self.folder / "encrypted").glob("*.age"))), 1)
        self.assertFalse(list((self.folder / "encrypted").glob("*.receipt.json")))
        self.aws.fail = False
        receipt = self.archive()
        self.assertEqual(self.archive(), receipt)
        self.assertEqual(self.aws.writes, 1)
        self.aws.corrupt = True
        with self.assertRaises(ValueError):
            self.archive()
        with self.assertRaises(ValueError):
            self.recovered(receipt)

    def test_receipt_destination_version_and_fingerprint_mismatches(self):
        self.enroll()
        receipt = self.archive()
        for field, value in (("bucket", "other"), ("version_id", "null"), ("object_key", "postgres/wrong"),
                             ("ca_sha256", "bad"), ("recovery_key_id", "other"), ("recovery_recipient", "wrong")):
            with self.subTest(field=field), self.assertRaises(ValueError):
                issuer.fetch_bundle(self.aws, {**receipt, field: value}, self.config)

    def test_crl_retry_full_history_expiry_and_wrong_signer(self):
        self.enroll()
        cert = self.issue_leaf()
        first = issuer.make_crl(self.ledger, self.key, self.ca, self.instant, str(cert.serial_number))
        second = issuer.make_crl(self.ledger, self.key, self.ca, self.instant, str(cert.serial_number))
        self.assertEqual(len(self.ledger["revoked"]), 1)
        self.assertEqual(self.ledger["crl_number"], 2)
        self.assertIsNotNone(issuer.validate_crl(second, self.ca, self.ledger, self.instant)
                             .get_revoked_certificate_by_serial_number(cert.serial_number))
        with self.assertRaises(ValueError):
            issuer.validate_crl(first, self.ca, self.ledger, self.instant)
        with self.assertRaises(ValueError):
            issuer.validate_crl(second, self.ca, self.ledger, self.instant + timedelta(days=35))
        with self.assertRaises(ValueError):
            issuer.make_crl(self.ledger, self.leaf_key, self.ca, self.instant)

    def test_openssl_independently_accepts_ca_and_rejects_revoked_leaf(self):
        self.enroll()
        revoked, good = self.issue_leaf(), self.issue_leaf("bedrock")
        crl = issuer.make_crl(self.ledger, self.key, self.ca, self.instant, str(revoked.serial_number))
        (self.folder / "issuer.crl").write_bytes(crl)
        (self.folder / "revoked.crt").write_text(issuer.pem(revoked))
        (self.folder / "good.crt").write_text(issuer.pem(good))
        base = ["openssl", "verify", "-CAfile", str(self.folder / "issuer.crt")]
        self.assertEqual(subprocess.run(base + [str(self.folder / "issuer.crt")], capture_output=True).returncode, 0)
        base += ["-CRLfile", str(self.folder / "issuer.crl"), "-crl_check"]
        self.assertEqual(subprocess.run(base + [str(self.folder / "good.crt")], capture_output=True).returncode, 0)
        result = subprocess.run(base + [str(self.folder / "revoked.crt")], capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(b"certificate revoked", result.stderr + result.stdout)

    def test_revoked_pending_leaf_removed_and_current_refused_by_renewer(self):
        self.enroll()
        cert = self.issue_leaf()
        self.ledger["pending"]["backup"] = {key: value for key, value in self.ledger["issued"][0].items() if key != "identity"}
        issuer.make_crl(self.ledger, self.key, self.ca, self.instant, str(cert.serial_number))
        self.assertEqual(self.ledger["pending"], {})
        issuer.validate_ledger(self.ledger, self.ca)
        with self.assertRaises(ValueError):
            renew.renew_identity("backup", self.ledger, lambda _: self.fail("save"),
                                 lambda *_: {"certificate": issuer.pem(cert)}, lambda _: self.fail("backup"),
                                 self.key, self.ca, self.instant)

    def test_cloud_crl_readback_checks_binding_enabled_data_and_expiry(self):
        self.enroll()
        crl = issuer.make_crl(self.ledger, self.key, self.ca, self.instant)
        arn = "arn:aws:rolesanywhere:ap-south-1:957261948820:trust-anchor/11111111-1111-1111-1111-111111111111"
        crl_id = "22222222-2222-2222-2222-222222222222"
        anchor = {"trustAnchor": {"trustAnchorArn": arn, "enabled": False,
                  "source": {"sourceType": "CERTIFICATE_BUNDLE", "sourceData": {"x509CertificateData": issuer.pem(self.ca)}}}}
        record = {"crl": {"trustAnchorArn": arn, "crlId": crl_id,
                         "enabled": True, "crlData": base64.b64encode(crl).decode()}}
        issuer.verify_cloud_crl(anchor, record, arn, crl_id, self.ledger, self.instant)
        for field, value in (("enabled", False), ("trustAnchorArn", arn + "x"),
                             ("crlId", "wrong"), ("crlData", base64.b64encode(b"wrong").decode())):
            bad = {"crl": {**record["crl"], field: value}}
            with self.subTest(field=field), self.assertRaises(ValueError):
                issuer.verify_cloud_crl(anchor, bad, arn, crl_id, self.ledger, self.instant)
        bad_anchor = copy.deepcopy(anchor)
        bad_anchor["trustAnchor"]["source"]["sourceData"]["x509CertificateData"] = issuer.pem(self.issue_leaf())
        with self.assertRaises(ValueError):
            issuer.verify_cloud_crl(bad_anchor, record, arn, crl_id, self.ledger, self.instant)
        with self.assertRaises(ValueError):
            issuer.verify_cloud_crl(anchor, record, arn, crl_id, self.ledger, self.instant + timedelta(days=35))

    def cli(self, command, *args):
        config = self.folder / "config.json"
        config.write_text(json.dumps(self.config))
        (self.folder / "recovery-key-v1.recipient").write_text(self.recipient)
        with patch.object(issuer, "ROOT", self.folder), patch.object(issuer, "load", return_value=renew), \
                patch.object(issuer, "IssuerKeychain", return_value=self.keychain), \
                patch.object(issuer, "now", return_value=self.instant), patch("sys.stdout", new_callable=io.StringIO) as output, \
                patch("sys.argv", ["issuer", command, "--config", str(config), *args]):
            result = issuer.main()
            return result, json.loads(output.getvalue())

    def test_cli_failed_backup_preserves_revocation_then_retry_publishes_full_crl(self):
        self.enroll()
        cert = self.issue_leaf()
        issuer.save_ledger(Path(self.config["ledger"]), self.ledger)
        self.aws.fail = True
        with self.assertRaises(RuntimeError):
            self.cli("revoke", "--serial", str(cert.serial_number))
        saved = json.loads(Path(self.config["ledger"]).read_text())
        self.assertEqual(saved["revoked"][0]["serial"], str(cert.serial_number))
        self.assertFalse(list(self.folder.glob("issuer-crl-*.pem")))
        self.aws.fail = False
        result, report = self.cli("crl")
        self.assertEqual(result, 0)
        self.assertEqual(report["revoked_count"], 1)
        self.assertEqual(report["crl_number"], 2)
        self.assertEqual(len(list(self.folder.glob("issuer-crl-*.pem"))), 1)
        self.assertNotIn("PRIVATE", json.dumps(report))
        self.recovered(report["receipt"])

    def test_shared_ledger_lock_prevents_concurrent_enrollment(self):
        import fcntl
        state = Path(self.config["ledger"])
        with state.with_suffix(".lock").open("a") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            with self.assertRaises(BlockingIOError):
                self.cli("enroll")
        self.assertIsNone(self.keychain.value)

    def test_cli_errors_never_print_private_diagnostics(self):
        config = self.folder / "bad.json"
        config.write_text("PRIVATE_SENTINEL invalid JSON")
        result = subprocess.run([sys.executable, str(ROOT / "home-server-issuer.py"), "enroll", "--config", str(config)],
                                capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 1)
        self.assertNotIn(b"PRIVATE_SENTINEL", result.stdout + result.stderr)
        self.assertNotIn(b"Traceback", result.stderr)

    def test_null_s3_version_and_tampered_cached_receipt_fail_closed(self):
        self.enroll()
        with patch.object(self.aws, "put_object", return_value={"VersionId": "null"}):
            with self.assertRaises(ValueError):
                self.archive()
        self.archive()
        path = next((self.folder / "encrypted").glob("*.receipt.json"))
        receipt = json.loads(path.read_text())
        receipt["ledger_sha256"] = "stale"
        path.write_text(json.dumps(receipt))
        with self.assertRaises(ValueError):
            self.archive()

    def test_renewal_cannot_accept_current_leaf_missing_from_recovered_history(self):
        self.enroll()
        cert = self.issue_leaf()
        self.ledger["issued"] = []
        with self.assertRaises(ValueError):
            renew.renew_identity("backup", self.ledger, lambda _: self.fail("save"),
                                 lambda *_: {"certificate": issuer.pem(cert)}, lambda _: self.fail("backup"),
                                 self.key, self.ca, self.instant)


if __name__ == "__main__":
    unittest.main()
