"""Disposable age identities only; no AWS/Keychain mutation or production data."""
import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("home_server_recovery_key", Path(__file__).with_name("recovery-key.py"))
custody = importlib.util.module_from_spec(spec)
spec.loader.exec_module(custody)


class MemoryKeychain:
    def __init__(self):
        self.identity = None
        self.adds = 0

    def get(self):
        return self.identity

    def add(self, identity):
        if self.identity is not None:
            raise AssertionError("Must never overwrite")
        self.identity = identity
        self.adds += 1


class RecoveryKeyTests(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.TemporaryDirectory(prefix="home-server-key-tests-")
        self.addCleanup(self.folder.cleanup)
        self.public = Path(self.folder.name) / "recipient.txt"
        self.keychain = MemoryKeychain()

    def test_prepare_retry_preserves_key_and_only_writes_public_file(self):
        first = custody.prepare(self.keychain, self.public)
        second = custody.prepare(self.keychain, self.public)
        self.assertTrue(first["keychain_created"])
        self.assertFalse(second["keychain_created"])
        self.assertEqual(first["recipient"], second["recipient"])
        self.assertEqual(self.keychain.adds, 1)
        self.assertEqual(list(Path(self.folder.name).iterdir()), [self.public])
        self.assertNotIn(b"AGE-SECRET", self.public.read_bytes())
        self.assertTrue(custody.verify(self.keychain.get(), first["recipient"])["decryption_verified"])

    def test_existing_recipient_with_missing_key_refuses_regeneration(self):
        self.public.write_text("age1existing\n")
        with self.assertRaises(custody.CustodyError):
            custody.prepare(self.keychain, self.public)
        self.assertEqual(self.keychain.adds, 0)

    def test_different_recipient_is_not_overwritten(self):
        custody.prepare(self.keychain, self.public)
        self.public.write_text("age1different\n")
        with self.assertRaises(custody.CustodyError):
            custody.prepare(self.keychain, self.public)
        self.assertEqual(self.public.read_text(), "age1different\n")

    def test_correct_key_wrong_key_and_corrupt_ciphertext(self):
        first = custody.prepare(self.keychain, self.public)
        identity = self.keychain.get()
        wrong = custody.validate_identity(custody.run(["age-keygen"]))
        encrypted = custody.run(["age", "-r", first["recipient"]], b"fixture")
        cipher_path = Path(self.folder.name) / "fixture.age"
        cipher_path.write_bytes(encrypted)
        with self.assertRaises(custody.CustodyError):
            custody.run(["age", "-d", "-i", "-", str(cipher_path)], wrong)
        cipher_path.write_bytes(encrypted[:-1] + bytes([encrypted[-1] ^ 1]))
        with self.assertRaises(custody.CustodyError):
            custody.run(["age", "-d", "-i", "-", str(cipher_path)], identity)
        with self.assertRaises(custody.CustodyError):
            custody.verify(wrong, first["recipient"])

    def test_aws_publish_retry_and_conflict_never_replace_existing_key(self):
        custody.prepare(self.keychain, self.public)
        identity = self.keychain.get()
        stored, puts = [], []

        def call(service, action, request):
            if action == "describe-secret":
                return {"VersionIdsToStages": {"v1": ["AWSCURRENT"]} if stored else {}}
            if action == "get-secret-value":
                return {"SecretString": stored[0]}
            if action == "put-secret-value":
                puts.append(request)
                stored.append(request["SecretString"])
                return {"VersionId": request["ClientRequestToken"]}
            raise AssertionError(action)

        aws = custody.AWSSecret.__new__(custody.AWSSecret)
        aws.secret_id = "modelmatch/home-server/recovery-key-v1"
        aws.call = call
        self.assertTrue(aws.publish(identity)["aws_value_created"])
        self.assertFalse(aws.publish(identity)["aws_value_created"])
        wrong = custody.validate_identity(custody.run(["age-keygen"]))
        with self.assertRaises(custody.CustodyError):
            aws.publish(wrong)
        self.assertEqual(len(puts), 1)
        self.assertEqual(stored[0].encode(), identity)

    def test_secret_payload_uses_stdin_not_process_arguments(self):
        aws = custody.AWSSecret.__new__(custody.AWSSecret)
        aws.base = ["aws", "--profile", "fixture"]
        with patch.object(custody, "run", return_value=b"{}") as command:
            aws.call("secretsmanager", "put-secret-value", {"SecretString": "sensitive-fixture"})
        args, payload = command.call_args.args
        self.assertNotIn("sensitive-fixture", " ".join(args))
        self.assertIn(b"sensitive-fixture", payload)


if __name__ == "__main__":
    unittest.main()
