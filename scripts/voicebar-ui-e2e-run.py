#!/usr/bin/env python3
"""One serial UI run, always recorded; imported unit tests use recorder stubs only."""
import argparse
import datetime
import html
import json
import math
import os
import pathlib
import plistlib
import re
import signal
import subprocess
import sys
import time
import importlib.util


_spec = importlib.util.spec_from_file_location('safety_supervisor', pathlib.Path(__file__).with_name('voicebar-ui-e2e-supervisor.py'))
safety = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(safety)
# (registry path, supervisor token) while run_suite registers its launches; None otherwise.
REGISTRATION = []


def owned_launch(kind):
    """Popen kwargs that register the child (PID + kernel birth) with the supervisor before exec."""
    if not REGISTRATION:
        return {}
    registry, token = REGISTRATION[0]
    def register():  # Runs in the forked child; a failure aborts the launch (fail closed).
        safety.register_owned(registry, token, kind, os.getpid(), safety.kernel_birth(os.getpid()))
    return dict(preexec_fn=register)


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
                                text=True, timeout=10, start_new_session=True, **owned_launch('visibility'))
        if result.returncode:
            raise RuntimeError('Hide Others / restore visibility failed: ' + result.stderr.strip())


QA_BUNDLE = 'com.voicelayer.voicebar.uie2e'


def qa_executable(output):
    """This run's QA executable (symlinks resolved, as proc_pidpath reports it)."""
    app = pathlib.Path((output / 'sandbox-path.txt').read_text().strip()) / 'VoiceBarQA.app'
    try:
        name = plistlib.loads((app / 'Contents/Info.plist').read_bytes())['CFBundleExecutable']
    except Exception:
        name = 'VoiceBar'
    return str((app / 'Contents/MacOS' / name).resolve())


def capture_source(progress, executable):
    """The recorder's declared sources: only this run's QA process windows may ever be composited."""
    sources = re.findall(r'^source=application bundle=(\S+) executable=(\S+) pids=([0-9,]*)$', progress, re.MULTILINE)
    if not sources or any(bundle != QA_BUNDLE or path != executable for bundle, path, _ in sources):
        raise RuntimeError('Recorder capture source is not the QA app window set; movie rejected')
    pids = sorted({int(pid) for _, _, group in sources for pid in group.split(',') if pid})
    if not pids:
        raise RuntimeError('Recorder never observed the proven QA process; movie is not QA evidence')
    return dict(kind='application', bundle=QA_BUNDLE, executable=executable, observedPids=pids, fullDisplay=False)


def write_latch(output, record):
    """Latch a foreign-modal STOP for the supervisor (exit 2). First writer wins; entries redacted."""
    try:
        with (output / safety.FOREIGN_MODAL_LATCH).open('x') as file:
            json.dump(record, file)
    except FileExistsError:
        pass


def modal_gate(output):
    """Fresh synchronous modal decision before Hide Others mutates any app's visibility (R2)."""
    helper = output / 'voicebar-ui-e2e-permissions'
    try:
        result = subprocess.run([str(helper)], capture_output=True, text=True, timeout=15, start_new_session=True,
                                **owned_launch('modal-gate'))
        parsed = json.loads(result.stdout)
        entries = safety.modal_receipt(parsed)
    except Exception as error:
        entries = getattr(error, 'modals', None) or [dict(owner='unknown', source='not-proven',
                                                          title=safety.redacted(''), reason='modal-gate-unreadable')]
    if entries:
        write_latch(output, dict(status='stop', phase='before-hide-others',
                                 modals=[e for e in entries if e['source'] != 'not-proven'],
                                 errors=[e for e in entries if e['source'] == 'not-proven']))
        raise InterruptedError('Foreign modal or NOT_PROVEN inventory before Hide Others; STOP latched')


class Boundary:
    """Owned broker answering the runner's per-command/action/still modal checks (R4)."""
    def __init__(self, output):
        self.output = output
        self.sandbox = pathlib.Path((output / 'sandbox-path.txt').read_text().strip())
        self.process = None

    def start(self):
        ready = self.sandbox / 'boundary/ready.json'
        self.process = subprocess.Popen([str(self.output / 'voicebar-ui-e2e-permissions'), '--broker', self.sandbox.name,
                                         str(self.sandbox), qa_executable(self.output), str(self.output / safety.FOREIGN_MODAL_LATCH)],
                                        stdout=subprocess.DEVNULL, stderr=(self.output / 'boundary.log').open('w'),
                                        start_new_session=True, **owned_launch('boundary'))
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            if self.process.poll() is not None:
                raise RuntimeError('Boundary broker exited before UI launch')
            if ready.is_file():
                return
            time.sleep(.05)
        raise RuntimeError('Boundary broker never became ready; no UI launch without per-boundary modal checks')

    def stop(self):
        if self.process is not None and self.process.poll() is None:
            self.process.terminate()  # Our own child handle (never a PID lookup).
            try: self.process.wait(timeout=5)
            except subprocess.TimeoutExpired: self.process.kill(); self.process.wait()


class Recording:
    def __init__(self, output, capture=None, ffprobe='ffprobe'):
        self.output, self.capture, self.ffprobe = output, capture or str(output / 'voicebar-ui-e2e-capture'), ffprobe
        self.executable = qa_executable(output)
        self.path = output / ('run-' + datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%S%fZ') + '.mov')
        self.progress = output / 'recording-progress.log'
        self.process = None
        self.files = []

    def arguments(self):
        # ScreenCaptureKit, QA app windows only; no full-display mode, camera or device-name selection.
        return [self.capture, '--include-bundle', QA_BUNDLE, '--include-executable', self.executable, str(self.path)]

    def start(self):
        for tool, option in [(self.capture, '--version'), (self.ffprobe, '-version')]:
            subprocess.run([tool, option], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, timeout=5,
                           **owned_launch('tool-check'))
        self.files = [self.progress.open('w'), (self.output / 'recording.log').open('w')]
        # A stop of xcodebuild's process group must not terminate the recorder mid-flush.
        self.process = subprocess.Popen(self.arguments(), stdin=subprocess.PIPE, text=True,
                                        stdout=self.files[0], stderr=self.files[1], start_new_session=True,
                                        **owned_launch('recorder'))
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
            capture_output=True, text=True, timeout=10, start_new_session=True, **owned_launch('ffprobe'))
        (self.output / 'recording-ffprobe.json').write_text(result.stdout)
        (self.output / 'recording-ffprobe.log').write_text(result.stderr)
        result.check_returncode()
        data = json.loads(result.stdout)
        duration = float(data['format']['duration'])
        streams = [stream['codec_type'] for stream in data['streams']]
        size = self.path.stat().st_size
        if not math.isfinite(duration) or duration <= 0 or size <= 0 or 'video' not in streams or 'audio' in streams:
            raise RuntimeError('ffprobe requires nonempty video, positive duration and zero audio streams')
        return dict(durationSeconds=duration, bytes=size, valid=True, captureSource=capture_source(self.progress.read_text(), self.executable))


def stop_test(process):
    if process is not None and process.poll() is None:
        try: os.killpg(process.pid, signal.SIGINT)
        except ProcessLookupError: return
        try: process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL); process.wait()


def atomic_write(path, text):
    staged = path.with_name('.' + path.name + '.tmp')
    staged.write_text(text)
    os.replace(staged, path)


def receipt_html(info):
    return ('<!doctype html><meta charset="utf-8"><title>UIE2E recording</title>'
            '<h1>UIE2E recording receipt</h1><a href="' + html.escape(info['path'], quote=True) +
            '">Screen recording (.mov)</a><pre>' + html.escape(json.dumps(info, indent=2)) + '</pre>')


def run_suite(output, arguments=None, recording=None, supervisor=None, registry=None, boundary=None):
    recording = recording or Recording(output)
    boundary = boundary or Boundary(output)
    visibility = Visibility(output)
    info = dict(path=recording.path.name, valid=False)
    atomic_write(output / 'recording.json', json.dumps(info, indent=2) + '\n')
    test = None
    status = 1
    # SIGHUP too: a torn-down operator session must not kill the runner before it stops its children.
    previous = {sig: signal.getsignal(sig) for sig in [signal.SIGINT, signal.SIGTERM, signal.SIGHUP]}
    cancelled = []
    def interrupted(sig, frame):
        # Latch throughout startup, execution AND cleanup. Never interrupt media flush.
        cancelled.append(int(sig))
    def supervisor_alive():
        # The authenticated supervisor identity (PID + kernel birth), never a re-sampled parent:
        # launchd adopting us must not pass as the supervisor.
        try:
            return (os.getppid() == supervisor['pid'] and
                    safety.kernel_birth(supervisor['pid']) == tuple(supervisor['birth']))
        except RuntimeError:
            return False
    def check_cancelled():
        if cancelled: raise InterruptedError('UI run interrupted by signal ' + str(cancelled[0]))
        if supervisor is not None and not supervisor_alive():
            raise InterruptedError('Safety supervisor %d exited; UI run aborted' % supervisor['pid'])
    staged_pass = output / '.recording.json.pass-staged'
    def write_fail(reason=None, detail=None):
        # Every receipt is FAIL/pending on disk before any PASS can exist.
        nonlocal status
        if status == 0: status = 1
        info['cancelledSignals'] = list(cancelled)
        if cancelled:
            info['error'] = 'UI run interrupted by signal ' + str(cancelled[0])
            reason = reason if reason in ('supervisor-lost', 'publication-failed') else 'interrupted'
        if reason: info['failReason'] = reason
        if detail: info.setdefault('error', detail)
        info['runPassed'] = False
        atomic_write(output / 'recording.json', json.dumps(info, indent=2) + '\n')
        atomic_write(output / 'recording.html', receipt_html(info))
    def lost():
        return supervisor is not None and not supervisor_alive()
    def lost_detail():
        return 'Safety supervisor %d lost before PASS publication (supervisor-lost)' % supervisor['pid']
    def publish():
        """FAIL/pending receipts first, then ONE rename promotes a pre-written PASS. Returns promoted."""
        nonlocal status
        candidate = status == 0 and not cancelled
        info['cancelledSignals'] = list(cancelled)
        if not candidate:
            write_fail()
            return False
        info['runPassed'] = False
        info['failReason'] = 'pending-final-supervisor-check'
        atomic_write(output / 'recording.json', json.dumps(info, indent=2) + '\n')
        atomic_write(output / 'recording.html', receipt_html(info))
        passing = {key: value for key, value in info.items() if key != 'failReason'}
        passing['runPassed'] = True
        staged_pass.write_text(json.dumps(passing, indent=2) + '\n')
        # FINAL BOUNDARY: the authenticated-supervisor check is the last act; the rename follows with
        # no other I/O. The cleanup's finalization step re-samples once more before the PASS line and
        # exit code (demote-only). RESIDUAL, documented: the supervisor can still die in the few
        # instructions after that last sample (before rename(2) here, or before print/return there);
        # macOS gives no pidfd/process handle, so a death past the final sample is undetectable.
        if cancelled or lost():
            staged_pass.unlink(missing_ok=True)
            if cancelled: write_fail()
            else: write_fail('supervisor-lost', lost_detail())
            return False
        os.replace(staged_pass, output / 'recording.json')
        info.clear(); info.update(passing)
        return True
    for sig in previous: signal.signal(sig, interrupted)
    if registry is not None: REGISTRATION[:] = [registry]
    try:
        check_cancelled()  # Revalidate the supervisor before any launch.
        modal_gate(output)  # Any visible foreign modal refuses before Hide Others touches other apps.
        visibility.call('hide')
        check_cancelled()
        boundary.start()
        check_cancelled()
        recording.start()  # No test may launch until real frames reach the output file.
        check_cancelled()
        with (output / 'test.log').open('w') as log:
            test = subprocess.Popen(arguments or test_arguments(output), stdout=log,
                                    stderr=subprocess.STDOUT, start_new_session=True, **owned_launch('test'))
            while test.poll() is None:
                check_cancelled()
                if recording.process.poll() is not None:
                    raise RuntimeError('Recorder stopped during UI execution; gate aborted')
                if boundary.process.poll() is not None:
                    raise RuntimeError('Boundary broker stopped during UI execution; gate aborted')
                if (output / safety.FOREIGN_MODAL_LATCH).exists():
                    raise InterruptedError('Foreign modal STOP latched; UI run aborted')
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
            try: boundary.stop()
            except Exception as error: info['boundaryCleanupError'] = str(error); status = 1
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
            promoted = publish()
            if promoted:
                try:
                    atomic_write(output / 'recording.html', receipt_html(info))  # The human view follows the JSON.
                except Exception as error:
                    info['publicationError'] = str(error)
                    write_fail('publication-failed', 'Receipt publication failed after promotion')
                    promoted = False
        finally:
            try:
                # Finalization re-samples: a cancellation or supervisor loss after promotion demotes,
                # so the PASS line and exit code never reuse the pre-rename liveness decision.
                if info.get('runPassed') is True and (cancelled or lost()):
                    if cancelled: write_fail()
                    else: write_fail('supervisor-lost', lost_detail())
                elif cancelled and info.get('runPassed') is not False:
                    write_fail()
            finally:
                for sig, handler in previous.items(): signal.signal(sig, handler)
                REGISTRATION.clear()
    # Console line and exit code come from the receipt that is actually on disk, after promotion.
    passed = info.get('runPassed') is True and info['valid'] and not cancelled
    try:
        print(f"{'PASS' if passed else 'FAIL'} recording: {output / info['path']} "
              f"duration={info.get('durationSeconds', 'N/A')}s bytes={info.get('bytes', 0)}", flush=True)
    except Exception as error:
        if not passed: raise
        info['publicationError'] = str(error)
        write_fail('publication-failed', 'Console PASS line could not be written')
        passed = False
    if cancelled: return 128 + cancelled[0]
    return 0 if passed else (status or 1)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('output', type=pathlib.Path)
    parser.add_argument('--scenario', choices=SCENARIOS)
    args = parser.parse_args()
    output = args.output.resolve()
    authority = safety.require_supervisor(output, os.environ)
    # Refuse BEFORE visibility/capture/UI unless the exact built guard passed its probes,
    # for every scenario or build that constructs the real AppDelegate fixture.
    spec = importlib.util.spec_from_file_location('device_guard', pathlib.Path(__file__).with_name('voicebar-ui-e2e-guard-proof.py'))
    guard = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(guard)
    sandbox = pathlib.Path((output / 'sandbox-path.txt').read_text().strip())
    guard.authorize(pathlib.Path(__file__).resolve().parent.parent, output, selected_scenario(output, args.scenario),
                    sandbox / 'VoiceBarQA.app/Contents/Info.plist')
    # Validate selection before changing visibility or starting the recorder.
    sys.exit(run_suite(output, test_arguments(output, args.scenario), supervisor=authority,
                       registry=(output / 'owned-registrations.jsonl', os.environ['VOICEBAR_UIE2E_SUPERVISOR_TOKEN'])))
