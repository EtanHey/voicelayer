"""Unit checks for untrusted result ingestion; these are not ratchet rows."""
import copy
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("comment", Path(__file__).with_name("comment.py"))
comment = importlib.util.module_from_spec(spec)
spec.loader.exec_module(comment)


class CommentTests(unittest.TestCase):
    def setUp(self):
        self.data = [dict(row=row, kind="behavior", value=0, ceiling=0, status="PASS",
                          measured_sha="a" * 40, bug_sha="b" * 40, fix_sha="c" * 40,
                          overlay_sha256="d" * 64 if row == "socket-isolation" else None)
                     for row in comment.ROWS]

    def read(self, data, sha="a" * 40):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "result.json"
            path.write_text(json.dumps(data))
            return comment.read(path, sha)

    def test_pins_and_reports_regression(self):
        baseline = self.read(self.data)
        changed = copy.deepcopy(self.data)
        changed[0].update(value=1, status="FAIL")
        head = self.read(changed)
        table = comment.render(baseline, head, "a" * 40, "a" * 40)
        self.assertIn("| ndjson-partial-write | 0 | 1 | +1 | 0 | FAIL |", table)
        self.assertIn("behavior (overlay: protected-path test seam)", table)
        self.assertIn("a" * 40, table)
        self.assertIn("| voice-ask-lock-suspends-timeout | 0 | 0 | +0 | 0 | PASS |", table)

    def test_rejects_stale_missing_and_forged_results(self):
        cases = [self.data[:-1], self.data + [self.data[0]]]
        for key, value in (("measured_sha", "e" * 40), ("status", "FAIL"),
                           ("ceiling", 1), ("value", True), ("row", "injected | row")):
            changed = copy.deepcopy(self.data)
            changed[0][key] = value
            cases.append(changed)
        changed = copy.deepcopy(self.data)
        changed[1]["overlay_sha256"] = None
        cases.append(changed)
        for data in cases:
            with self.subTest(data=data), self.assertRaises((AssertionError, TypeError)):
                self.read(data)


if __name__ == "__main__":
    unittest.main()
