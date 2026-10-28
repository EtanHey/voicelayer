"""Unit checks for untrusted result ingestion; these are not ratchet rows."""
import copy
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import Mock, patch
from urllib.parse import urlparse

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
        self.assertIn("| voice-ask-lock-suspends-timeout | 0 | 0 | +0 | 0 | PASS |", table)

    def test_recents_requires_and_labels_overlay_receipt(self):
        self.assertIn("recents-newest-after-retranscribe", comment.ROWS)
        data = copy.deepcopy(self.data)
        row = next(item for item in data if item["row"] == "recents-newest-after-retranscribe")
        row["overlay_sha256"] = "d" * 64
        table = comment.render(self.read(data), self.read(data), "a" * 40, "a" * 40)
        self.assertIn("behavior (overlay: trigger + snapshot + defaults-domain test seams)", table)
        row["overlay_sha256"] = None
        with self.assertRaises(comment.InvalidResults):
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
            with self.subTest(data=data), self.assertRaises(comment.InvalidResults):
                self.read(data)

    def outcome(self, baseline=None, head=None, base_sha="a" * 40):
        with tempfile.TemporaryDirectory() as directory:
            base, tip = Path(directory) / "base.json", Path(directory) / "head.json"
            base.write_text(json.dumps(self.data if baseline is None else baseline))
            tip.write_text(json.dumps(self.data if head is None else head))
            return comment.result(base, tip, base_sha, "a" * 40)

    def test_advanced_base_is_unavailable_without_numbers(self):
        outcome = self.outcome(base_sha="e" * 40)
        self.assertIsInstance(outcome, comment.Unavailable)
        body = comment.body_for(outcome, "e" * 40, "a" * 40,
                                "https://github.com/example/project/actions/runs/123")
        self.assertIn("table unavailable: baseline advanced", body)
        self.assertNotIn("|", body)
        self.assertNotIn("PASS", body)
        self.assertIn("e" * 40, body)

    def test_invalid_rows_and_overlay_never_become_numbers(self):
        for field, value in (("row", "injected | row"), ("overlay_sha256", None),
                             ("value", True), ("status", "FAIL")):
            data = copy.deepcopy(self.data)
            data[1][field] = value
            with self.subTest(field=field):
                outcome = self.outcome(head=data)
                self.assertIsInstance(outcome, comment.Unavailable)
                body = comment.body_for(outcome, "a" * 40, "a" * 40, None)
                self.assertIn("table unavailable:", body)
                self.assertNotIn("|", body)
                self.assertNotIn("PASS", body)

    def test_missing_malformed_and_incompatible_results(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "result.json"
            self.assertIsInstance(comment.result(path, path, "a" * 40, "a" * 40), comment.Unavailable)
            path.write_text("{")
            self.assertIsInstance(comment.result(path, path, "a" * 40, "a" * 40), comment.Unavailable)
        for data in ({}, [None] * len(comment.ROWS), [{}] * len(comment.ROWS)):
            self.assertIsInstance(self.outcome(head=data), comment.Unavailable)
        changed = copy.deepcopy(self.data)
        changed[0]["fix_sha"] = "e" * 40
        self.assertIsInstance(self.outcome(head=changed), comment.Unavailable)

    def test_superseded_or_closed_callback_preserves_newer_table(self):
        for state, sha in (("open", "e" * 40), ("closed", "a" * 40)):
            api = Mock(return_value={"state": state, "head": {"sha": sha},
                                     "base": {"sha": "a" * 40, "ref": "main"}})
            with self.subTest(state=state), patch.object(comment, "api", api):
                reason = comment.publish("example/project", 7, "a" * 40, "a" * 40, "new body")
                self.assertIn("superseded or closed", reason.reason)
                self.assertEqual(api.call_count, 1)

    def test_current_head_upserts_unavailable_and_failures_stay_red(self):
        current = {"state": "open", "head": {"sha": "a" * 40},
                   "base": {"sha": "a" * 40, "ref": "main"}}
        existing = {"id": 9, "user": {"login": "github-actions[bot]"}, "body": comment.MARKER}
        with patch.object(comment, "api", side_effect=[current, [[existing]], current, {}]) as api:
            body = comment.body_for(comment.Unavailable("missing result artifact"), "a" * 40, "a" * 40, None)
            self.assertIsNone(comment.publish("example/project", 7, "a" * 40, "a" * 40, body).reason)
            self.assertEqual(api.call_args.args[1], "PATCH")
            self.assertEqual(api.call_args.kwargs["payload"], {"body": body})
        with patch.object(comment, "api", side_effect=[current, [[existing, existing]]]):
            with self.assertRaisesRegex(RuntimeError, "multiple ratchet comments"):
                comment.publish("example/project", 7, "a" * 40, "a" * 40, body)
        with patch.object(comment, "api", side_effect=RuntimeError("publisher bug")):
            with self.assertRaisesRegex(RuntimeError, "publisher bug"):
                comment.publish("example/project", 7, "a" * 40, "a" * 40, body)
        with patch.object(comment, "api", side_effect=[current, [[]], current, OSError("write failed")]):
            with self.assertRaisesRegex(OSError, "write failed"):
                comment.publish("example/project", 7, "a" * 40, "a" * 40, body)

    def test_head_rechecked_immediately_before_write(self):
        current = {"state": "open", "head": {"sha": "a" * 40},
                   "base": {"sha": "a" * 40, "ref": "main"}}
        moved = copy.deepcopy(current)
        moved["head"]["sha"] = "e" * 40
        with patch.object(comment, "api", side_effect=[current, [[]], moved]) as api:
            reason = comment.publish("example/project", 7, "a" * 40, "a" * 40, "body")
            self.assertIsNotNone(reason.reason)
            self.assertEqual(api.call_count, 3)

    def test_base_advanced_before_write_upserts_unavailable(self):
        current = {"state": "open", "head": {"sha": "a" * 40},
                   "base": {"sha": "a" * 40, "ref": "main"}}
        moved = copy.deepcopy(current)
        moved["base"]["sha"] = "e" * 40
        with patch.object(comment, "api", side_effect=[current, [[]], moved, {}]) as api:
            self.assertIn("base advanced", comment.publish("example/project", 7, "a" * 40, "a" * 40, "table").reason)
            body = api.call_args.kwargs["payload"]["body"]
            self.assertIn("table unavailable: base advanced", body)
            self.assertIn("e" * 40, body)
            self.assertNotIn("|", body)

    def test_cli_stale_input_succeeds_but_publisher_bug_fails(self):
        with tempfile.TemporaryDirectory() as directory:
            summary = Path(directory) / "summary.md"
            args = ["comment.py", "--baseline", str(Path(directory) / "missing.json"),
                    "--head", str(Path(directory) / "missing.json"),
                    "--baseline-sha", "a" * 40, "--head-sha", "a" * 40,
                    "--repo", "example/project", "--source-run", "123"]
            with patch("sys.argv", args), patch.dict("os.environ", {"GITHUB_STEP_SUMMARY": str(summary)}), patch("builtins.print"):
                comment.main()
            self.assertIn("table unavailable: missing result artifact", summary.read_text())
            with patch("sys.argv", args + ["--pr", "7"]), patch.object(comment, "publish", side_effect=RuntimeError("publisher bug")):
                with self.assertRaisesRegex(RuntimeError, "publisher bug"):
                    comment.main()

    def test_head_mismatch_is_distinct_from_advanced_baseline(self):
        changed = copy.deepcopy(self.data)
        changed[0]["measured_sha"] = "e" * 40
        self.assertEqual(self.outcome(head=changed).reason, "result head mismatch")
        self.assertEqual(self.outcome(base_sha="e" * 40).reason, "baseline advanced")
        self.assertEqual(self.outcome(baseline=changed, head=changed,
                                      base_sha="e" * 40).reason, "result head mismatch")

    def pinned_body(self, run_id, attempt=1, unavailable=False, base_sha="a" * 40,
                    head_sha="a" * 40):
        outcome = comment.Unavailable("missing result artifact") if unavailable else self.outcome()
        return comment.body_for(outcome, base_sha, head_sha,
                                comment.source_url("example/project", run_id), attempt)

    def test_same_head_preserves_newer_runs_and_attempts(self):
        for old_run, old_attempt, new_run, new_attempt in ((124, 1, 123, 9), (123, 2, 123, 1)):
            for unavailable in (False, True):
                with self.subTest(run=old_run, attempt=old_attempt, unavailable=unavailable):
                    self.assert_preserved(self.pinned_body(old_run, old_attempt),
                                          self.pinned_body(new_run, new_attempt, unavailable))

    def assert_preserved(self, existing_body, candidate, base_sha="a" * 40):
        current = {"state": "open", "head": {"sha": "a" * 40},
                   "base": {"sha": base_sha, "ref": "main"}}
        existing = {"id": 9, "user": {"login": "github-actions[bot]"}, "body": existing_body}
        with patch.object(comment, "api", side_effect=[current, [[existing]], current]) as api:
            publication = comment.publish("example/project", 7, base_sha, "a" * 40, candidate)
            self.assertIsNotNone(publication.reason)
            self.assertEqual(publication.body, existing_body)
            self.assertTrue(all(call.args[1:] == () for call in api.call_args_list))

    def test_older_run_cannot_downgrade_table_after_baseline_advances(self):
        self.assert_preserved(self.pinned_body(124),
                              self.pinned_body(123, unavailable=True, base_sha="e" * 40),
                              base_sha="e" * 40)

    def test_unavailable_never_downgrades_valid_same_head_and_base(self):
        self.assert_preserved(self.pinned_body(123), self.pinned_body(124, unavailable=True))
        legacy = comment.render(self.read(self.data), self.read(self.data), "a" * 40, "a" * 40)
        self.assert_preserved(legacy, self.pinned_body(124, unavailable=True))

    def test_newer_table_can_replace_old_or_unavailable_table(self):
        for existing_body in (self.pinned_body(123), self.pinned_body(124, unavailable=True),
                              self.pinned_body(125, head_sha="e" * 40)):
            current = {"state": "open", "head": {"sha": "a" * 40},
                       "base": {"sha": "a" * 40, "ref": "main"}}
            existing = {"id": 9, "user": {"login": "github-actions[bot]"}, "body": existing_body}
            candidate = self.pinned_body(124, attempt=2)
            with self.subTest(existing=existing_body), patch.object(comment, "api", side_effect=[current, [[existing]], current, {}]) as api:
                publication = comment.publish("example/project", 7, "a" * 40, "a" * 40, candidate)
                self.assertIsNone(publication.reason)
                self.assertEqual(api.call_args.kwargs["payload"], {"body": candidate})

    def test_summary_uses_published_baseline_when_base_moves(self):
        with tempfile.TemporaryDirectory() as directory:
            summary = Path(directory) / "summary.md"
            args = ["comment.py", "--baseline", directory + "/missing.json",
                    "--head", directory + "/missing.json", "--baseline-sha", "a" * 40,
                    "--head-sha", "a" * 40, "--pr", "7", "--source-run", "123",
                    "--run-attempt", "2"]
            current = {"state": "open", "head": {"sha": "a" * 40},
                       "base": {"sha": "a" * 40, "ref": "main"}}
            moved = copy.deepcopy(current)
            moved["base"]["sha"] = "e" * 40
            with patch("sys.argv", args), patch.dict("os.environ", {"GITHUB_STEP_SUMMARY": str(summary)}), patch("builtins.print"), patch.object(comment, "api", side_effect=[current, [[]], moved, {}]) as api:
                comment.main()
            published = api.call_args.kwargs["payload"]["body"]
            self.assertEqual(summary.read_text(), published)
            self.assertIn("Baseline: `" + "e" * 40 + "`", published)
            self.assertIn('"source_run_id": 123', published)
            self.assertIn('"run_attempt": 2', published)

    def test_source_url_is_parsed_and_pinned_to_repository(self):
        url = comment.source_url("example/project", 123)
        self.assertEqual(urlparse(url).hostname, "github.com")
        self.assertEqual(urlparse(url).path, "/example/project/actions/runs/123")


if __name__ == "__main__":
    unittest.main()
