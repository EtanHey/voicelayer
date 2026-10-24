"""Synthetic causal controls; real npm pack qualification is also required."""

import importlib.util
import io
import json
from pathlib import Path
import tarfile
import tempfile
import unittest


SPEC = importlib.util.spec_from_file_location(
    "npm_package_contract", Path(__file__).resolve().parents[1] / "scripts/verify-npm-package.py")
CONTRACT = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CONTRACT)
IDENTITY = {"name": "contract-fixture", "version": "1.0.0"}
LOCK = b'{"lockfileVersion": 1}\n'


class PackageContractTests(unittest.TestCase):
    def check_archive(self, extra=(), omit=(), identity=IDENTITY, expected_error=None):
        fixtures = Path(__file__).resolve().parents[1] / ".build.noindex"
        fixtures.mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(dir=fixtures) as directory:
            archive = Path(directory) / "fixture.tgz"
            members = [("package/package.json", json.dumps(identity).encode(), tarfile.REGTYPE),
                       ("package/bun.lock", LOCK, tarfile.REGTYPE)]
            with tarfile.open(archive, "w:gz") as packed:
                for name, data, kind in [m for m in members if m[0] not in omit] + list(extra):
                    member = tarfile.TarInfo(name)
                    member.type = kind
                    member.size = len(data) if kind == tarfile.REGTYPE else 0
                    if kind in (tarfile.SYMTYPE, tarfile.LNKTYPE):
                        member.linkname = "package/package.json"
                    packed.addfile(member, io.BytesIO(data))
            if expected_error:
                with self.assertRaisesRegex(ValueError, expected_error):
                    CONTRACT.verify_archive(archive, IDENTITY, LOCK)
            else:
                result = CONTRACT.verify_archive(archive, IDENTITY, LOCK)
                self.assertEqual((result["name"], result["version"], result["members"]),
                                 ("contract-fixture", "1.0.0", 2))

    def test_exact_lock_and_identity_pass(self):
        self.check_archive()

    def test_missing_lock_refused(self):
        self.check_archive(omit=("package/bun.lock",), expected_error="missing package/bun.lock")

    def test_changed_lock_refused(self):
        self.check_archive(omit=("package/bun.lock",), extra=[
            ("package/bun.lock", LOCK + b"changed", tarfile.REGTYPE)], expected_error="differs")

    def test_duplicate_lock_refused(self):
        self.check_archive(extra=[("package/bun.lock", LOCK, tarfile.REGTYPE)],
                           expected_error="duplicate")

    def test_unsafe_lock_paths_refused(self):
        for name in ("/package/bun.lock", "package/../bun.lock", "package/./bun.lock",
                     "package//bun.lock", "package\\bun.lock"):
            with self.subTest(name=name):
                self.check_archive(extra=[(name, LOCK, tarfile.REGTYPE)], expected_error="unsafe")

    def test_nonregular_lock_refused(self):
        for kind in (tarfile.SYMTYPE, tarfile.LNKTYPE, tarfile.DIRTYPE, tarfile.FIFOTYPE):
            with self.subTest(kind=kind):
                self.check_archive(omit=("package/bun.lock",), extra=[
                    ("package/bun.lock", LOCK, kind)], expected_error="nonregular")

    def test_package_identity_mismatch_refused(self):
        for key in ("name", "version"):
            with self.subTest(key=key):
                self.check_archive(identity={**IDENTITY, key: "different"}, expected_error="identity")

    def test_missing_package_manifest_refused(self):
        self.check_archive(omit=("package/package.json",), expected_error="missing package/package.json")

    def test_duplicate_package_manifest_refused(self):
        self.check_archive(extra=[("package/package.json", b"{}", tarfile.REGTYPE)],
                           expected_error="duplicate")

    def test_invalid_manifest_refused(self):
        self.check_archive(omit=("package/package.json",), extra=[
            ("package/package.json", b"[", tarfile.REGTYPE)], expected_error="Expecting")


if __name__ == "__main__":
    unittest.main()
