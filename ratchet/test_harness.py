"""Unit regression checks for harness failure paths; never real row receipts."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import threading
import time
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("harness", Path(__file__).with_name("run.py"))
harness = importlib.util.module_from_spec(spec)
spec.loader.exec_module(harness)


class HarnessTests(unittest.TestCase):
    def test_recents_row_pins_first_parent_and_counts_order_age_and_missing_rows(self):
        self.assertEqual(harness.ROWS["recents-newest-after-retranscribe"], ("2f2de18c^1", "2f2de18c"))
        expected = [{"path": "/synthetic/new.wav", "created_at": "2026-08-21T10:00:00.000Z"},
                    {"path": "/synthetic/old.wav", "created_at": "2026-08-20T10:00:00.000Z"}]
        self.assertEqual(harness.recents_violations(expected, expected), 0)
        for actual in (expected[::-1], expected[:1], [],
                       [dict(expected[0], created_at="2026-08-22T10:00:00.000Z"), expected[1]],
                       expected + [expected[0]]):
            with self.subTest(actual=actual):
                self.assertGreater(harness.recents_violations(actual, expected), 0)

    def test_failed_install_removes_real_registered_worktree_and_temp_root(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture = Path(directory)
            repo, root = fixture / "repo", fixture / "vlr-failed"
            env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
            execute = subprocess.run
            def git(*args):
                return subprocess.check_output(["git", "-C", str(repo), *args], env=env)
            repo.mkdir()
            git("init", "--quiet")
            git("-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid",
                "commit", "--allow-empty", "--quiet", "-m", "synthetic")
            before = git("worktree", "list", "--porcelain")
            def failing_install(argv, **kwargs):
                if argv[0] == "bun":
                    self.assertIn(str(root / "source"), git("worktree", "list", "--porcelain").decode())
                    raise subprocess.CalledProcessError(23, argv)
                return execute(argv, **kwargs)
            root.mkdir()
            try:
                with patch.object(harness, "REPO", repo), patch.object(harness.tempfile, "mkdtemp", return_value=str(root)), \
                        patch.object(harness.subprocess, "run", side_effect=failing_install):
                    with self.assertRaises(subprocess.CalledProcessError) as error:
                        harness.Run("HEAD", fixture / "setup.log")
                self.assertEqual(error.exception.returncode, 23)
                self.assertEqual(git("worktree", "list", "--porcelain"), before)
                self.assertFalse(root.exists())
            finally:
                if root.exists():
                    execute(["git", "-C", str(repo), "worktree", "remove", "--force", str(root / "source")], env=env)

    def test_delayed_split_event_and_late_duplicate_are_both_counted(self):
        wire = harness.Wire()
        event = json.dumps(dict(type="archive_metadata_updated", recording_path="/fixture/audio.wav")).encode() + b"\n"
        def producer():
            time.sleep(.6)  # Beyond the old fixed .5-second snapshot.
            wire.feed(event[:10])
            time.sleep(.02)
            wire.feed(event[10:])
            time.sleep(.05)
            wire.feed(event)
        thread = threading.Thread(target=producer)
        thread.start()
        try:
            # Leave ample scheduling margin after each feed, including the duplicate.
            frames, observed, quiet = wire.archive("/fixture/audio.wav", timeout=3, quiet=1.5)
            self.assertTrue(observed and quiet)
            self.assertEqual(sum(frame["type"] == "archive_metadata_updated" for frame in frames), 2)
        finally:
            thread.join(5)

    def test_missing_or_incomplete_event_fails_with_bounded_wait(self):
        wire = harness.Wire()
        wire.feed(b'{"type":"archive_metadata_updated"')
        frames, observed, quiet = wire.archive("/fixture/audio.wav", timeout=.05, quiet=.05)
        self.assertEqual(frames, [])
        self.assertFalse(observed or quiet)

    def test_pressure_requires_fragmentation_and_a_stalled_small_buffer(self):
        raw = b'{"payload":"' + b"x" * 12000 + b'"}\n'
        chunks = [raw[i:i + 4093] for i in range(0, len(raw), 4093)]
        evidence = harness.pressure_evidence(chunks, [len(raw)], 4096, .5, 4096)
        harness.require_pressure(evidence)
        self.assertGreaterEqual(evidence["split_frames"], 1)
        for parts, sizes, queued, stall, buffer in (([raw], [len(raw)], 4096, .5, 4096),
                (chunks, [], 4096, .5, 4096), (chunks, [len(raw)], 4095, .5, 4096),
                (chunks, [len(raw)], 4096, 0, 4096), (chunks, [len(raw)], 4096, .5, len(raw) * 2)):
            with self.subTest(queued=queued, stall=stall, buffer=buffer, sizes=sizes), \
                    self.assertRaisesRegex(RuntimeError, "pressure not exercised"):
                harness.require_pressure(harness.pressure_evidence(parts, sizes, queued, stall, buffer))


if __name__ == "__main__":
    unittest.main()
