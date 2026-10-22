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
# GATECAP1: every frame and movie must declare a QA-only capture source.
QA_CAPTURE = dict(source='qa-window-id', status='PROVEN', windows=[4242])
QA_SOURCE = dict(kind='application', bundle='com.voicelayer.voicebar.uie2e', executable='/private/tmp/vl-ui-x/VoiceBarQA.app/Contents/MacOS/VoiceBar', observedPids=[4242], fullDisplay=False)


class ReportTests(unittest.TestCase):
    def test_seek2_can_no_longer_be_waived_as_an_expected_failure(self):
        step = dict(passed=True, expectedFailure=dict(packet='SEEK2', surface='notch:seek-idle',
                    descriptions=['[SEEK2] readback must seek']))
        with self.assertRaises(ValueError):
            results.expected_packet(step)

    def test_expected_packet_failure_is_explicit_xfail_and_unmatched_cannot_pass(self):
        (self.root / 'a.png').write_bytes(b'png')
        step = dict(evidenceContract='visible', capture=QA_CAPTURE, number=1, name='newline frame', attachment='UIE2E-0001', passed=True,
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
        step = dict(evidenceContract='visible', capture=QA_CAPTURE, number=1, name='unexpected result', attachment='UIE2E-0001', passed=False)
        attachment = dict(suggestedHumanReadableName='UIE2E-0001', exportedFileName='a.png', isAssociatedWithFailure=False)
        self.assertFalse(results.report(self.root, [step], [dict(attachments=[attachment])]))
        step['expectedFailure'] = dict(packet='SEL1', surface='notch:supersede-preparing', descriptions=['[SEL1] replacement'])
        with self.assertRaises(ValueError):
            results.report(self.root, [step], [dict(attachments=[attachment])])

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(suffix='.noindex', dir=BUILD_ROOT)
        self.root = pathlib.Path(self.temp.name)
        self.addCleanup(self.temp.cleanup)
        inventory = patch.object(results, 'verify_no_system_capture')
        inventory.start(); self.addCleanup(inventory.stop)

    def test_order_is_action_order_and_missing_image_fails_closed(self):
        (self.root / 'a.png').write_bytes(b'png')
        (self.root / 'b.png').write_bytes(b'png')
        steps = [dict(evidenceContract='visible', capture=QA_CAPTURE, number=i, name=f'<click {i}>', attachment=f'UIE2E-{i:04d}', passed=True) for i in (1, 2)]
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
        ledger = dict(version=1, steps=[dict(evidenceContract='visible', capture=QA_CAPTURE, number=1, name='click', attachment='UIE2E-0001', passed=True)],
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
        step = dict(evidenceContract='visible', capture=QA_CAPTURE, number=1, name='click', attachment='UIE2E-0001', passed=True)
        attachment = dict(suggestedHumanReadableName='UIE2E-0001', exportedFileName='a.png', isAssociatedWithFailure=False)
        with self.assertRaises(ValueError):
            results.report(self.root, [step], [dict(attachments=[attachment, attachment])])

    def test_failure_does_not_become_pass(self):
        (self.root / 'a.png').write_bytes(b'png')
        step = dict(evidenceContract='visible', capture=QA_CAPTURE, number=1, name='click', attachment='UIE2E-0001', passed=False)
        attachment = dict(suggestedHumanReadableName='UIE2E-0001', exportedFileName='a.png', isAssociatedWithFailure=False)
        self.assertFalse(results.report(self.root, [step], [dict(attachments=[attachment])]))

    def test_capability_skip_is_logged_without_becoming_a_failure(self):
        (self.root / 'a.png').write_bytes(b'png')
        step = dict(evidenceContract='visible', capture=QA_CAPTURE, number=1, name='S3 not in this build', attachment='UIE2E-0001', passed=True,
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

    def test_configure_refuses_every_guarded_scenario_without_the_exact_guard_proof(self):
        products = self.root / 'DerivedData/Build/Products'
        products.mkdir(parents=True)
        for scenario in ['hide1', 'gate2246']:
            with self.subTest(scenario=scenario):
                (self.root / 'scenario.json').unlink(missing_ok=True)
                (self.root / 'UIE2E.xctestrun').unlink(missing_ok=True)
                (products / 'test.xctestrun').write_bytes(plistlib.dumps({'VoiceBarUIE2ETests': {'EnvironmentVariables': {}}}))
                with self.assertRaises(FileNotFoundError):
                    results.configure(self.root, self.root / 'QA.app', self.root / 'sandbox', scenario)
                self.assertFalse((self.root / 'UIE2E.xctestrun').exists())
                with patch.object(results, 'load_guard') as load:
                    load.return_value.required.return_value = True
                    load.return_value.verify.return_value = self.root / 'device-guard.dylib'
                    results.configure(self.root, self.root / 'QA.app', self.root / 'sandbox', scenario)
                env = plistlib.loads((self.root / 'UIE2E.xctestrun').read_bytes())['VoiceBarUIE2ETests']['EnvironmentVariables']
                self.assertEqual(env['VOICEBAR_UIE2E_DEVICE_GUARD'], str(self.root / 'device-guard.dylib'))

    INSTALLED = 'voicebar-no-device-guard-v1:installed\n'

    def guard_logs(self, sandbox, *contents):
        for launch, text in enumerate(contents, 1):
            name = 'no-device-guard.log' if launch == 1 else 'no-device-guard-launch-%d.log' % launch
            (sandbox / name).write_text(text)

    def test_guard_receipt_steps_cover_every_launch_and_the_scenario_boundaries(self):
        launch = lambda n: {'GUARD launch %d installed' % n, 'GUARD launch %d no tripwire' % n}
        for scenario, prefix in [('hide1', 'HIDE1VIS'), ('gate2246', 'GATE2246')]:
            with self.subTest(scenario=scenario):
                self.assertEqual(results.guard_receipt_steps(scenario, 1),
                                 {prefix + ' no-device guard installed before fixtures',
                                  prefix + ' no device-start or process tripwire invoked'} | launch(1))
        self.assertEqual(results.guard_receipt_steps('full', 3, gate_build=True),
                         {'GATE2245 no-device guard installed before fixtures',
                          'GATE2245 no device-start or process tripwire invoked'} | launch(1) | launch(2) | launch(3))
        self.assertEqual(results.guard_receipt_steps('full', 0), set())
        self.assertEqual(results.guard_receipt_steps('focused-338', 0), set())

    def test_one_install_marker_per_launch_passes_and_any_other_line_is_a_trip(self):
        sandbox = self.root / 'sandbox'; sandbox.mkdir()
        self.assertEqual(results.guard_launch_issues(sandbox, 1), ['FAIL no-device guard receipt missing for launch 1'])
        self.guard_logs(sandbox, self.INSTALLED, self.INSTALLED)
        self.assertEqual(results.guard_launch_issues(sandbox, 2), [])
        for launch in [1, 2]:
            with self.subTest(trip_on=launch):
                logs = [self.INSTALLED, self.INSTALLED]
                logs[launch - 1] += 'AudioDeviceStart\n'
                self.guard_logs(sandbox, *logs)
                issues = results.guard_launch_issues(sandbox, 2)
                self.assertEqual(issues, ['FAIL device tripwire on launch %d: AudioDeviceStart' % launch])
        # Two installs in one launch log mean two processes shared one receipt: never accepted.
        self.guard_logs(sandbox, self.INSTALLED * 2, self.INSTALLED)
        self.assertEqual(results.guard_launch_issues(sandbox, 2),
                         ['FAIL launch 1 guard receipt is not exactly one install marker'])
        # A gap in the launch sequence cannot hide a launch.
        self.guard_logs(sandbox, self.INSTALLED, self.INSTALLED)
        (sandbox / 'no-device-guard-launch-2.log').rename(sandbox / 'no-device-guard-launch-3.log')
        self.assertEqual(results.guard_launch_issues(sandbox, 2),
                         ['FAIL unexpected no-device guard launch logs: no-device-guard-launch-3.log',
                          'FAIL no-device guard receipt missing for launch 2'])

    def named_run(self, names, scenario):
        directory = self.root / 'screenshots'; directory.mkdir()
        steps = [dict(evidenceContract='visible', capture=QA_CAPTURE, number=n, name=name, attachment='UIE2E-%04d' % n, passed=True) for n, name in enumerate(names, 1)]
        coverage = dict(observed=[], exercised=[], missing=[], scenario=scenario)
        ledger = dict(version=1, steps=steps, completed=True, failures=0, coverage=coverage, knownVisualGaps=[],
                      scenario=scenario, scope=scenario)
        manifest = []
        for step in steps:
            png = '%04d.png' % step['number']
            (directory / png).write_bytes(b'png' + str(step['number']).encode())
            (directory / ('r%04d.json' % step['number'])).write_text(json.dumps(step))
            manifest += [dict(suggestedHumanReadableName=step['attachment'] + '_0_UUID.png', exportedFileName=png,
                              isAssociatedWithFailure=False),
                         dict(suggestedHumanReadableName='UIE2E-RECEIPT-%04d_0_UUID.json' % step['number'],
                              exportedFileName='r%04d.json' % step['number'], isAssociatedWithFailure=False)]
        (directory / 'ledger.json').write_text(json.dumps(ledger))
        manifest.append(dict(suggestedHumanReadableName='UIE2E-LEDGER_0_UUID.json', exportedFileName='ledger.json',
                             isAssociatedWithFailure=False))
        (directory / 'manifest.json').write_text(json.dumps([dict(attachments=manifest)]))
        (self.root / 'run.mov').write_bytes(b'video')
        (self.root / 'recording.json').write_text(json.dumps(dict(path='run.mov', valid=True, captureSource=QA_SOURCE, durationSeconds=1, bytes=5)))
        (self.root / 'scenario.json').write_text(json.dumps({'scenario': scenario}))
        sandbox = self.root / 'sandbox'; sandbox.mkdir()
        return sandbox

    def test_gate2245_full_run_with_a_relaunch_requires_receipts_for_both_launches(self):
        names = ['launch isolated QA app', 'GUARD launch 1 installed',
                 'GATE2245 no-device guard installed before fixtures', 'HIDE1 fixtures',
                 'GATE2245 no device-start or process tripwire invoked', 'popover quit',
                 'GUARD launch 1 no tripwire', 'relaunch isolated QA app', 'GUARD launch 2 installed',
                 'terminate QA app', 'GUARD launch 2 no tripwire']
        for case in ['clean', 'trip-on-relaunch', 'missing-relaunch-step', 'missing-boundary-step']:
            with self.subTest(case=case):
                for path in [self.root / 'screenshots', self.root / 'sandbox']:
                    if path.exists():
                        __import__('shutil').rmtree(path)
                run_names = [n for n in names if not (
                    (case == 'missing-relaunch-step' and n == 'GUARD launch 2 no tripwire')
                    or (case == 'missing-boundary-step' and n.startswith('GATE2245 no device-start')))]
                sandbox = self.named_run(run_names, 'full')
                (sandbox / 'VoiceBarQA.app/Contents').mkdir(parents=True)
                (sandbox / 'VoiceBarQA.app/Contents/Info.plist').write_bytes(plistlib.dumps({'UIE2EGate2245': True}))
                self.guard_logs(sandbox, self.INSTALLED,
                                self.INSTALLED + ('posix_spawn\n' if case == 'trip-on-relaunch' else ''))
                with patch.object(results.subprocess, 'run'):
                    passed = results.export(self.root, sandbox)
                self.assertEqual(passed, case == 'clean')
                qa = json.loads((self.root / 'qa-report.json').read_text())
                if case == 'trip-on-relaunch':
                    self.assertIn('FAIL device tripwire on launch 2: posix_spawn', qa['issues'])
                if case.startswith('missing'):
                    self.assertTrue(any(i.startswith('FAIL no-device guard receipt steps missing') for i in qa['issues']))

    def test_ordinary_full_run_needs_no_guard_receipts(self):
        sandbox = self.named_run(['launch isolated QA app', 'terminate QA app'], 'full')
        with patch.object(results.subprocess, 'run'):
            self.assertTrue(results.export(self.root, sandbox))

    def guarded_full_run(self, launches=2, extra_names=()):
        names = ['launch isolated QA app', 'GUARD launch 1 installed',
                 'GATE2245 no-device guard installed before fixtures',
                 'GATE2245 no device-start or process tripwire invoked']
        for launch in range(2, launches + 1):
            names += ['GUARD launch %d no tripwire' % (launch - 1),
                      'relaunch isolated QA app', 'GUARD launch %d installed' % launch]
        names += ['terminate QA app', 'GUARD launch %d no tripwire' % launches]
        sandbox = self.named_run(names + list(extra_names), 'full')
        contents = sandbox / 'VoiceBarQA.app/Contents'; contents.mkdir(parents=True)
        (contents / 'Info.plist').write_bytes(plistlib.dumps({'UIE2EGate2245': True}))
        self.guard_logs(sandbox, *([self.INSTALLED] * launches))
        return sandbox

    def export_guarded_run(self, sandbox):
        with patch.object(results.subprocess, 'run'):
            return results.export(self.root, sandbox)

    def test_two_launch_ledger_cannot_pass_after_final_log_is_deleted(self):
        sandbox = self.guarded_full_run()
        self.assertTrue(self.export_guarded_run(sandbox))
        (sandbox / 'no-device-guard-launch-2.log').unlink()
        self.assertFalse(self.export_guarded_run(sandbox))
        self.assertIn('launch 2', ' '.join(json.loads((self.root / 'qa-report.json').read_text())['issues']))

    def test_extra_unrecorded_log_fails_even_with_orphan_guard_steps(self):
        sandbox = self.guarded_full_run(extra_names=[
            'GUARD launch 3 installed', 'GUARD launch 3 no tripwire'])
        (sandbox / 'no-device-guard-launch-3.log').write_text(self.INSTALLED)
        self.assertFalse(self.export_guarded_run(sandbox))

    def test_extra_unrecorded_log_fails_without_guard_steps(self):
        sandbox = self.guarded_full_run()
        (sandbox / 'no-device-guard-launch-3.log').write_text(self.INSTALLED)
        self.assertFalse(self.export_guarded_run(sandbox))

    def test_all_recorded_launch_logs_and_guard_steps_pass(self):
        sandbox = self.guarded_full_run(launches=3)
        self.assertTrue(self.export_guarded_run(sandbox))
        self.assertEqual(json.loads((self.root / 'qa-report.json').read_text())['issues'], [])

    def test_misnumbered_launch_log_fails(self):
        sandbox = self.guarded_full_run()
        log = sandbox / 'no-device-guard-launch-2.log'
        for name in ['no-device-guard-launch-3.log', 'no-device-guard-launch-02.log',
                     'no-device-guard-launch-1.log', 'no-device-guard-launch-other.log']:
            with self.subTest(name=name):
                wrong = log.rename(sandbox / name)
                self.assertFalse(self.export_guarded_run(sandbox))
                wrong.rename(log)

    def test_each_launch_requires_exactly_one_of_each_guard_step(self):
        sandbox = self.guarded_full_run(extra_names=['GUARD launch 2 no tripwire'])
        self.assertFalse(self.export_guarded_run(sandbox))

    def test_relaunch_action_requires_evidence_even_when_both_guard_steps_are_missing(self):
        names = ['launch isolated QA app', 'GUARD launch 1 installed',
                 'GATE2245 no-device guard installed before fixtures',
                 'GATE2245 no device-start or process tripwire invoked',
                 'GUARD launch 1 no tripwire', 'relaunch isolated QA app', 'terminate QA app']
        sandbox = self.named_run(names, 'full')
        contents = sandbox / 'VoiceBarQA.app/Contents'; contents.mkdir(parents=True)
        (contents / 'Info.plist').write_bytes(plistlib.dumps({'UIE2EGate2245': True}))
        self.guard_logs(sandbox, self.INSTALLED)
        self.assertFalse(self.export_guarded_run(sandbox))

    def test_guarded_scenarios_reconcile_launch_actions_and_unique_guard_steps(self):
        sandbox = self.root / 'sandbox'; sandbox.mkdir()
        self.guard_logs(sandbox, self.INSTALLED, self.INSTALLED)
        for scenario in ['full', 'hide1', 'gate2246']:
            with self.subTest(scenario=scenario):
                if scenario == 'full':
                    contents = sandbox / 'VoiceBarQA.app/Contents'; contents.mkdir(parents=True)
                    (contents / 'Info.plist').write_bytes(plistlib.dumps({'UIE2EGate2245': True}))
                actions = ['launch isolated QA app', 'relaunch isolated QA app']
                names = actions + sorted(results.guard_receipt_steps(scenario, 2, gate_build=True))
                self.assertEqual(results.guard_export_issues(scenario, sandbox, names), [])
                for phase in ['installed', 'no tripwire']:
                    receipt = 'GUARD launch 2 ' + phase
                    for bad_names in [[n for n in names if n != receipt], names + [receipt]]:
                        self.assertTrue(results.guard_export_issues(scenario, sandbox, bad_names))
                for bad_names in [[n for n in names if n not in actions],
                                  names + ['launch isolated QA app'],
                                  actions[::-1] + names[2:]]:
                    self.assertTrue(results.guard_export_issues(scenario, sandbox, bad_names))

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
        step = dict(evidenceContract='visible', capture=QA_CAPTURE, number=1, name='click', attachment='UIE2E-0001', passed=True)
        attachment = dict(suggestedHumanReadableName='UIE2E-0001', exportedFileName='a.png', isAssociatedWithFailure=False)
        recording = dict(path='run.mov', valid=True, captureSource=QA_SOURCE, durationSeconds=1.25, bytes=123)
        self.assertTrue(results.report(directory, [step], [dict(attachments=[attachment])], recording))
        page = (directory / 'index.html').read_text()
        self.assertIn('../run.mov', page)
        self.assertIn('1.25 s', page)
        self.assertIn('123 bytes', page)
        with self.assertRaises(ValueError):
            results.report(directory, [step], [dict(attachments=[attachment])], dict(recording, valid=False))

    def test_valid_video_from_a_cancelled_run_cannot_pass_the_contact_sheet(self):
        (self.root / 'a.png').write_bytes(b'png')
        step = dict(evidenceContract='visible', capture=QA_CAPTURE, number=1, name='click', attachment='UIE2E-0001', passed=True)
        attachment = dict(suggestedHumanReadableName='UIE2E-0001', exportedFileName='a.png', isAssociatedWithFailure=False)
        recording = dict(path='run.mov', valid=True, captureSource=QA_SOURCE, durationSeconds=1.25, bytes=123,
                         runPassed=False, cancelledSignals=[15], error='UI run interrupted by signal 15')
        self.assertFalse(results.report(self.root, [step], [dict(attachments=[attachment])], recording))
        self.assertIn('interrupted', (self.root / 'index.html').read_text())

    def attachment_run(self, *, complete=True, gaps=None, failures=0):
        directory = self.root / 'screenshots'; directory.mkdir()
        step = dict(evidenceContract='visible', capture=QA_CAPTURE, number=1, name='click', attachment='UIE2E-0001', passed=True)
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
        (self.root / 'recording.json').write_text(json.dumps(dict(path='run.mov', valid=True, captureSource=QA_SOURCE, durationSeconds=1, bytes=5)))
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
