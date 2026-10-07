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
                          overlay_sha256="d" * 64 if row in ("socket-isolation", "recents-newest-after-retranscribe") else None)
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

    def test_recents_requires_and_labels_overlay_receipt(self):
        self.assertIn("recents-newest-after-retranscribe", comment.ROWS)
        data = copy.deepcopy(self.data)
        row = next(item for item in data if item["row"] == "recents-newest-after-retranscribe")
        row["overlay_sha256"] = "d" * 64
        table = comment.render(self.read(data), self.read(data), "a" * 40, "a" * 40)
        self.assertIn("behavior (overlay: trigger + snapshot + defaults-domain test seams)", table)
        row["overlay_sha256"] = None
        with self.assertRaises((AssertionError, TypeError)):
            self.read(data)

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
