#!/usr/bin/env python3
import importlib.util
import pathlib
import plistlib
import tempfile
import unittest

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


if __name__ == '__main__':
    unittest.main()
