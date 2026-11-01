import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import base_cache as cache


class CacheTests(unittest.TestCase):
    def setUp(self):
        pin = patch.object(cache, 'sha', return_value='a' * 40)
        pin.start()
        self.addCleanup(pin.stop)

    def rows(self):
        return [dict(row=row, measured_sha='a' * 40, error=None, status='PASS', value=0,
                     ceiling=0, kind='behavior', bug_sha='a' * 40, fix_sha='a' * 40,
                     app_binary_sha256='b' * 64, overlay_sha256='c' * 64) for row in cache.ROWS]

    def run_case(self, rows, fresh):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'result.json').write_text(json.dumps(rows))
            calls = []
            def execute(argv):
                row = argv[argv.index('--row') + 1]
                calls.append(row)
                item = next(item.copy() for item in self.rows() if item['row'] == row)
                item.update(fresh)
                (Path(argv[-1]) / 'result.json').write_text(json.dumps([item]))
                return type('Result', (), {'returncode': int(item['status'] != 'PASS')})()
            result, clean = cache.baseline('a' * 40, root, root / 'out', execute)
            return calls, result, clean

    def test_hit_skips_base_and_head_regression_still_fails(self):
        calls, base, clean = self.run_case(self.rows(), {})
        self.assertEqual(calls, [])
        self.assertTrue(clean)
        import test_runner
        result = unittest.TestResult()
        test_runner.RunnerTests('test_missing_binary_emits_fail_rows_and_nonzero_exit').run(result)
        self.assertTrue(result.wasSuccessful(), (result.errors, result.failures))
        self.assertTrue(all(item['value'] == 0 for item in base))

    def test_failed_or_deadline_base_is_rerun_and_cannot_fail_clean_pr(self):
        for changes in ({'error': 'deadline expired', 'status': 'FAIL', 'value': 1},
                        {'status': 'FAIL', 'value': 1}, {'measured_sha': 'd' * 40}):
            rows = self.rows()
            rows[-1].update(changes)
            calls, results, clean = self.run_case(rows, {})
            self.assertEqual(calls, [rows[-1]['row']])
            self.assertTrue(clean)
            self.assertTrue(all(item['status'] == 'PASS' for item in results))

    def test_missing_row_reruns_and_error_is_not_cacheable(self):
        calls, _, clean = self.run_case(self.rows()[:-1],
                                        dict(error='deadline expired', status='FAIL', value=1))
        self.assertEqual(calls, [list(cache.ROWS)[-1]])
        self.assertFalse(clean)
