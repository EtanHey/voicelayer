#!/usr/bin/env python3
import importlib.util
import json
import pathlib
import plistlib
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('results', pathlib.Path(__file__).with_name('voicebar-ui-e2e-results.py'))
results = importlib.util.module_from_spec(spec)
spec.loader.exec_module(results)


class ReportTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self.temp.name)
        self.addCleanup(self.temp.cleanup)

    def test_order_is_action_order_and_missing_image_fails_closed(self):
        (self.root / 'a.png').write_bytes(b'png')
        (self.root / 'b.png').write_bytes(b'png')
        steps = [dict(number=i, name=f'<click {i}>', attachment=f'UIE2E-{i:04d}', passed=True) for i in (1, 2)]
        attachments = [dict(suggestedHumanReadableName=f'UIE2E-{i:04d}.png', exportedFileName=name, isAssociatedWithFailure=False)
                       for i, name in [(2, 'b.png'), (1, 'a.png')]]
        self.assertTrue(results.report(self.root, steps, [dict(attachments=attachments)]))
        html = (self.root / 'index.html').read_text()
        self.assertLess(html.index('&lt;click 1&gt;'), html.index('&lt;click 2&gt;'))
        (self.root / 'b.png').unlink()
        with self.assertRaises(ValueError):
            results.report(self.root, steps, [dict(attachments=attachments)])

    def test_zero_steps_and_duplicate_screenshots_cannot_pass(self):
        with self.assertRaises(ValueError):
            results.report(self.root, [], [])
        step = dict(number=1, name='click', attachment='UIE2E-0001', passed=True)
        attachment = dict(suggestedHumanReadableName='UIE2E-0001', exportedFileName='a.png', isAssociatedWithFailure=False)
        with self.assertRaises(ValueError):
            results.report(self.root, [step], [dict(attachments=[attachment, attachment])])

    def test_failure_does_not_become_pass(self):
        (self.root / 'a.png').write_bytes(b'png')
        step = dict(number=1, name='click', attachment='UIE2E-0001', passed=False)
        attachment = dict(suggestedHumanReadableName='UIE2E-0001', exportedFileName='a.png', isAssociatedWithFailure=False)
        self.assertFalse(results.report(self.root, [step], [dict(attachments=[attachment])]))

    def test_capability_skip_is_logged_without_becoming_a_failure(self):
        (self.root / 'a.png').write_bytes(b'png')
        step = dict(number=1, name='S3 not in this build', attachment='UIE2E-0001', passed=True,
                    skipped='S3 not in this build')
        attachment = dict(suggestedHumanReadableName='UIE2E-0001', exportedFileName='a.png', isAssociatedWithFailure=False)
        self.assertTrue(results.report(self.root, [step], [dict(attachments=[attachment])]))
        self.assertIn('SKIP S3 not in this build', (self.root / 'index.html').read_text())

    def test_configure_resolves_testroot_without_touching_launch_environment(self):
        products = self.root / 'DerivedData/Build/Products'
        products.mkdir(parents=True)
        (products / 'test.xctestrun').write_bytes(plistlib.dumps({'VoiceBarUIE2ETests': {
            'TestBundlePath': '__TESTROOT__/Debug/Test.xctest', 'EnvironmentVariables': {'Existing': 'kept'}}}))
        results.configure(self.root, self.root / 'QA.app', self.root / 'sandbox')
        target = plistlib.loads((self.root / 'UIE2E.xctestrun').read_bytes())['VoiceBarUIE2ETests']
        self.assertEqual(target['EnvironmentVariables']['Existing'], 'kept')
        self.assertEqual(target['EnvironmentVariables']['VOICEBAR_UIE2E_APP'], str(self.root / 'QA.app'))
        self.assertEqual(target['TestBundlePath'], str(products / 'Debug/Test.xctest'))

    def test_contact_sheet_links_the_validated_recording_and_metadata(self):
        directory = self.root / 'screenshots'; directory.mkdir()
        (directory / 'a.png').write_bytes(b'png')
        step = dict(number=1, name='click', attachment='UIE2E-0001', passed=True)
        attachment = dict(suggestedHumanReadableName='UIE2E-0001', exportedFileName='a.png', isAssociatedWithFailure=False)
        recording = dict(path='run.mov', valid=True, durationSeconds=1.25, bytes=123)
        self.assertTrue(results.report(directory, [step], [dict(attachments=[attachment])], recording))
        page = (directory / 'index.html').read_text()
        self.assertIn('../run.mov', page)
        self.assertIn('1.25 s', page)
        self.assertIn('123 bytes', page)
        with self.assertRaises(ValueError):
            results.report(directory, [step], [dict(attachments=[attachment])], dict(recording, valid=False))

    def test_valid_video_from_a_cancelled_run_cannot_pass_the_contact_sheet(self):
        (self.root / 'a.png').write_bytes(b'png')
        step = dict(number=1, name='click', attachment='UIE2E-0001', passed=True)
        attachment = dict(suggestedHumanReadableName='UIE2E-0001', exportedFileName='a.png', isAssociatedWithFailure=False)
        recording = dict(path='run.mov', valid=True, durationSeconds=1.25, bytes=123,
                         runPassed=False, cancelledSignals=[15], error='UI run interrupted by signal 15')
        self.assertFalse(results.report(self.root, [step], [dict(attachments=[attachment])], recording))
        self.assertIn('interrupted', (self.root / 'index.html').read_text())

    def attachment_run(self, *, complete=True, gaps=None, failures=0):
        directory = self.root / 'screenshots'; directory.mkdir()
        step = dict(number=1, name='click', attachment='UIE2E-0001', passed=True)
        coverage = dict(observed=['Ask/response/Paste'], exercised=['Ask/response/Paste'], missing=[])
        ledger = dict(version=1, steps=[step], completed=complete, failures=failures,
                      coverage=coverage, knownVisualGaps=gaps or [])
        (directory / 'a.png').write_bytes(b'png')
        manifest = []
        for name, filename, data in [('UIE2E-0001', 'a.png', None),
                                     ('UIE2E-RECEIPT-0001', 'step.json', step),
                                     ('UIE2E-LEDGER', 'ledger.json', ledger)]:
            if data is not None:
                (directory / filename).write_text(json.dumps(data))
            manifest.append(dict(suggestedHumanReadableName=name + '_0_UUID.json', exportedFileName=filename,
                                 isAssociatedWithFailure=False))
        (directory / 'manifest.json').write_text(json.dumps([dict(attachments=manifest)]))
        (self.root / 'run.mov').write_bytes(b'video')
        (self.root / 'recording.json').write_text(json.dumps(dict(path='run.mov', valid=True, durationSeconds=1, bytes=5)))
        return directory, ledger, manifest

    def export_attached_run(self):
        # The signed test runner cannot write here. Only exported XCTest attachments exist.
        with patch.object(results.subprocess, 'run'):
            return results.export(self.root, self.root / 'no-sandbox-ledger')

    def test_export_reads_attached_receipts_without_any_scratch_ledger(self):
        self.attachment_run()
        self.assertTrue(self.export_attached_run())
        self.assertEqual(json.loads((self.root / 'steps.json').read_text())[0]['name'], 'click')
        self.assertEqual(json.loads((self.root / 'coverage.json').read_text())['missing'], [])

    def test_partial_run_keeps_step_report_but_cannot_pass_without_final_ledger(self):
        directory, _, manifest = self.attachment_run()
        (directory / 'manifest.json').write_text(json.dumps([dict(attachments=manifest[:-1])]))
        self.assertFalse(self.export_attached_run())
        self.assertIn('completion', (directory / 'index.html').read_text())

    def test_visual_gap_cannot_be_hidden_by_passing_ax_text(self):
        directory, _, _ = self.attachment_run(gaps=['P1b note visibly truncates despite full AX text'])
        self.assertFalse(self.export_attached_run())
        self.assertIn('KNOWN VISUAL GAP', (directory / 'index.html').read_text())
        self.assertIn('visibly truncates', (directory / 'index.html').read_text())

    def test_duplicate_missing_mismatched_and_unsafe_receipts_fail_closed(self):
        directory, ledger, manifest = self.attachment_run()
        for attachments in [manifest + [manifest[1]], [manifest[0], manifest[2]],
                            [manifest[0], dict(manifest[1], exportedFileName='../steps.json'), manifest[2]]]:
            (directory / 'manifest.json').write_text(json.dumps([dict(attachments=attachments)]))
            with self.assertRaises(ValueError):
                self.export_attached_run()
        (directory / 'manifest.json').write_text(json.dumps([dict(attachments=manifest)]))
        ledger['steps'][0]['name'] = 'different action'
        (directory / 'ledger.json').write_text(json.dumps(ledger))
        with self.assertRaises(ValueError):
            self.export_attached_run()

    def test_unfinished_or_teardown_failed_suite_cannot_pass(self):
        directory, ledger, _ = self.attachment_run(complete=False)
        self.assertFalse(self.export_attached_run())
        ledger.update(completed=True, failures=1)
        (directory / 'ledger.json').write_text(json.dumps(ledger))
        self.assertFalse(self.export_attached_run())

    def test_failed_action_attachment_still_exports_a_failed_contact_sheet(self):
        directory, ledger, manifest = self.attachment_run()
        ledger['steps'][0]['passed'] = False
        ledger['failures'] = 1
        manifest[1]['isAssociatedWithFailure'] = True
        (directory / 'step.json').write_text(json.dumps(ledger['steps'][0]))
        (directory / 'ledger.json').write_text(json.dumps(ledger))
        (directory / 'manifest.json').write_text(json.dumps([dict(attachments=manifest)]))
        self.assertFalse(self.export_attached_run())
        self.assertIn('0001 FAIL click', (directory / 'index.html').read_text())


if __name__ == '__main__':
    unittest.main()
