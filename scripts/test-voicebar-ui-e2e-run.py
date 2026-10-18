#!/usr/bin/env python3
import importlib.util
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
        # SUP3: parent-death handling. A runner reparented away from its supervisor stops its test.
        marker = self.root / 'test-started'
        parents = iter([4242] * 3)
        def getppid(): return next(parents, 1)
        started = time.monotonic()
        with unittest.mock.patch.object(runner.os, 'getppid', side_effect=getppid):
            result = runner.run_suite(self.output, [sys.executable, '-c',
                f'import pathlib,time;pathlib.Path({str(marker)!r}).touch();time.sleep(60)'],
                self.recorder(), supervisor=4242)
        self.assertNotEqual(result, 0)
        self.assertLess(time.monotonic() - started, 30)
        info = json.loads((self.output / 'recording.json').read_text())
        self.assertIn('supervisor', info['error'].lower())
        self.assertTrue(info['valid'])  # The recorder is still flushed, never abandoned.
        self.assertFalse(info['runPassed'])
        self.assertTrue(json.loads((self.output / 'visibility.json').read_text())['restored'])

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
