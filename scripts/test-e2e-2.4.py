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
    def run_gate(self, release=False, returncode=0, output="", swift=False):
        with tempfile.TemporaryDirectory() as folder:
            report = Path(folder) / 'report.json'
            argv = ['gate', '--report', str(report)] + (['--release'] if release else []) + (['--swift'] if swift else [])
            with patch('sys.argv', argv), patch.object(gate, 'run_bounded', return_value=subprocess.CompletedProcess([], returncode, stdout=output, stderr="")):
                result = gate.main()
            return result, report.read_text()

    def test_skips_are_visible_and_cannot_be_release_green(self):
        result, report = self.run_gate(release=True, output=" 1 skip\n")
        self.assertEqual(result, 1)
        self.assertIn('PASS_WITH_SKIPS', report)
        self.assertIn('"releaseReady": false', report)

    def test_deadline_stops_owned_process_group(self):
        import sys
        with self.assertRaises(subprocess.TimeoutExpired):
            gate.run_bounded([sys.executable, '-c', 'import time; time.sleep(30)'],
                             timeout=0.05, text=True)

    def test_combined_runtime_over_fifteen_minutes_refuses_release(self):
        import itertools
        import json
        with tempfile.TemporaryDirectory() as folder:
            native = Path(folder)
            (native / 'qa-report.json').write_text(json.dumps({'scenario': 'e2e24', 'scenarioPassed': True}))
            (native / 'ledger.json').write_text(json.dumps({'scenario': 'e2e24', 'completed': True,
                'failures': 0, 'coverage': {'verifiedSurfaces': ['e2e24'], 'missing': [], 'missingSurfaces': []}}))
            (native / 'recording.json').write_text(json.dumps({'valid': True, 'runPassed': True,
                'durationSeconds': 200, 'path': 'run.mov'}))
            (native / 'run.mov').write_text('controlled receipt fixture')
            report = native / 'report.json'
            with patch('sys.argv', ['gate', '--release', '--swift', '--native-output', str(native), '--report', str(report)]), \
                 patch.object(gate, 'run_bounded', return_value=subprocess.CompletedProcess([], 0, '', '')), \
                 patch.object(gate.time, 'monotonic', side_effect=itertools.chain([0], itertools.repeat(800))):
                self.assertEqual(gate.main(), 1)
            self.assertIn('combined 15 minute runtime', report.read_text())
            self.assertIn('"releaseReady": false', report.read_text())

    def test_native_surfaces_never_upgrade_uncovered_flows(self):
        rows = gate.native_rows({'e2e24:dictionary'})
        self.assertEqual(next(r for r in rows if r['flow'] == 'dictionary CRUD')['status'], 'PASS')
        for flow in ['F5 physical gestures', 'native paste target and terminal typing', 'installed update and restore']:
            self.assertEqual(next(r for r in rows if r['flow'] == flow)['status'], 'UNPROVED-native')
        self.assertNotEqual(next(r for r in rows if r['flow'] == 'recognizer load/unload')['status'], 'PASS')

    def test_partial_native_receipt_preserves_only_its_verified_case(self):
        import json
        with tempfile.TemporaryDirectory() as folder:
            native = Path(folder)
            (native/'qa-report.json').write_text(json.dumps({'scenario':'e2e24','scenarioPassed':False}))
            (native/'ledger.json').write_text(json.dumps({'scenario':'e2e24','completed':True,'failures':0,
                'coverage':{'verifiedSurfaces':['e2e24:dictionary'],'missing':[],'missingSurfaces':['e2e24:recognizer']}}))
            (native/'recording.json').write_text(json.dumps({'valid':True,'runPassed':True,'durationSeconds':1,'path':'run.mov'}))
            (native/'run.mov').write_text('controlled fixture')
            report=native/'report.json'
            with patch('sys.argv',['gate','--report',str(report),'--native-output',str(native)]), \
                 patch.object(gate,'run_bounded',return_value=subprocess.CompletedProcess([],0,'','')):
                gate.main()
            rows=json.loads(report.read_text())['rows']
            self.assertEqual(next(r for r in rows if r['flow']=='dictionary CRUD')['status'],'PASS')
            self.assertNotEqual(next(r for r in rows if r['flow']=='recognizer load/unload')['status'],'PASS')

    def test_zero_executed_swift_methods_cannot_pass(self):
        import json
        result, report = self.run_gate(swift=True)
        self.assertEqual(result, 1)
        row = next(r for r in json.loads(report)['rows'] if r['flow']=='scoped Swift flow coverage')
        self.assertEqual(row['status'], 'FAIL')
        self.assertGreater(len(row['missingCases']), 0)

    def test_inventory_matches_sources_and_generator(self):
        spec = importlib.util.spec_from_file_location('coverage_generator', gate.ROOT / 'scripts/generate-e2e-2.4-coverage.py')
        module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
        import json
        rows = json.loads((gate.ROOT / 'tests/fixtures/e2e-2.4/coverage.json').read_text())
        self.assertEqual(rows, module.generate())
        for row in rows:
            source = (gate.ROOT / row['source']).read_text()
            for case in row['cases']:
                self.assertIn('func ' + case.split('/')[1] + '(', source)

    def test_every_declared_suite_exists(self):
        for suites in gate.CASES.values():
            for suite in suites:
                self.assertTrue((gate.ROOT / 'src/__tests__' / (suite + '.test.ts')).is_file(), suite)

    def test_pending_native_blocks_release(self):
        result, report = self.run_gate(release=True)
        self.assertEqual(result, 1)
        self.assertIn('UNPROVED-native', report)

    def test_suite_failure_blocks_isolated_gate(self):
        result, _ = self.run_gate(returncode=1)
        self.assertEqual(result, 1)

    def test_isolated_success_is_explicitly_not_release_ready(self):
        result, report = self.run_gate()
        self.assertEqual(result, 0)
        self.assertIn('"releaseReady": false', report)

if __name__ == '__main__':
    unittest.main()
