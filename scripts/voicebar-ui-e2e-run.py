#!/usr/bin/env python3
"""One serial UI run, always recorded; imported unit tests use recorder stubs only."""
import argparse
import datetime
import html
import json
import math
import os
import pathlib
import re
import signal
import subprocess
import sys
import time


SCENARIOS = {'full': 'testFullUIOnlyFlow', 'focused-338': 'testFocused338StateGallery', 'hide1': 'testHide1VisualFlow', 'gate2246': 'testGate2246Flow'}


def selected_scenario(output, scenario=None):
    path = output / 'scenario.json'
    recorded = json.loads(path.read_text())['scenario'] if path.exists() else None
    chosen = scenario if scenario is not None else recorded if recorded is not None else 'full'
    if chosen not in SCENARIOS or (recorded is not None and recorded != chosen):
        raise ValueError('Invalid or conflicting UIE2E scenario: ' + str(chosen))
    return chosen


def test_arguments(output, scenario=None):
    scenario = selected_scenario(output, scenario)
    return ['xcodebuild', 'test-without-building', '-xctestrun', str(output / 'UIE2E.xctestrun'),
            '-destination', 'platform=macOS', '-parallel-testing-enabled', 'NO',
            '-only-testing:VoiceBarUIE2ETests/VoiceBarFlowTests/' + SCENARIOS[scenario],
            '-resultBundlePath', str(output / 'VoiceBar.xcresult')]


class Visibility:
    def __init__(self, output):
        self.helper = output / 'voicebar-ui-e2e-visibility'
        self.receipt = output / 'visibility.json'

    def call(self, mode):
        result = subprocess.run([str(self.helper), mode, str(self.receipt)], capture_output=True,
                                text=True, timeout=10, start_new_session=True)
        if result.returncode:
            raise RuntimeError('Hide Others / restore visibility failed: ' + result.stderr.strip())


class Recording:
    def __init__(self, output, capture=None, ffprobe='ffprobe'):
        self.output, self.capture, self.ffprobe = output, capture or str(output / 'voicebar-ui-e2e-capture'), ffprobe
        self.path = output / ('run-' + datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%S%fZ') + '.mov')
        self.progress = output / 'recording-progress.log'
        self.process = None
        self.files = []

    def arguments(self):
        # Typed ScreenCaptureKit display input; no camera/device-name selection API.
        return [self.capture, str(self.path)]

    def start(self):
        for tool, option in [(self.capture, '--version'), (self.ffprobe, '-version')]:
            subprocess.run([tool, option], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, timeout=5)
        self.files = [self.progress.open('w'), (self.output / 'recording.log').open('w')]
        # A stop of xcodebuild's process group must not terminate the recorder mid-flush.
        self.process = subprocess.Popen(self.arguments(), stdin=subprocess.PIPE, text=True,
                                        stdout=self.files[0], stderr=self.files[1], start_new_session=True)
        deadline = time.monotonic() + 20
        while time.monotonic() < deadline:
            if self.process.poll() is not None:
                raise RuntimeError('Recorder exited before UI launch; inspect recording.log/permission prompt')
            frames = re.findall(r'^frame=\s*(\d+)', self.progress.read_text(), re.MULTILINE)
            if frames and int(frames[-1]) > 0 and self.path.is_file() and self.path.stat().st_size > 0:
                return
            time.sleep(.05)
        raise RuntimeError('Recorder produced no frames; stop for screen-recording permission, never grant automatically')

    def stop(self):
        forced = False
        try:
            if self.process is not None:
                if self.process.poll() is None:
                    try:
                        self.process.stdin.write('q\n'); self.process.stdin.flush()
                    except BrokenPipeError:
                        pass
                    try:
                        self.process.wait(timeout=10)
                    except subprocess.TimeoutExpired:
                        forced = True
                        self.process.send_signal(signal.SIGINT)
                        try: self.process.wait(timeout=5)
                        except subprocess.TimeoutExpired: self.process.kill(); self.process.wait()
                if forced or self.process.returncode != 0:
                    raise RuntimeError('Recorder did not finish cleanly; fragments retained for recovery')
            else:
                raise RuntimeError('Recording never started')
        finally:
            if self.process is not None and self.process.stdin is not None: self.process.stdin.close()
            for file in self.files: file.close()
        result = subprocess.run([self.ffprobe, '-v', 'error', '-show_entries',
            'format=duration:stream=codec_type', '-of', 'json', str(self.path)],
            capture_output=True, text=True, timeout=10, start_new_session=True)
        (self.output / 'recording-ffprobe.json').write_text(result.stdout)
        (self.output / 'recording-ffprobe.log').write_text(result.stderr)
        result.check_returncode()
        data = json.loads(result.stdout)
        duration = float(data['format']['duration'])
        streams = [stream['codec_type'] for stream in data['streams']]
        size = self.path.stat().st_size
        if not math.isfinite(duration) or duration <= 0 or size <= 0 or 'video' not in streams or 'audio' in streams:
            raise RuntimeError('ffprobe requires nonempty video, positive duration and zero audio streams')
        return dict(durationSeconds=duration, bytes=size, valid=True)


def stop_test(process):
    if process is not None and process.poll() is None:
        try: os.killpg(process.pid, signal.SIGINT)
        except ProcessLookupError: return
        try: process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL); process.wait()


def run_suite(output, arguments=None, recording=None, supervisor=None):
    recording = recording or Recording(output)
    visibility = Visibility(output)
    info = dict(path=recording.path.name, valid=False)
    (output / 'recording.json').write_text(json.dumps(info, indent=2) + '\n')
    test = None
    status = 1
    # SIGHUP too: a torn-down operator session must not kill the runner before it stops its children.
    previous = {sig: signal.getsignal(sig) for sig in [signal.SIGINT, signal.SIGTERM, signal.SIGHUP]}
    cancelled = []
    def interrupted(sig, frame):
        # Latch throughout startup, execution AND cleanup. Never interrupt media flush.
        cancelled.append(int(sig))
    def check_cancelled():
        if cancelled: raise InterruptedError('UI run interrupted by signal ' + str(cancelled[0]))
        # Parent-death handling: reparented away from the safety supervisor, stop owned children now.
        if supervisor is not None and os.getppid() != supervisor:
            raise InterruptedError('Safety supervisor %d exited; UI run aborted' % supervisor)
    def publish():
        info['cancelledSignals'] = list(cancelled)
        if cancelled: info['error'] = 'UI run interrupted by signal ' + str(cancelled[0])
        info['runPassed'] = status == 0 and not cancelled
        (output / 'recording.json').write_text(json.dumps(info, indent=2) + '\n')
        caption = html.escape(json.dumps(info, indent=2))
        (output / 'recording.html').write_text('<!doctype html><meta charset="utf-8"><title>UIE2E recording</title>'
            '<h1>UIE2E recording receipt</h1><a href="' + html.escape(info['path'], quote=True) +
            '">Screen recording (.mov)</a><pre>' + caption + '</pre>')
    for sig in previous: signal.signal(sig, interrupted)
    try:
        visibility.call('hide')
        check_cancelled()
        recording.start()  # No test may launch until real frames reach the output file.
        check_cancelled()
        with (output / 'test.log').open('w') as log:
            test = subprocess.Popen(arguments or test_arguments(output), stdout=log,
                                    stderr=subprocess.STDOUT, start_new_session=True)
            while test.poll() is None:
                check_cancelled()
                if recording.process.poll() is not None:
                    raise RuntimeError('Recorder stopped during UI execution; gate aborted')
                time.sleep(.05)
            if recording.process.poll() is not None:
                raise RuntimeError('Recorder ended before test completion; gate aborted')
            status = test.returncode
    except Exception as error:
        info['error'] = str(error)
    finally:
        # Handlers keep latching cancellation while owned children flush / probe.
        try:
            try: stop_test(test)
            except Exception as error: info['testCleanupError'] = str(error); status = 1
            try:
                info.update(recording.stop())
            except Exception as error:
                info['recordingError'] = str(error)
                status = 1
            try:
                visibility.call('restore')
                info['visibilityRestored'] = json.loads(visibility.receipt.read_text())['restored']
                if info['visibilityRestored'] is not True: raise RuntimeError('Visibility restoration unconfirmed')
            except Exception as error:
                info['visibilityError'] = str(error)
                status = 1
            info['testExit'] = test.returncode if test is not None else None
            publish()
            print(f"{'PASS' if info['valid'] and info['runPassed'] else 'FAIL'} recording: {output / info['path']} "
                  f"duration={info.get('durationSeconds', 'N/A')}s bytes={info.get('bytes', 0)}", flush=True)
        finally:
            # Also persist a first cancellation arriving during receipt publication.
            if cancelled and info.get('runPassed') is not False: publish()
            for sig, handler in previous.items(): signal.signal(sig, handler)
    return 128 + cancelled[0] if cancelled else status


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('output', type=pathlib.Path)
    parser.add_argument('--scenario', choices=SCENARIOS)
    args = parser.parse_args()
    output = args.output.resolve()
    import importlib.util
    spec = importlib.util.spec_from_file_location('safety_supervisor', pathlib.Path(__file__).with_name('voicebar-ui-e2e-supervisor.py'))
    safety = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(safety)
    safety.require_supervisor(output, os.environ)
    # Refuse BEFORE visibility/capture/UI unless the exact built guard passed its probes.
    if selected_scenario(output, args.scenario) == 'gate2246':
        import importlib.util
        spec = importlib.util.spec_from_file_location('device_guard', pathlib.Path(__file__).with_name('voicebar-ui-e2e-guard-proof.py'))
        guard = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(guard)
        guard.verify(pathlib.Path(__file__).resolve().parent.parent, output)
        # The lead authorized ONE retry after the seam. Claim it atomically, once.
        with (output / 'native-retry-claimed.json').open('x') as receipt:
            json.dump({'authorizedBy': 'GATE2246B-BRIEF and QA-only seam ruling',
                       'claimedAt': datetime.datetime.now(datetime.timezone.utc).isoformat()}, receipt)
    # Validate selection before changing visibility or starting the recorder.
    sys.exit(run_suite(output, test_arguments(output, args.scenario), supervisor=os.getppid()))
