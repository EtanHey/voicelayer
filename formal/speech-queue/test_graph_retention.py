"""Exercise the production lifecycle, then require both cleanup mutants to fail."""
from pathlib import Path
import importlib.util
import os
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import graph_retention as retention

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "formal/speech-queue"))
spec = importlib.util.spec_from_file_location("retention_checker", Path(__file__).with_name("check.py"))
checker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(checker)


class GraphRetentionTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)

    def graph(self, run):
        (run / "meta").mkdir(exist_ok=True)
        (run / "meta/state.dot").write_text("graph")
        (run / "result.log").write_text("receipt")

    def failed_run(self, error=AssertionError):
        with self.assertRaises(error):
            with retention.graph_run(self.root) as run:
                self.graph(run)
                if error is subprocess.TimeoutExpired:
                    raise error("TLC", 1)
                raise error("synthetic failure")
        return run

    def test_success_modes_remove_graphs_and_keep_logs(self):
        for mode in ("full", "--f5-only", "--receipt"):
            with self.subTest(mode=mode), retention.graph_run(self.root) as run:
                self.graph(run)
            self.assertFalse(list(run.rglob("*.dot")))
            self.assertEqual((run / "result.log").read_text(), "receipt")
            self.assertFalse((run / retention.MARKER).exists())

    def test_actual_checker_wraps_every_mode_and_failure(self):
        calls = []
        def body(runner, run, f5_only, receipt):
            calls.append((f5_only, receipt))
            self.graph(run)
        modes = [(False, False), (True, False), (False, True), (True, True)]
        with patch.object(checker, "ROOT", self.root), patch.object(checker, "check_run", body):
            for f5_only, receipt in modes:
                checker.check(None, f5_only, receipt)
                self.assertFalse(list(self.root.rglob("*.dot")))
        self.assertEqual(calls, modes)
        def failed_body(*args):
            body(*args)
            raise RuntimeError("reader failed")
        with patch.object(checker, "ROOT", self.root), patch.object(checker, "check_run", failed_body):
            with self.assertRaises(RuntimeError):
                checker.check(None)
        self.assertEqual(len(list(self.root.rglob(retention.MARKER))), 1)
        self.assertEqual(len(list(self.root.rglob("*.dot"))), 1)

    def test_metadata_rotation_protects_older_failure(self):
        failed = self.failed_run()
        for _ in range(4):
            with retention.graph_run(self.root) as run:
                self.graph(run)
        self.assertEqual(len(list(self.root.iterdir())), 4)  # Three recent logs plus failure.
        self.assertTrue((failed / retention.MARKER).is_file())
        self.assertEqual(list(self.root.rglob("*.dot")), [failed / "meta/state.dot"])

    def test_generic_checker_removes_success_metadata_and_keeps_failure(self):
        with retention.graph_run(self.root, prefix="tlc-", keep_runs=0) as run:
            self.graph(run)
        self.assertFalse(run.exists())
        with self.assertRaises(AssertionError):
            with retention.graph_run(self.root, prefix="tlc-", keep_runs=0) as failed:
                self.graph(failed)
                raise AssertionError("TLC")
        with retention.graph_run(self.root, prefix="tlc-", keep_runs=0):
            pass
        self.assertEqual(list(self.root.iterdir()), [failed])
        self.assertTrue((failed / retention.MARKER).is_file())

    def test_cleanup_error_marks_remaining_graphs(self):
        with self.assertRaises(OSError), patch.object(retention, "delete_graphs", side_effect=OSError("unlink")):
            with retention.graph_run(self.root) as run:
                self.graph(run)
        self.assertTrue((run / retention.MARKER).is_file())
        self.assertEqual(len(list(run.rglob("*.dot"))), 1)

    def test_all_failure_exits_keep_graphs(self):
        for error in (SystemExit, AssertionError, RuntimeError, subprocess.TimeoutExpired, KeyboardInterrupt):
            with self.subTest(error=error):
                run = self.failed_run(error)
                self.assertTrue((run / retention.MARKER).is_file())
                self.assertEqual(len(list(run.rglob("*.dot"))), 1)

    def test_new_failure_replaces_old_slot(self):
        old = self.failed_run()
        new = self.failed_run()
        self.assertFalse(list(old.rglob("*.dot")))
        self.assertFalse((old / retention.MARKER).exists())
        self.assertEqual(list(self.root.rglob(retention.MARKER)), [new / retention.MARKER])
        self.assertEqual(len(list(self.root.rglob("*.dot"))), 1)

    def test_new_failure_wins_even_if_old_marker_time_is_in_the_future(self):
        old = self.failed_run()
        future = time.time() + 3600
        os.utime(old / retention.MARKER, (future, future))
        new = self.failed_run()
        self.assertFalse(list(old.rglob("*.dot")))
        self.assertEqual(list(self.root.rglob(retention.MARKER)), [new / retention.MARKER])
        self.assertEqual(len(list(new.rglob("*.dot"))), 1)

    def test_clean_run_preserves_failed_slot(self):
        failed = self.failed_run()
        with retention.graph_run(self.root) as run:
            self.graph(run)
        self.assertEqual(list(self.root.rglob("*.dot")), [failed / "meta/state.dot"])
        self.assertTrue((failed / retention.MARKER).is_file())

    def test_startup_sweeps_killed_and_older_marked_runs(self):
        for name, stamp in (("run-old", 1), ("tlc-new", 2), ("run-killed", None)):
            run = self.root / name
            run.mkdir()
            self.graph(run)
            if stamp is not None:
                marker = run / retention.MARKER
                marker.write_text("failed")
                os.utime(marker, (stamp, stamp))
        with retention.graph_run(self.root):
            self.assertEqual(list(self.root.rglob("*.dot")), [self.root / "tlc-new/meta/state.dot"])
            self.assertEqual(list(self.root.rglob(retention.MARKER)), [self.root / "tlc-new" / retention.MARKER])
        self.assertTrue((self.root / "run-killed/result.log").is_file())
        self.assertTrue((self.root / "tlc-new/result.log").is_file())


def suite():
    return unittest.defaultTestLoader.loadTestsFromTestCase(GraphRetentionTests)


if __name__ == "__main__":
    mutants = {"cleanup-skipped": "delete_graphs", "keep-old-failures": "discard_failure"}
    if len(sys.argv) == 3 and sys.argv[1] == "--mutant":
        mutant = sys.argv[2]
        with patch.object(retention, mutants[mutant], lambda run: None):
            result = unittest.TextTestRunner().run(suite())
        if result.failures and not result.errors:
            print(f"MUTANT DETECTED: {mutant}", flush=True)
            sys.exit(1)
        sys.exit(0 if result.wasSuccessful() else 2)
    result = unittest.TextTestRunner().run(suite())
    assert result.wasSuccessful(), "Graph retention self-test failed"
    for mutant in mutants:
        result = subprocess.run([sys.executable, "-B", __file__, "--mutant", mutant],
                                env=os.environ, capture_output=True, text=True)
        assert result.returncode == 1 and f"MUTANT DETECTED: {mutant}" in result.stdout, (
            f"Mutant survived or errored: {mutant}\n{result.stdout}\n{result.stderr}")
        print(f"PASS: retention mutant {mutant}: expected FAIL, actual rc={result.returncode}", flush=True)
