"""Unit checks for replay classification and row pinning; never real row receipts."""
import importlib.util
from pathlib import Path
import re
import unittest

spec = importlib.util.spec_from_file_location("replay_runner", Path(__file__).with_name("run.py"))
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)
comment_spec = importlib.util.spec_from_file_location("replay_comment", Path(__file__).with_name("comment.py"))
comment = importlib.util.module_from_spec(comment_spec)
comment_spec.loader.exec_module(comment)


def report(*cases):
    body = []
    for name, child in cases:
        body.append(f'<testcase name="{name}" classname="">{child}</testcase>')
    return '<?xml version="1.0"?><testsuites><testsuite name="probe">' + "".join(body) + "</testsuite></testsuites>"


ASSERT = '<failure type="AssertionError" message="Expected: &quot;OPEN&quot; Received: &quot;COMMITTED&quot;">x</failure>'
SKIP = "<skipped />"


class ReplayClassificationTests(unittest.TestCase):
    def test_all_pass_is_zero(self):
        value, cases, problems = runner.classify_replay(report(("a", ""), ("b", "")), ("a", "b"))
        self.assertEqual((value, problems), (0, []))
        self.assertEqual([case["outcome"] for case in cases], ["pass", "pass"])

    def test_assertion_failures_count_as_semantic(self):
        value, _, problems = runner.classify_replay(report(("a", ASSERT), ("b", "")), ("a", "b"), returncode=1)
        self.assertEqual((value, problems), (1, []))

    def test_named_semantic_message_counts_only_when_listed(self):
        refusal = '<failure type="Error" message="UNKNOWN: quit outcome unverifiable">x</failure>'
        value, _, problems = runner.classify_replay(report(("a", refusal)), ("a",), (r"^UNKNOWN: quit",), 1)
        self.assertEqual((value, problems), (1, []))
        value, _, problems = runner.classify_replay(report(("a", refusal)), ("a",), (), 1)
        self.assertEqual(value, 0)
        self.assertTrue(any("non-semantic" in problem for problem in problems))

    def test_import_or_type_errors_are_harness_failures_not_history(self):
        crash = '<failure type="TypeError" message="installer.completeGatedInstall is not a function">x</failure>'
        value, _, problems = runner.classify_replay(report(("a", crash)), ("a",), returncode=1)
        self.assertEqual(value, 0)
        self.assertTrue(problems)

    def test_missing_skipped_or_extra_cases_block(self):
        for xml, expected in ((report(("a", "")), ("a", "b")),
                              (report(("a", ""), ("b", SKIP)), ("a", "b")),
                              (report(("a", ""), ("c", "")), ("a",))):
            with self.subTest(expected=expected):
                _, _, problems = runner.classify_replay(xml, expected)
                self.assertTrue(problems)

    def test_nonzero_exit_without_semantic_failure_blocks(self):
        value, _, problems = runner.classify_replay(report(("a", "")), ("a",), returncode=1)
        self.assertEqual(value, 0)
        self.assertTrue(any("without a semantic failure" in problem for problem in problems))

    def test_zero_exit_with_failures_blocks(self):
        _, _, problems = runner.classify_replay(report(("a", ASSERT)), ("a",), returncode=0)
        self.assertTrue(problems)


class ReplayRowPinningTests(unittest.TestCase):
    def test_rows_pin_full_commits_and_exact_cases(self):
        self.assertGreaterEqual(len(runner.REPLAY_ROWS), 10)
        for row, item in runner.REPLAY_ROWS.items():
            with self.subTest(row=row):
                for key in ("bug", "fix"):
                    self.assertRegex(item[key], r"^[0-9a-f]{40}$")
                self.assertNotEqual(item["bug"], item["fix"])
                commit, path = item["probe"]
                self.assertRegex(commit, r"^[0-9a-f]{40}$")
                self.assertRegex(path, r"^src/__tests__/[\w.-]+\.test\.ts$")
                self.assertTrue(item["tests"])
                self.assertEqual(len(item["tests"]), len(set(item["tests"])))
                for pattern in item.get("semantic", ()):
                    self.assertTrue(pattern.startswith("^"))
                    re.compile(pattern)

    def test_replay_rows_do_not_change_the_default_ci_row_set(self):
        self.assertFalse(set(runner.REPLAY_ROWS) & set(runner.ROWS))
        self.assertEqual(tuple(runner.ROWS), comment.ROWS)


if __name__ == "__main__":
    unittest.main()
