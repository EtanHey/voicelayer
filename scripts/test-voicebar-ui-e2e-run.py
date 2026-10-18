#!/usr/bin/env python3
import contextlib
import html
import importlib.util
import io
import json
import os
import pathlib
import signal
import subprocess
import sys
import tempfile
import time
import unittest
import unittest.mock

MODULE = pathlib.Path(__file__).with_name('voicebar-ui-e2e-run.py')
spec = importlib.util.spec_from_file_location('runner', MODULE)
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)

# GATECAP1: one-shot modal gate + boundary broker (voicebar-ui-e2e-permissions) for run_suite.
HELPER = '''#!/usr/bin/env python3
import json,pathlib,signal,sys,time
root=pathlib.Path(__file__).parent.parent
with (root/'calls').open('a') as log: log.write('permissions '+json.dumps(sys.argv[1:])+'\\n')
if len(sys.argv)==6 and sys.argv[1]=='--broker':
 boundary=pathlib.Path(sys.argv[3])/'boundary'; boundary.mkdir(exist_ok=True)
 if not (root/'broker-never-ready').exists(): (boundary/'ready.json').write_text('{"ready":true}')
 signal.signal(signal.SIGTERM, lambda *a: sys.exit(0))
 if (root/'broker-latch').exists():
  time.sleep(.3); pathlib.Path(sys.argv[5]).write_text(json.dumps({'status':'stop','modals':[{'owner':'com.apple.coreservices.uiagent','source':'system-owner','title':'<redacted len=4 sha256=00000000>'}]}))
 while True: time.sleep(.05)
modals=[{'owner':'com.apple.coreservices.uiagent','pid':611,'title':'BrainBar is an app downloaded','source':'system-owner'}] if (root/'modal-visible').exists() else []
errors=[{'kind':'ax-windows','owner':'com.example.hung','pid':9,'reason':'cannot-complete'}] if (root/'inventory-error').exists() else []
print(json.dumps({'axTrusted':True,'prompts':[],'modals':modals,'inventoryErrors':errors}) if not (root/'helper-garbage').exists() else 'garbage')
'''

STUB = '''#!/usr/bin/env python3
import json,pathlib,sys,time
root=pathlib.Path(__file__).parent
with (root/'calls').open('a') as log: log.write(pathlib.Path(sys.argv[0]).name+' '+json.dumps(sys.argv[1:])+'\\n')
if '-version' in sys.argv or '--version' in sys.argv: sys.exit(0)
if pathlib.Path(sys.argv[0]).name=='voicebar-ui-e2e-visibility':
 mode=sys.argv[1]; receipt=pathlib.Path(sys.argv[2])
 if mode=='hide':
  receipt.write_text(json.dumps({'visibleBefore':['T3 Code','Editor'],'restored':False}))
  if (root/'visibility-denied').exists(): sys.exit(7)
  (root/'foreign-overlay').unlink(missing_ok=True)
 else:
  data=json.loads(receipt.read_text()) if receipt.exists() else {}
  data['restored']=True; receipt.write_text(json.dumps(data))
 sys.exit(0)
if pathlib.Path(sys.argv[0]).name=='ffprobe':
 if (root/'delay-probe').exists():
  (root/'probe-waiting').touch()
  while not (root/'release').exists(): time.sleep(.01)
 if (root/'invalid-media').exists(): sys.exit(1)
 movie=pathlib.Path(sys.argv[-1])
 if not movie.read_bytes().endswith(b'flushed'): sys.exit(1)
 streams=[{'codec_type':'video'}]
 if (root/'audio').exists(): streams.append({'codec_type':'audio'})
 print(json.dumps({'format':{'duration':'1.25'},'streams':streams})); sys.exit(0)
if (root/'denied').exists(): sys.exit(1)
if '-i' in sys.argv and (root/'cameras.json').exists():
 selector=sys.argv[sys.argv.index('-i')+1].split(':')[0]
 if any(name.startswith(selector) for name in json.loads((root/'cameras.json').read_text())):
  (root/'camera-opened').touch()
movie=pathlib.Path(sys.argv[-1]); movie.write_bytes(b'incremental-')
bundle='com.apple.finder' if (root/'foreign-source').exists() else 'com.voicelayer.voicebar.uie2e'
exe=sys.argv[sys.argv.index('--include-executable')+1] if '--include-executable' in sys.argv else ''
if (root/'stale-executable').exists(): exe='/private/tmp/vl-ui-OTHER/VoiceBarQA.app/Contents/MacOS/VoiceBar'
if not (root/'no-source').exists():
 print('source=application bundle='+bundle+' executable='+exe+' pids=',flush=True)
 if not (root/'no-pids').exists(): print('source=application bundle='+bundle+' executable='+exe+' pids=4242',flush=True)
print('frame=1',flush=True)
if (root/'early-end').exists():
 time.sleep(.2)
 with movie.open('ab') as output: output.write(b'flushed')
 sys.exit(0)
for line in sys.stdin:
 if line.strip()=='q':
  if (root/'delay-flush').exists():
   (root/'flush-waiting').touch()
   while not (root/'release').exists(): time.sleep(.01)
  with movie.open('ab') as output: output.write(b'flushed')
  with (root/'calls').open('a') as log: log.write('flushed\\n')
  sys.exit(0)
'''


class RunnerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = pathlib.Path(self.temp.name)
        self.output = self.root / 'output'; self.output.mkdir()
        for name in ['capture', 'ffprobe']:
            path = self.root / name; path.write_text(STUB); path.chmod(0o755)
        visibility = self.output / 'voicebar-ui-e2e-visibility'
        visibility.write_text(STUB.replace("root=pathlib.Path(__file__).parent", "root=pathlib.Path(__file__).parent.parent")); visibility.chmod(0o755)
        helper = self.output / 'voicebar-ui-e2e-permissions'; helper.write_text(HELPER); helper.chmod(0o755)
        (self.root / 'sandbox').mkdir()
        (self.output / 'sandbox-path.txt').write_text(str(self.root / 'sandbox') + '\n')

    def recorder(self):
        return runner.Recording(self.output, str(self.root / 'capture'), str(self.root / 'ffprobe'))

    def test_foreign_overlay_is_hidden_before_test_and_exact_visibility_restored(self):
        overlay = self.root / 'foreign-overlay'; overlay.touch()
        code = f'import pathlib,sys;sys.exit(8 if pathlib.Path({str(overlay)!r}).exists() else 0)'
        self.assertEqual(runner.run_suite(self.output, [sys.executable, '-c', code], self.recorder()), 0)
        receipt = json.loads((self.output / 'visibility.json').read_text())
        self.assertEqual(receipt['visibleBefore'], ['T3 Code', 'Editor'])
        self.assertTrue(receipt['restored'])

    def test_failed_hide_refuses_test_and_still_restores_visibility(self):
        (self.root / 'visibility-denied').touch()
        marker = self.root / 'test-started'
        code = f'open({str(marker)!r},"w").close()'
        self.assertNotEqual(runner.run_suite(self.output, [sys.executable, '-c', code], self.recorder()), 0)
        self.assertFalse(marker.exists())
        self.assertTrue(json.loads((self.output / 'visibility.json').read_text())['restored'])
        self.assertIn('Hide Others', json.loads((self.output / 'recording.json').read_text())['error'])

    def test_hide1_selects_only_visual_hide_test(self):
        args = runner.test_arguments(self.output, 'hide1')
        selected = [arg for arg in args if arg.startswith('-only-testing:')]
        self.assertEqual(selected, ['-only-testing:VoiceBarUIE2ETests/VoiceBarFlowTests/testHide1VisualFlow'])

    def test_argument_builder_uses_one_serial_run_without_invalid_iteration_option(self):
        args = runner.test_arguments(self.output)
        self.assertEqual(args[:2], ['xcodebuild', 'test-without-building'])
        self.assertNotIn('-test-iterations', args)
        self.assertEqual(args[args.index('-parallel-testing-enabled') + 1], 'NO')
        self.assertEqual(args[args.index('-resultBundlePath') + 1], str(self.output / 'VoiceBar.xcresult'))

    def test_each_scenario_selects_exactly_one_method_never_both(self):
        for scenario, method in [('full', 'testFullUIOnlyFlow'), ('focused-338', 'testFocused338StateGallery')]:
            with self.subTest(scenario=scenario):
                args = runner.test_arguments(self.output, scenario)
                self.assertEqual([a for a in args if a.startswith('-only-testing:')],
                                 ['-only-testing:VoiceBarUIE2ETests/VoiceBarFlowTests/' + method])
        with self.assertRaises(ValueError):
            runner.test_arguments(self.output, 'focused-338,full')

    def test_metadata_preserves_focused_selection_without_explicit_argument(self):
        (self.output / 'scenario.json').write_text(json.dumps({'scenario': 'focused-338'}))
        self.assertIn('-only-testing:VoiceBarUIE2ETests/VoiceBarFlowTests/testFocused338StateGallery',
                      runner.test_arguments(self.output))
        with self.assertRaises(ValueError):
            runner.test_arguments(self.output, 'full')

    def test_cli_rejects_unknown_scenario_before_output_or_native_tools(self):
        result = subprocess.run(['bash', str(MODULE.with_name('voicebar-ui-e2e.sh')),
                                 '--output', str(self.root / 'never-created'), '--scenario', 'all'],
                                capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('scenario', result.stderr)
        self.assertFalse((self.root / 'never-created').exists())

    def test_success_and_test_failure_both_flush_before_ffprobe(self):
        for code in [0, 7]:
            with self.subTest(code=code):
                result = runner.run_suite(self.output, [sys.executable, '-c', f'import sys;sys.exit({code})'], self.recorder())
                self.assertEqual(result, code)
                info = json.loads((self.output / 'recording.json').read_text())
                self.assertTrue(info['valid'])
                self.assertEqual(info['durationSeconds'], 1.25)
                self.assertGreater(info['bytes'], 0)
                calls = (self.root / 'calls').read_text()
                self.assertLess(calls.rindex('flushed'), calls.rindex('ffprobe ['))
                self.assertIn(info['path'], (self.output / 'recording.html').read_text())

    def test_camera_names_cannot_select_a_capture_device(self):
        for name in ['Capture screen 0', 'Capture screen 0 virtual camera']:
            with self.subTest(camera=name):
                (self.root / 'camera-opened').unlink(missing_ok=True)
                (self.root / 'cameras.json').write_text(json.dumps([name]))
                self.assertEqual(runner.run_suite(self.output, [sys.executable, '-c', 'pass'], self.recorder()), 0)
                self.assertFalse((self.root / 'camera-opened').exists(), 'AVFoundation prefix selected a camera')

    def test_default_capture_is_the_built_display_only_helper(self):
        args = runner.Recording(self.output).arguments()
        self.assertEqual(args[0], str(self.output / 'voicebar-ui-e2e-capture'))
        self.assertNotIn('avfoundation', args)

    def test_gatecap1_movie_records_only_the_proven_qa_process_windows(self):
        executable = str((self.root / 'sandbox/VoiceBarQA.app/Contents/MacOS/VoiceBar').resolve())
        args = runner.Recording(self.output).arguments()
        self.assertEqual(args[1:5], ['--include-bundle', 'com.voicelayer.voicebar.uie2e', '--include-executable', executable])
        source = MODULE.with_name('voicebar-ui-e2e-capture.swift').read_text()
        self.assertNotIn('excludingWindows', source, 'a display-wide filter composites the private desktop')
        self.assertIn('$0.bundleIdentifier == bundle && path($0.processID) == executable', source)
        self.assertEqual(runner.run_suite(self.output, [sys.executable, '-c', 'pass'], self.recorder()), 0)
        info = json.loads((self.output / 'recording.json').read_text())
        self.assertEqual(info['captureSource'], dict(kind='application', bundle='com.voicelayer.voicebar.uie2e',
                                                     executable=executable, observedPids=[4242], fullDisplay=False))
        for marker, reason in [('foreign-source', 'not the QA app'), ('no-source', 'not the QA app'),
                               ('stale-executable', 'not the QA app'), ('no-pids', 'never observed')]:
            with self.subTest(marker=marker):
                (self.root / marker).touch()
                self.assertNotEqual(runner.run_suite(self.output, [sys.executable, '-c', 'pass'], self.recorder()), 0)
                info = json.loads((self.output / 'recording.json').read_text())
                self.assertNotIn('captureSource', info)
                self.assertIn(reason, info['recordingError'])
                (self.root / marker).unlink()

    def test_gatecap1_modal_or_unproven_inventory_refuses_before_hide_others(self):
        for marker in ['modal-visible', 'inventory-error', 'helper-garbage']:
            with self.subTest(marker=marker):
                (self.root / marker).touch()
                (self.root / 'calls').unlink(missing_ok=True)
                (self.output / 'foreign-modal-stop.json').unlink(missing_ok=True)
                self.assertNotEqual(runner.run_suite(self.output, [sys.executable, '-c', 'pass'], self.recorder()), 0)
                calls = (self.root / 'calls').read_text()
                self.assertNotIn('voicebar-ui-e2e-visibility ["hide"', calls, 'Hide Others ran over a foreign modal')
                self.assertNotIn('capture [', calls)
                latch = json.loads((self.output / 'foreign-modal-stop.json').read_text())
                self.assertEqual(latch['phase'], 'before-hide-others')
                self.assertNotIn('BrainBar', json.dumps(latch))
                self.assertTrue(latch['modals'] or latch['errors'])
                (self.root / marker).unlink()

    def test_gatecap1_broker_must_be_ready_and_a_latched_stop_aborts_the_run(self):
        (self.root / 'broker-never-ready').touch()
        self.assertNotEqual(runner.run_suite(self.output, [sys.executable, '-c', 'pass'], self.recorder()), 0)
        self.assertIn('never became ready', json.loads((self.output / 'recording.json').read_text())['error'])
        self.assertNotIn('test [', (self.root / 'calls').read_text())
        (self.root / 'broker-never-ready').unlink()
        (self.root / 'broker-latch').touch()
        started = time.monotonic()
        self.assertNotEqual(runner.run_suite(self.output, [sys.executable, '-c', 'import time; time.sleep(20)'], self.recorder()), 0)
        self.assertLess(time.monotonic() - started, 15)
        self.assertIn('STOP latched', json.loads((self.output / 'recording.json').read_text())['error'])
        broker = [l for l in (self.root / 'calls').read_text().splitlines() if '--broker' in l][-1]
        self.assertIn(str(self.output / 'foreign-modal-stop.json'), broker)

    def test_runner_source_uses_supervised_recording_after_build_only_exit(self):
        source = MODULE.with_name('voicebar-ui-e2e.sh').read_text()
        self.assertNotIn('-test-iterations', source)
        self.assertLess(source.index('[[ $build_only == 0 ]] || exit 0'), source.index('voicebar-ui-e2e-supervisor.py'))

    def test_early_recorder_exit_cannot_pass_even_with_a_valid_video(self):
        (self.root / 'early-end').touch()
        self.assertNotEqual(runner.run_suite(self.output, [sys.executable, '-c', 'import time;time.sleep(5)'], self.recorder()), 0)
        info = json.loads((self.output / 'recording.json').read_text())
        self.assertTrue(info['valid'])
        self.assertIn('Recorder', info['error'])

    def test_no_test_launch_when_capture_is_denied(self):
        (self.root / 'denied').touch()
        marker = self.root / 'test-started'
        result = runner.run_suite(self.output, [sys.executable, '-c', f'open({str(marker)!r},"w").close()'], self.recorder())
        self.assertNotEqual(result, 0)
        self.assertFalse(marker.exists())
        self.assertFalse(json.loads((self.output / 'recording.json').read_text())['valid'])

    def test_ffprobe_audio_rejection_fails_the_gate(self):
        (self.root / 'audio').touch()
        self.assertNotEqual(runner.run_suite(self.output, [sys.executable, '-c', 'pass'], self.recorder()), 0)
        self.assertFalse(json.loads((self.output / 'recording.json').read_text())['valid'])

    def test_invalid_ffprobe_media_fails_the_gate(self):
        (self.root / 'invalid-media').touch()
        self.assertNotEqual(runner.run_suite(self.output, [sys.executable, '-c', 'pass'], self.recorder()), 0)
        self.assertFalse(json.loads((self.output / 'recording.json').read_text())['valid'])

    def test_interrupt_stops_only_owned_children_and_flushes_the_video(self):
        self.assert_interrupt(signal.SIGTERM, False)

    def test_process_group_interrupt_cannot_kill_recorder_before_flush(self):
        self.assert_interrupt(signal.SIGINT, True)

    def test_cancellation_during_flush_is_latched_and_media_still_finalizes(self):
        self.assert_cleanup_interrupt('flush', signal.SIGTERM)

    def test_cancellation_during_ffprobe_is_latched_and_probe_still_finishes(self):
        self.assert_cleanup_interrupt('probe', signal.SIGINT)

    def test_sigint_during_flush_is_latched(self):
        self.assert_cleanup_interrupt('flush', signal.SIGINT)

    def test_sigterm_during_ffprobe_is_latched(self):
        self.assert_cleanup_interrupt('probe', signal.SIGTERM)

    def test_process_group_cancel_during_ffprobe_preserves_probe(self):
        self.assert_cleanup_interrupt('probe', signal.SIGINT, whole_group=True)

    def test_process_group_cancel_during_flush_preserves_recorder(self):
        self.assert_cleanup_interrupt('flush', signal.SIGTERM, whole_group=True)

    def test_sighup_from_session_teardown_is_latched_and_cleans_up(self):
        # SUP3: run-03's runner died without publishing a receipt, orphaning xcodebuild.
        self.assert_interrupt(signal.SIGHUP, False)

    def test_supervisor_death_aborts_and_stops_owned_children(self):
        # SUP3: parent-death handling, checked by the authenticated identity.
        marker = self.root / 'test-started'
        authority = dict(pid=4242, birth=(7, 7))
        alive = [4]  # Alive through entry, Hide Others and the boundary broker (GATECAP1); dies once recording runs.
        def birth(pid):
            alive[0] -= 1
            return (7, 7) if pid == 4242 and alive[0] > 0 else None
        started = time.monotonic()
        with unittest.mock.patch.object(runner.os, 'getppid', return_value=4242), \
                unittest.mock.patch.object(runner.safety, 'kernel_birth', side_effect=birth):
            result = runner.run_suite(self.output, [sys.executable, '-c',
                f'import pathlib,time;pathlib.Path({str(marker)!r}).touch();time.sleep(60)'],
                self.recorder(), supervisor=authority)
        self.assertNotEqual(result, 0)
        self.assertLess(time.monotonic() - started, 30)
        info = json.loads((self.output / 'recording.json').read_text())
        self.assertIn('supervisor', info['error'].lower())
        self.assertTrue(info['valid'])  # The recorder is still flushed, never abandoned.
        self.assertFalse(info['runPassed'])
        self.assertTrue(json.loads((self.output / 'visibility.json').read_text())['restored'])

    def test_supervisor_death_after_child_launch_reaps_child_and_fails_receipt(self):
        # CR 4306348751: the child really starts, THEN the supervisor dies mid-run.
        marker = self.root / 'test-started'
        def birth(pid):
            return (7, 7) if pid == 4242 and not marker.exists() else None
        with unittest.mock.patch.object(runner.os, 'getppid', return_value=4242), \
                unittest.mock.patch.object(runner.safety, 'kernel_birth', side_effect=birth):
            result = runner.run_suite(self.output, [sys.executable, '-c',
                f'import os,pathlib,time;pathlib.Path({str(marker)!r}).write_text(str(os.getpid()));time.sleep(60)'],
                self.recorder(), supervisor=dict(pid=4242, birth=(7, 7)))
        self.assertTrue(marker.exists(), 'the child must have launched before the supervisor died')
        with self.assertRaises(ProcessLookupError):  # Stopped AND reaped: no live or zombie PID left.
            os.kill(int(marker.read_text()), 0)
        self.assertNotEqual(result, 0)
        info = json.loads((self.output / 'recording.json').read_text())
        self.assertIn('supervisor', info['error'].lower())
        self.assertIsNotNone(info['testExit'])
        self.assertTrue(info['valid'])  # Media still finalizes after the supervisor is gone.
        self.assertFalse(info['runPassed'])
        self.assertTrue(json.loads((self.output / 'visibility.json').read_text())['restored'])

    def test_supervisor_lost_after_final_loop_check_never_publishes_pass(self):
        # CR 4306348758: alive for every loop check, dead by the time cleanup publishes.
        lost = []
        recording = self.recorder()
        stop = recording.stop
        def stop_then_lose_supervisor():
            lost.append(True)  # Dies without a caught signal while media flushes.
            return stop()
        recording.stop = stop_then_lose_supervisor
        def birth(pid): return (7, 7) if pid == 4242 and not lost else None
        printed = io.StringIO()
        with unittest.mock.patch.object(runner.os, 'getppid', return_value=4242), \
                unittest.mock.patch.object(runner.safety, 'kernel_birth', side_effect=birth), \
                contextlib.redirect_stdout(printed):
            result = runner.run_suite(self.output, [sys.executable, '-c', 'pass'], recording,
                                      supervisor=dict(pid=4242, birth=(7, 7)))
        self.assertNotEqual(result, 0)
        info = json.loads((self.output / 'recording.json').read_text())
        self.assertEqual(info['testExit'], 0)
        self.assertTrue(info['valid'])
        self.assertFalse(info['runPassed'])
        self.assertEqual(info['failReason'], 'supervisor-lost')
        self.assertIn('supervisor-lost', (self.output / 'recording.html').read_text())
        self.assertNotIn('PASS', printed.getvalue())
        self.assertIn('FAIL recording:', printed.getvalue())

    def test_supervisor_replaced_by_same_pid_before_publish_never_passes(self):
        # Same PID, different microsecond birth: a recycled PID is not the authenticated supervisor.
        recording = self.recorder()
        stop = recording.stop
        births = [(7, 7)]
        def stop_then_replace():
            births[0] = (7, 8)
            return stop()
        recording.stop = stop_then_replace
        with unittest.mock.patch.object(runner.os, 'getppid', return_value=4242), \
                unittest.mock.patch.object(runner.safety, 'kernel_birth', side_effect=lambda pid: births[0]), \
                contextlib.redirect_stdout(io.StringIO()):
            result = runner.run_suite(self.output, [sys.executable, '-c', 'pass'], recording,
                                      supervisor=dict(pid=4242, birth=(7, 7)))
        self.assertNotEqual(result, 0)
        info = json.loads((self.output / 'recording.json').read_text())
        self.assertFalse(info['runPassed'])
        self.assertEqual(info['failReason'], 'supervisor-lost')

    def test_live_authenticated_supervisor_at_publish_still_passes(self):
        printed = io.StringIO()
        with unittest.mock.patch.object(runner.os, 'getppid', return_value=4242), \
                unittest.mock.patch.object(runner.safety, 'kernel_birth', return_value=(7, 7)), \
                contextlib.redirect_stdout(printed):
            result = runner.run_suite(self.output, [sys.executable, '-c', 'pass'], self.recorder(),
                                      supervisor=dict(pid=4242, birth=(7, 7)))
        self.assertEqual(result, 0)
        info = json.loads((self.output / 'recording.json').read_text())
        self.assertTrue(info['runPassed'])
        self.assertNotIn('failReason', info)
        self.assertIn('PASS recording:', printed.getvalue())

    def publish_with(self, on_write, kernel=None, supervisor=dict(pid=4242, birth=(7, 7))):
        """Run a passing suite; on_write(path, nth) fires after each receipt write (nth per receipt name)."""
        lost = []
        counts = {}
        real_write = pathlib.Path.write_text
        def write_text(path, *args, **kwargs):
            result = real_write(path, *args, **kwargs)
            for name in ['recording.json', 'recording.html']:
                if name in path.name and path.parent == self.output:
                    counts[name] = counts.get(name, 0) + 1
                    on_write(name, counts[name], lost)
            return result
        def birth(pid): return (7, 7) if pid == 4242 and not lost else None
        printed = io.StringIO()
        with unittest.mock.patch.object(runner.os, 'getppid', return_value=4242), \
                unittest.mock.patch.object(runner.safety, 'kernel_birth', side_effect=kernel or birth), \
                unittest.mock.patch.object(pathlib.Path, 'write_text', autospec=True, side_effect=write_text), \
                contextlib.redirect_stdout(printed):
            result = runner.run_suite(self.output, [sys.executable, '-c', 'pass'], self.recorder(), supervisor=supervisor)
        info = json.loads((self.output / 'recording.json').read_text())
        return result, info, printed.getvalue()

    def assert_supervisor_lost_receipt(self, result, info, printed, reason='supervisor-lost'):
        self.assertNotEqual(result, 0)
        self.assertFalse(info['runPassed'])
        self.assertEqual(info['failReason'], reason)
        self.assertTrue(info['valid'])  # Media finalized regardless.
        self.assertNotIn('PASS', printed)
        page = html.unescape((self.output / 'recording.html').read_text())
        self.assertIn(reason, page)
        self.assertIn('"runPassed": false', page)
        self.assertEqual([p.name for p in self.output.glob('.recording*')], [])  # No staged PASS left behind.

    def test_supervisor_death_during_html_receipt_write_never_passes(self):
        # Sol R1 reproduction: alive through cleanup and the first check, dead while recording.html is written.
        def die(name, nth, lost):
            if name == 'recording.html': lost.append(True)
        self.assert_supervisor_lost_receipt(*self.publish_with(die))

    def test_supervisor_death_during_json_receipt_write_never_passes(self):
        def die(name, nth, lost):
            if name == 'recording.json' and nth == 2: lost.append(True)  # nth 1 is run_suite's opening receipt.
        self.assert_supervisor_lost_receipt(*self.publish_with(die))

    def test_supervisor_death_after_promotion_demotes_before_console_and_exit(self):
        # Lost during the post-rename HTML render: finalization revalidates, so no PASS line and exit 1.
        writes = []
        def die(name, nth, lost):
            writes.append(name)
            if name == 'recording.html' and nth == 2: lost.append(True)
        result, info, printed = self.publish_with(die)
        self.assertIn('recording.html', writes)
        self.assert_supervisor_lost_receipt(result, info, printed)

    def test_publication_failure_after_promotion_demotes_the_passing_receipt(self):
        def fail(name, nth, lost):
            if name == 'recording.html' and nth == 2: raise OSError('disk full')
        result, info, printed = self.publish_with(fail)
        self.assertNotEqual(result, 0)
        self.assertFalse(info['runPassed'])
        self.assertEqual(info['failReason'], 'publication-failed')
        self.assertIn('disk full', info['publicationError'])
        self.assertNotIn('PASS', printed)

    def test_broken_console_pass_line_demotes_the_receipt(self):
        with unittest.mock.patch('builtins.print', side_effect=BrokenPipeError('stdout closed')):
            result, info, printed = self.publish_with(lambda *a: None)
        self.assertEqual(result, 1)
        self.assertFalse(info['runPassed'])
        self.assertEqual(info['failReason'], 'publication-failed')

    def test_signal_during_receipt_publication_never_leaves_pass(self):
        def interrupt(name, nth, lost):
            if name == 'recording.html' and nth == 2: signal.raise_signal(signal.SIGTERM)
        result, info, printed = self.publish_with(interrupt)
        self.assertEqual(result, 128 + signal.SIGTERM)
        self.assertFalse(info['runPassed'])
        self.assertIn(int(signal.SIGTERM), info['cancelledSignals'])
        self.assertNotIn('PASS', printed)

    def test_no_io_between_final_supervisor_check_and_pass_promotion(self):
        trace = []
        real_replace, real_write = os.replace, pathlib.Path.write_text
        def replace(src, dst):
            trace.append(('replace', pathlib.Path(dst).name)); return real_replace(src, dst)
        def write_text(path, *args, **kwargs):
            trace.append(('write', path.name)); return real_write(path, *args, **kwargs)
        def birth(pid):
            trace.append(('check', pid)); return (7, 7)
        with unittest.mock.patch.object(runner.os, 'getppid', return_value=4242), \
                unittest.mock.patch.object(runner.safety, 'kernel_birth', side_effect=birth), \
                unittest.mock.patch.object(runner.os, 'replace', side_effect=replace), \
                unittest.mock.patch.object(pathlib.Path, 'write_text', autospec=True, side_effect=write_text), \
                contextlib.redirect_stdout(io.StringIO()):
            result = runner.run_suite(self.output, [sys.executable, '-c', 'pass'], self.recorder(),
                                      supervisor=dict(pid=4242, birth=(7, 7)))
        self.assertEqual(result, 0)
        promotion = trace.index(('replace', 'recording.json'), trace.index(('write', '.recording.json.pass-staged')))
        self.assertEqual(trace[promotion - 1], ('check', 4242))  # The check is the last act before the rename.
        before = trace[:promotion]
        self.assertIn(('write', '.recording.html.tmp'), before)  # FAIL/pending receipts already on disk.
        self.assertTrue(json.loads((self.output / 'recording.json').read_text())['runPassed'])

    def test_receipts_are_pending_fail_before_the_final_check(self):
        seen = {}
        def snapshot(pid):
            if pid == 4242 and (self.output / '.recording.json.pass-staged').exists():
                seen['json'] = json.loads((self.output / 'recording.json').read_text())
                seen['html'] = html.unescape((self.output / 'recording.html').read_text())
            return (7, 7)
        result, info, printed = self.publish_with(lambda *a: None, kernel=snapshot)
        self.assertEqual(result, 0)
        self.assertFalse(seen['json']['runPassed'])
        self.assertEqual(seen['json']['failReason'], 'pending-final-supervisor-check')
        self.assertNotIn('"runPassed": true', seen['html'])
        self.assertTrue(info['runPassed'])
        self.assertNotIn('failReason', info)
        self.assertIn('PASS recording:', printed)
        self.assertIn('"runPassed": true', html.unescape((self.output / 'recording.html').read_text()))

    def test_supervisor_death_before_suite_entry_never_launches(self):
        # Sol R5: validated supervisor 4242 died; launchd (1) is now the parent. Never adopt it.
        marker = self.root / 'test-started'
        with unittest.mock.patch.object(runner.os, 'getppid', return_value=1), \
                unittest.mock.patch.object(runner.safety, 'kernel_birth', return_value=None):
            result = runner.run_suite(self.output, [sys.executable, '-c',
                f'import pathlib;pathlib.Path({str(marker)!r}).touch()'],
                self.recorder(), supervisor=dict(pid=4242, birth=(7, 7)))
        self.assertNotEqual(result, 0)
        self.assertFalse(marker.exists())
        self.assertFalse((self.root / 'calls').exists() and 'capture [' in (self.root / 'calls').read_text())
        info = json.loads((self.output / 'recording.json').read_text())
        self.assertIn('supervisor', info['error'].lower())

    def test_every_owned_launch_is_registered_before_exec(self):
        registry = self.output / 'owned-registrations.jsonl'
        result = runner.run_suite(self.output, [sys.executable, '-c', 'pass'], self.recorder(),
                                  registry=(registry, 'fixture-token'))
        self.assertEqual(result, 0)
        rows = [json.loads(line) for line in registry.read_text().splitlines() if line]  # Blank lines are framing.
        kinds = [row['kind'] for row in rows]
        for kind in ['visibility', 'recorder', 'test', 'ffprobe']:
            self.assertIn(kind, kinds)
        digest = runner.safety.token_digest('fixture-token')
        self.assertTrue(all(row['token'] == digest and row['pid'] > 1 and len(row['birth']) == 2 for row in rows))

    def test_failed_or_short_registration_never_execs_the_child(self):
        # SUP3.1 (Sol N6): the preexec acknowledgement is the full verified record or no launch.
        marker = self.root / 'executed'
        code = 'import pathlib; pathlib.Path(%r).touch()' % str(marker)
        real_write = os.write
        cases = [(self.root / 'missing-dir' / 'registry.jsonl', None),
                 (self.output / 'short-registry.jsonl', lambda fd, data: real_write(fd, data[:12]))]
        for registry, write in cases:
            runner.REGISTRATION[:] = [(registry, 'fixture-token')]
            try:
                with unittest.mock.patch.object(runner.safety.os, 'write', side_effect=write or real_write):
                    with self.assertRaises(subprocess.SubprocessError):
                        subprocess.run([sys.executable, '-c', code], **runner.owned_launch('test'))
            finally:
                runner.REGISTRATION.clear()
            self.assertFalse(marker.exists(), registry)

    def assert_cleanup_interrupt(self, phase, sig, whole_group=False):
        (self.root / ('delay-' + phase)).touch()
        process = self.supervisor('pass')
        try:
            deadline = time.monotonic() + 10
            while not (self.root / (phase + '-waiting')).exists() and process.poll() is None and time.monotonic() < deadline:
                time.sleep(.02)
            self.assertTrue((self.root / (phase + '-waiting')).exists())
            for _ in range(2):  # Repeated cancellation must not abort cleanup.
                if whole_group: os.killpg(process.pid, sig)
                else: process.send_signal(sig)
            (self.root / 'release').touch()
            output = process.communicate(timeout=10)[0].decode()
            self.assertNotEqual(process.returncode, 0, output)
            info = json.loads((self.output / 'recording.json').read_text())
            self.assertTrue(info['valid'], output)
            self.assertEqual(info['testExit'], 0)
            self.assertIn('interrupted', info['error'].lower())
            self.assertFalse(info['runPassed'])
            self.assertIn(int(sig), info['cancelledSignals'])
            self.assertIn('interrupted', (self.output / 'recording.html').read_text().lower())
            self.assertNotIn('PASS recording:', output)
            self.assertIn('ffprobe [', (self.root / 'calls').read_text())
            self.assertTrue(json.loads((self.output / 'visibility.json').read_text())['restored'])
        finally:
            (self.root / 'release').touch()
            if process.poll() is None: process.kill(); process.wait()

    def supervisor(self, test_code):
        code = (f'import importlib.util,pathlib,sys;'
                f's=importlib.util.spec_from_file_location("runner",{str(MODULE)!r});'
                'm=importlib.util.module_from_spec(s);s.loader.exec_module(m);'
                f'o=pathlib.Path({str(self.output)!r});'
                f'r=m.Recording(o,{str(self.root / "capture")!r},{str(self.root / "ffprobe")!r});'
                f'sys.exit(m.run_suite(o,[sys.executable,"-c",{test_code!r}],r))')
        return subprocess.Popen([sys.executable, '-c', code], stdout=subprocess.PIPE,
                                stderr=subprocess.STDOUT, start_new_session=True)

    def assert_interrupt(self, sig, whole_group):
        marker = self.root / 'test-started'
        process = self.supervisor(f'import pathlib,time;pathlib.Path({str(marker)!r}).touch();time.sleep(60)')
        try:
            deadline = time.monotonic() + 10
            while not marker.exists() and process.poll() is None and time.monotonic() < deadline: time.sleep(.02)
            self.assertTrue(marker.exists())
            if whole_group: os.killpg(process.pid, sig)
            else: process.send_signal(sig)
            output = process.communicate(timeout=10)[0].decode()
            self.assertNotEqual(process.returncode, 0, output)
            info = json.loads((self.output / 'recording.json').read_text())
            self.assertTrue(info['valid'], output)
            self.assertEqual(info['durationSeconds'], 1.25)
            self.assertTrue(json.loads((self.output / 'visibility.json').read_text())['restored'])
        finally:
            if process.poll() is None: process.kill(); process.wait()


if __name__ == '__main__':
    unittest.main()
