#!/usr/bin/env python3
import importlib.util
import json
import pathlib
import plistlib
import tempfile
import unittest

BUILD_ROOT = pathlib.Path(__file__).resolve().parents[1] / ".build.noindex"
BUILD_ROOT.mkdir(exist_ok=True)
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('results', pathlib.Path(__file__).with_name('voicebar-ui-e2e-results.py'))
results = importlib.util.module_from_spec(spec)
spec.loader.exec_module(results)


class ReportTests(unittest.TestCase):
    def test_seek2_can_no_longer_be_waived_as_an_expected_failure(self):
        step = dict(passed=True, expectedFailure=dict(packet='SEEK2', surface='notch:seek-idle',
                    descriptions=['[SEEK2] readback must seek']))
        with self.assertRaises(ValueError):
            results.expected_packet(step)

    def test_expected_packet_failure_is_explicit_xfail_and_unmatched_cannot_pass(self):
        (self.root / 'a.png').write_bytes(b'png')
        step = dict(number=1, name='newline frame', attachment='UIE2E-0001', passed=True,
                    expectedFailure=dict(packet='P14b', surface='notch:list-newlines',
                                         descriptions=['[P14b] items remain on one line']))
        attachment = dict(suggestedHumanReadableName='UIE2E-0001', exportedFileName='a.png', isAssociatedWithFailure=True)
        self.assertTrue(results.report(self.root, [step], [dict(attachments=[attachment])]))
        self.assertIn('XFAIL [P14b]', (self.root / 'index.html').read_text())
        step['expectedFailure']['descriptions'] = []
        with self.assertRaises(ValueError):
            results.report(self.root, [step], [dict(attachments=[attachment])])
        step['expectedFailure']['descriptions'] = ['Missing control: unrelated harness failure']
        with self.assertRaises(ValueError):
            results.report(self.root, [step], [dict(attachments=[attachment])])

    def test_expected_surface_without_matching_receipt_stays_blocking(self):
        directory, ledger, manifest = self.attachment_run()
        ledger['coverage'].update(expectedSurfaces={'notch:seek-idle': 'SEEK2'}, missingSurfaces=[])
        (directory / 'ledger.json').write_text(json.dumps(ledger))
        with self.assertRaises(ValueError):
            self.export_attached_run()

    def test_observed_expected_surface_exports_without_becoming_verified(self):
        directory, ledger, manifest = self.attachment_run()
        expected = dict(packet='P14b', surface='notch:list-newlines', descriptions=['[P14b] same visual line'])
        ledger['steps'][0]['expectedFailure'] = expected
        ledger['coverage'].update(expectedSurfaces={'notch:list-newlines': 'P14b'}, missingSurfaces=[], verifiedSurfaces=[])
        (directory / 'step.json').write_text(json.dumps(ledger['steps'][0]))
        (directory / 'ledger.json').write_text(json.dumps(ledger))
        self.assertTrue(self.export_attached_run())
        self.assertIn('XFAIL [P14b]', (directory / 'index.html').read_text())
        ledger['coverage']['verifiedSurfaces'] = ['notch:list-newlines']
        (directory / 'ledger.json').write_text(json.dumps(ledger))
        with self.assertRaises(ValueError):
            self.export_attached_run()

    def test_unexpected_pass_or_unmatched_failure_cannot_use_an_expected_tag(self):
        (self.root / 'a.png').write_bytes(b'png')
        step = dict(number=1, name='unexpected result', attachment='UIE2E-0001', passed=False)
        attachment = dict(suggestedHumanReadableName='UIE2E-0001', exportedFileName='a.png', isAssociatedWithFailure=False)
        self.assertFalse(results.report(self.root, [step], [dict(attachments=[attachment])]))
        step['expectedFailure'] = dict(packet='SEL1', surface='notch:supersede-preparing', descriptions=['[SEL1] replacement'])
        with self.assertRaises(ValueError):
            results.report(self.root, [step], [dict(attachments=[attachment])])

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(suffix='.noindex', dir=BUILD_ROOT)
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

    def test_unverified_surfaces_fail_even_with_passing_control_receipts(self):
        coverage = dict(observed=[], exercised=[], missing=[], missingSurfaces=['Speech', 'notch:seek-idle'])
        ledger = dict(version=1, steps=[dict(number=1, name='click', attachment='UIE2E-0001', passed=True)],
                      completed=True, failures=0, coverage=coverage, knownVisualGaps=[])
        (self.root / 'step.json').write_text(json.dumps(ledger['steps'][0]))
        (self.root / 'ledger.json').write_text(json.dumps(ledger))
        attachments = [dict(suggestedHumanReadableName='UIE2E-RECEIPT-0001.json', exportedFileName='step.json', isAssociatedWithFailure=False),
                       dict(suggestedHumanReadableName='UIE2E-LEDGER.json', exportedFileName='ledger.json', isAssociatedWithFailure=False)]
        _, _, issues = results.receipts(self.root, [dict(attachments=attachments)])
        self.assertIn('FAIL unverified surfaces: Speech, notch:seek-idle', issues)

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

    def test_configure_replaces_combined_selection_in_both_plist_formats(self):
        products = self.root / 'DerivedData/Build/Products'
        products.mkdir(parents=True)
        for modern in [False, True]:
            for scenario, method in [('full', 'testFullUIOnlyFlow'), ('focused-338', 'testFocused338StateGallery')]:
                with self.subTest(modern=modern, scenario=scenario):
                    (self.root / 'scenario.json').unlink(missing_ok=True)
                    target = dict(OnlyTestIdentifiers=['VoiceBarFlowTests/testFullUIOnlyFlow',
                                                       'VoiceBarFlowTests/testFocused338StateGallery'],
                                  SkipTestIdentifiers=['VoiceBarFlowTests'], EnvironmentVariables={'Existing': 'kept'})
                    data = {'TestConfigurations': [{'TestTargets': [target]}]} if modern else {'VoiceBarUIE2ETests': target}
                    (products / 'test.xctestrun').write_bytes(plistlib.dumps(data))
                    results.configure(self.root, self.root / 'QA.app', self.root / 'sandbox', scenario)
                    data = plistlib.loads((self.root / 'UIE2E.xctestrun').read_bytes())
                    configured = data['TestConfigurations'][0]['TestTargets'][0] if modern else data['VoiceBarUIE2ETests']
                    self.assertEqual(configured['OnlyTestIdentifiers'], ['VoiceBarFlowTests/' + method])
                    self.assertNotIn('SkipTestIdentifiers', configured)
                    self.assertEqual(configured['EnvironmentVariables']['VOICEBAR_UIE2E_SCENARIO'], scenario)
                    self.assertEqual(json.loads((self.root / 'scenario.json').read_text())['scenario'], scenario)

    def focused_run(self):
        directory, ledger, manifest = self.attachment_run()
        ledger.update(scenario='focused-338', scope='focused-338')
        ledger['coverage']['scenario'] = 'focused-338'
        (directory / 'ledger.json').write_text(json.dumps(ledger))
        sandbox = self.root / 'sandbox'; sandbox.mkdir()
        (sandbox / 'gallery.json').write_text(json.dumps({'scenario': 'focused-338', 'pages': ['feedback']}))
        (sandbox / 'focused-scope.json').write_text(json.dumps({'scope': 'focused-338'}))
        (self.root / 'scenario.json').write_text(json.dumps({'scenario': 'focused-338'}))
        return directory, ledger, manifest, sandbox

    def full_run(self):
        directory, ledger, manifest = self.attachment_run()
        ledger.update(scenario='full', scope='full')
        ledger['coverage']['scenario'] = 'full'
        (directory / 'ledger.json').write_text(json.dumps(ledger))
        sandbox = self.root / 'sandbox'; sandbox.mkdir()
        (self.root / 'scenario.json').write_text(json.dumps({'scenario': 'full'}))
        return directory, ledger, manifest, sandbox

    def test_focused_export_copies_gallery_and_scope_and_labels_bounded_coverage(self):
        directory, _, _, sandbox = self.focused_run()
        with patch.object(results.subprocess, 'run'):
            self.assertTrue(results.export(self.root, sandbox))
        self.assertEqual((self.root / 'gallery.json').read_bytes(), (sandbox / 'gallery.json').read_bytes())
        self.assertEqual((self.root / 'focused-scope.json').read_bytes(), (sandbox / 'focused-scope.json').read_bytes())
        self.assertIn('focused-338', (directory / 'index.html').read_text())
        self.assertIn('full release coverage NOT_PROVEN', (directory / 'index.html').read_text())
        qa = json.loads((self.root / 'qa-report.json').read_text())
        self.assertEqual(qa['scenario'], 'focused-338')
        self.assertEqual(qa['verdict'], 'FOCUSED_SCENARIO_PASS')
        self.assertFalse(qa['fullReleasePass'])

    def test_focused_export_requires_gallery_and_matching_scope(self):
        directory, ledger, _, sandbox = self.focused_run()
        (sandbox / 'gallery.json').unlink()
        with patch.object(results.subprocess, 'run'), self.assertRaises(ValueError):
            results.export(self.root, sandbox)
        (sandbox / 'gallery.json').write_text('{}')
        ledger['scope'] = 'full'
        (directory / 'ledger.json').write_text(json.dumps(ledger))
        with patch.object(results.subprocess, 'run'), self.assertRaises(ValueError):
            results.export(self.root, sandbox)

    def test_focused_export_keeps_per_page_screenshot_and_failure_rules(self):
        directory, ledger, manifest, sandbox = self.focused_run()
        ledger['steps'][0]['skipped'] = 'gallery capability absent'
        (directory / 'step.json').write_text(json.dumps(ledger['steps'][0]))
        (directory / 'ledger.json').write_text(json.dumps(ledger))
        with patch.object(results.subprocess, 'run'):
            self.assertFalse(results.export(self.root, sandbox))
        ledger['steps'][0].pop('skipped')
        (directory / 'step.json').write_text(json.dumps(ledger['steps'][0]))
        (directory / 'ledger.json').write_text(json.dumps(ledger))
        (directory / 'manifest.json').write_text(json.dumps([dict(attachments=manifest[1:])]))
        with patch.object(results.subprocess, 'run'), self.assertRaises(ValueError):
            results.export(self.root, sandbox)

    def test_focused_p1e_expected_waiver_cannot_pass(self):
        directory, ledger, _, sandbox = self.focused_run()
        ledger['steps'][0]['expectedFailure'] = dict(packet='P1e', surface='feedback',
                                                   descriptions=['[P1e] clipped gallery text'])
        (directory / 'step.json').write_text(json.dumps(ledger['steps'][0]))
        (directory / 'ledger.json').write_text(json.dumps(ledger))
        with patch.object(results.subprocess, 'run'):
            self.assertFalse(results.export(self.root, sandbox))
        self.assertEqual(json.loads((self.root / 'qa-report.json').read_text())['verdict'], 'FAIL')

    def p1f_run(self, scenario='focused-338'):
        directory, ledger, manifest, sandbox = (
            self.focused_run() if scenario == 'focused-338' else self.full_run())
        surfaces = ['338:static:selection-' + suffix for suffix in
                    ['clipboard-changed', 'copy-timeout', 'copy-empty', 'copy-failed']]
        ledger['steps'][0].update(name='selection errors page', expectedFailure=dict(
            packet='P1f', surface='', surfaces=surfaces,
            descriptions=['[P1f] selection error text is clipped']))
        ledger['coverage'].update(expectedSurfaces=dict.fromkeys(surfaces, 'P1f'),
                                  missingSurfaces=[], verifiedSurfaces=[])
        for attachment in manifest[:2]:
            attachment['isAssociatedWithFailure'] = True
        (directory / 'manifest.json').write_text(json.dumps([dict(attachments=manifest)]))
        self.write_p1f_receipts(directory, ledger)
        return directory, ledger, manifest, sandbox

    def write_p1f_receipts(self, directory, ledger):
        (directory / 'step.json').write_text(json.dumps(ledger['steps'][0]))
        (directory / 'ledger.json').write_text(json.dumps(ledger))

    def test_focused_p1f_aggregated_four_surface_waiver_fails_after_merge(self):
        directory, ledger, _, sandbox = self.p1f_run()
        with patch.object(results.subprocess, 'run'):
            self.assertFalse(results.export(self.root, sandbox))
        page = (directory / 'index.html').read_text()
        self.assertIn('FAIL focused-338 cannot use expected-failure waivers', page)
        self.assertIn('0001 FAIL selection errors page', page)
        self.assertNotIn('XFAIL [P1f]', page)
        self.assertEqual(page.count('<figure>'), 1)
        coverage = json.loads((self.root / 'coverage.json').read_text())
        self.assertEqual(coverage['expectedSurfaces'], ledger['coverage']['expectedSurfaces'])
        self.assertEqual(len(coverage['expectedSurfaces']), 4)
        self.assertEqual(coverage['verifiedSurfaces'], [])
        qa = json.loads((self.root / 'qa-report.json').read_text())
        self.assertEqual(qa['verdict'], 'FAIL')
        self.assertIn('P1f', ' '.join(qa['issues']))
        self.assertFalse(qa['fullReleasePass'])

    def test_full_p1f_aggregated_four_surface_expected_receipt_still_exports(self):
        directory, ledger, _, sandbox = self.p1f_run(scenario='full')
        with patch.object(results.subprocess, 'run'):
            self.assertTrue(results.export(self.root, sandbox))
        page = (directory / 'index.html').read_text()
        self.assertEqual(page.count('XFAIL [P1f]'), 1)
        qa = json.loads((self.root / 'qa-report.json').read_text())
        self.assertEqual(qa['scenario'], 'full')
        self.assertEqual(qa['verdict'], 'FULL_UI_SCENARIO_PASS')
        self.assertEqual(ledger['coverage']['scenario'], 'full')

    def test_p1f_missing_unknown_or_duplicate_scope_cannot_waive_coverage(self):
        directory, ledger, _, sandbox = self.p1f_run()
        expected = ledger['steps'][0]['expectedFailure']
        surfaces = expected['surfaces'][:]
        for invalid in [surfaces[:-1], surfaces[:-1] + ['338:static:unknown'],
                        surfaces + ['338:static:unknown'], surfaces + [surfaces[0]]]:
            with self.subTest(surfaces=invalid):
                expected['surfaces'] = invalid
                self.write_p1f_receipts(directory, ledger)
                with patch.object(results.subprocess, 'run'), self.assertRaises(ValueError):
                    results.export(self.root, sandbox)
        expected.pop('surfaces')
        self.write_p1f_receipts(directory, ledger)
        with patch.object(results.subprocess, 'run'), self.assertRaises(ValueError):
            results.export(self.root, sandbox)

    def test_p1f_unknown_packet_or_untagged_description_cannot_waive(self):
        directory, ledger, _, sandbox = self.p1f_run()
        expected = ledger['steps'][0]['expectedFailure']
        for packet, descriptions in [
                ('UNKNOWN', ['[UNKNOWN] clipped text']), ('P1f-extra', ['[P1f-extra] clipped text']),
                ('P1f', []), ('P1f', ['clipped text']), ('P1f', ['[P1f-extra] clipped text']),
                ('P1f', ['[P1f] clipped text', 'Missing control: unrelated harness failure']),
                ('P1f', ['[P1e] clipped text']), ('P1f', [None])]:
            with self.subTest(packet=packet, descriptions=descriptions):
                expected.update(packet=packet, descriptions=descriptions)
                self.write_p1f_receipts(directory, ledger)
                with patch.object(results.subprocess, 'run'), self.assertRaises(ValueError):
                    results.export(self.root, sandbox)

    def test_optional_expected_surfaces_must_be_nonempty_unique_strings(self):
        for packet in ['P14b', 'P1f']:
            for invalid in [None, [], 'scope', {}, [''], [' '], [None], [1], ['scope', 'scope']]:
                with self.subTest(packet=packet, surfaces=invalid):
                    step = dict(passed=True, expectedFailure=dict(packet=packet, surface='scope',
                                surfaces=invalid, descriptions=['[' + packet + '] clipped text']))
                    with self.assertRaises(ValueError):
                        results.expected_packet(step)

    def test_p1f_singular_surface_still_exports(self):
        directory, ledger, _, sandbox = self.p1f_run(scenario='full')
        expected = ledger['steps'][0]['expectedFailure']
        surface = expected.pop('surfaces')[0]
        expected['surface'] = surface
        ledger['coverage']['expectedSurfaces'] = {surface: 'P1f'}
        self.write_p1f_receipts(directory, ledger)
        with patch.object(results.subprocess, 'run'):
            self.assertTrue(results.export(self.root, sandbox))

    def test_legacy_packet_cannot_use_aggregate_surface_proof(self):
        directory, ledger, _, sandbox = self.p1f_run()
        ledger['steps'][0]['expectedFailure'].update(packet='P14b', descriptions=['[P14b] clipped text'])
        ledger['coverage']['expectedSurfaces'] = dict.fromkeys(
            ledger['coverage']['expectedSurfaces'], 'P14b')
        self.write_p1f_receipts(directory, ledger)
        with patch.object(results.subprocess, 'run'), self.assertRaises(ValueError):
            results.export(self.root, sandbox)

    def test_full_export_rejects_focused_ledger_without_metadata(self):
        directory, ledger, _, _ = self.focused_run()
        (self.root / 'scenario.json').unlink()
        with patch.object(results.subprocess, 'run'), self.assertRaises(ValueError):
            results.export(self.root, self.root / 'sandbox')

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
