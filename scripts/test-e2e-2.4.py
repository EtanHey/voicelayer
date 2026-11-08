import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('gate', Path(__file__).with_name('e2e-2.4.py'))
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)

class GateTests(unittest.TestCase):
    def run_gate(self, release=False, returncode=0, output=""):
        with tempfile.TemporaryDirectory() as folder:
            report = Path(folder) / 'report.json'
            argv = ['gate', '--report', str(report)] + (['--release'] if release else [])
            with patch('sys.argv', argv), patch.object(gate.subprocess, 'run', return_value=subprocess.CompletedProcess([], returncode, stdout=output, stderr="")):
                result = gate.main()
            return result, report.read_text()

    def test_skips_are_visible_and_cannot_be_release_green(self):
        result, report = self.run_gate(release=True, output=" 1 skip\n")
        self.assertEqual(result, 1)
        self.assertIn('PASS_WITH_SKIPS', report)
        self.assertIn('"releaseReady": false', report)

    def test_every_declared_suite_exists(self):
        for suites in gate.CASES.values():
            for suite in suites:
                self.assertTrue((gate.ROOT / 'src/__tests__' / (suite + '.test.ts')).is_file(), suite)

    def test_pending_native_blocks_release(self):
        result, report = self.run_gate(release=True)
        self.assertEqual(result, 1)
        self.assertIn('M1-pending', report)

    def test_suite_failure_blocks_isolated_gate(self):
        result, _ = self.run_gate(returncode=1)
        self.assertEqual(result, 1)

    def test_isolated_success_is_explicitly_not_release_ready(self):
        result, report = self.run_gate()
        self.assertEqual(result, 0)
        self.assertIn('"releaseReady": false', report)

if __name__ == '__main__':
    unittest.main()
