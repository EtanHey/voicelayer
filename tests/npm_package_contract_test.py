"""Synthetic causal controls; real npm pack qualification is also required."""

import importlib.util
import io
import json
import os
from pathlib import Path
import re
import shutil
import shlex
import subprocess
import sys
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


class WorkflowSourceTests(unittest.TestCase):
    def test_checkouts_and_package_commands_keep_separate_roots(self):
        workflow = (Path(__file__).resolve().parents[1] / ".github/workflows/publish.yml").read_text()
        self.assertIn("defaults:\n      run:\n        working-directory: source", workflow)
        self.assertIn("ref: ${{ inputs.ref || github.ref }}\n          path: source", workflow)
        self.assertIn("ref: ${{ github.workflow_sha }}\n          path: workflow-tools", workflow)
        self.assertIn("working-directory: workflow-tools\n        run: python3 -m unittest", workflow)
        self.assertNotIn("${{ inputs.ref }}", workflow.split("        run:", 1)[1])

    def test_workflows_require_daemon_dependencies(self):
        root = Path(__file__).resolve().parents[1]
        for name in ("publish.yml", "ci.yml"):
            with self.subTest(workflow=name):
                workflow = (root / ".github/workflows" / name).read_text()
                self.assertRegex(workflow, r"- name: Run tests\n        env:\n          VOICELAYER_REQUIRE_TTS_DAEMON_DEPS: ['\"]1['\"]\n        run: bun test")

    def test_missing_daemon_dependencies_skip_locally_but_fail_when_required(self):
        root = Path(__file__).resolve().parents[1]
        fixtures = root / ".build.noindex"
        fixtures.mkdir(exist_ok=True)
        bun = shutil.which("bun")
        self.assertIsNotNone(bun)
        with tempfile.TemporaryDirectory(dir=fixtures) as directory:
            python = Path(directory) / "python3"
            python.write_text("#!/bin/sh\necho forced-missing-daemon-deps >&2\nexit 1\n")
            python.chmod(0o755)
            for required in ("", "1"):
                with self.subTest(required=required):
                    env = {**os.environ, "PATH": directory + os.pathsep + os.environ["PATH"],
                           "VOICELAYER_REQUIRE_TTS_DAEMON_DEPS": required}
                    result = subprocess.run(
                        ["timeout", "-s", "KILL", "900", bun, "test", "./src/__tests__/qwen3-cancel.test.ts"],
                        cwd=root, env=env, capture_output=True, text=True, timeout=30)
                    self.assertIn("forced-missing-daemon-deps", result.stderr)
                    if required:
                        self.assertNotEqual(result.returncode, 0, result.stderr)
                        self.assertIn("qwen3-cancel requires fastapi and uvicorn", result.stderr)
                        self.assertNotIn("SKIP qwen3-cancel", result.stderr)
                    else:
                        self.assertEqual(result.returncode, 0, result.stderr)
                        self.assertIn("SKIP qwen3-cancel", result.stderr)

    def test_daemon_dependencies_resolve_without_requirements_in_older_source(self):
        root = Path(__file__).resolve().parents[1]
        workflow = (root / ".github/workflows/publish.yml").read_text()
        command = re.search(
            r"- name: Install daemon test dependencies\n        run: (.+)", workflow).group(1)
        argv = shlex.split(command)
        self.assertEqual(argv[:-1], ["python3", "-m", "pip", "install", "-r"])
        requirements = root / "tests/requirements-tts-daemon.txt"
        fixtures = root / ".build.noindex"
        fixtures.mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(dir=fixtures) as directory:
            workspace = Path(directory)
            source = workspace / "source"
            source.mkdir()
            tools = workspace / "workflow-tools/tests"
            tools.mkdir(parents=True)
            shutil.copyfile(requirements, tools / requirements.name)
            self.assertFalse((source / "tests" / requirements.name).exists())
            self.assertEqual((source / argv[-1]).read_bytes(), requirements.read_bytes())

    def test_legacy_source_guard_location_fails_and_workflow_command_passes(self):
        root = Path(__file__).resolve().parents[1]
        fixtures = root / ".build.noindex"
        fixtures.mkdir(exist_ok=True)
        workflow = (root / ".github/workflows/publish.yml").read_text()
        command = re.search(r"^          (python3 .*verify-npm-package.py.*)$", workflow, re.M).group(1)
        with tempfile.TemporaryDirectory(dir=fixtures) as directory:
            workspace = Path(directory)
            source = workspace / "source"
            source.mkdir()
            tools = workspace / "workflow-tools/scripts"
            tools.mkdir(parents=True)
            shutil.copyfile(root / "scripts/verify-npm-package.py", tools / "verify-npm-package.py")
            (source / "bun.lock").write_bytes(LOCK)
            (source / "package.json").write_text(json.dumps(IDENTITY))
            for argv in (["git", "init", "-q"], ["git", "add", "bun.lock", "package.json"],
                         ["git", "-c", "user.name=Contract Fixture", "-c", "user.email=fixture@example.invalid",
                          "commit", "-qm", "fixture source"]):
                subprocess.run(argv, cwd=source, check=True, capture_output=True)
            archive = workspace / "fixture.tgz"
            with tarfile.open(archive, "w:gz") as packed:
                for name, data in [("bun.lock", LOCK), ("package.json", json.dumps(IDENTITY).encode())]:
                    member = tarfile.TarInfo("package/" + name)
                    member.size = len(data)
                    packed.addfile(member, io.BytesIO(data))
            old = subprocess.run([sys.executable, "scripts/verify-npm-package.py", str(archive)],
                                 cwd=source, capture_output=True, text=True)
            self.assertEqual(old.returncode, 2)
            self.assertFalse((source / "scripts/verify-npm-package.py").exists())
            result = subprocess.run(["bash", "-e", "-c", 'pack_dir="$1"; archive="$2"; ' + command,
                                     "contract-fixture", str(workspace), archive.name],
                                    cwd=source, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(json.loads(result.stdout)["version"], IDENTITY["version"])


if __name__ == "__main__":
    unittest.main()
