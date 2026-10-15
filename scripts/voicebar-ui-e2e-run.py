#!/usr/bin/env python3
"""One serial UI run, always recorded; imported unit tests use recorder stubs only."""
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


def test_arguments(output):
    return ['xcodebuild', 'test-without-building', '-xctestrun', str(output / 'UIE2E.xctestrun'),
            '-destination', 'platform=macOS', '-parallel-testing-enabled', 'NO',
            '-resultBundlePath', str(output / 'VoiceBar.xcresult')]


class Recording:
    def __init__(self, output, ffmpeg='ffmpeg', ffprobe='ffprobe'):
        self.output, self.ffmpeg, self.ffprobe = output, ffmpeg, ffprobe
        self.path = output / ('run-' + datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%S%fZ') + '.mov')
        self.progress = output / 'recording-progress.log'
        self.process = None
        self.files = []

    def arguments(self):
        # Named screen only, no default device/camera fallback; :none never opens audio.
        # Fragment metadata travels with its packets rather than waiting for a final moov.
        return [self.ffmpeg, '-hide_banner', '-loglevel', 'warning', '-n', '-stdin',
                '-f', 'avfoundation', '-framerate', '15', '-capture_cursor', '1',
                '-i', 'Capture screen 0:none', '-an', '-c:v', 'libx264', '-preset', 'ultrafast',
                '-crf', '24', '-vf', 'scale=trunc(iw/2)*2:trunc(ih/2)*2', '-pix_fmt', 'yuv420p',
                '-g', '15', '-movflags', 'frag_keyframe+empty_moov+default_base_moof',
                '-frag_duration', '1000000', '-flush_packets', '1', '-progress', 'pipe:1', str(self.path)]

    def start(self):
        for tool in [self.ffmpeg, self.ffprobe]:
            subprocess.run([tool, '-version'], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, timeout=5)
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
            capture_output=True, text=True, timeout=10)
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


def run_suite(output, arguments=None, recording=None):
    recording = recording or Recording(output)
    info = dict(path=recording.path.name, valid=False)
    (output / 'recording.json').write_text(json.dumps(info, indent=2) + '\n')
    test = None
    status = 1
    previous = {sig: signal.getsignal(sig) for sig in [signal.SIGINT, signal.SIGTERM]}
    def interrupted(sig, frame):
        raise InterruptedError('UI run interrupted by signal ' + str(sig))
    for sig in previous: signal.signal(sig, interrupted)
    try:
        recording.start()  # No test may launch until real frames reach the output file.
        with (output / 'test.log').open('w') as log:
            test = subprocess.Popen(arguments or test_arguments(output), stdout=log,
                                    stderr=subprocess.STDOUT, start_new_session=True)
            while test.poll() is None:
                if recording.process.poll() is not None:
                    raise RuntimeError('Recorder stopped during UI execution; gate aborted')
                time.sleep(.05)
            if recording.process.poll() is not None:
                raise RuntimeError('Recorder ended before test completion; gate aborted')
            status = test.returncode
    except Exception as error:
        info['error'] = str(error)
    finally:
        # Repeated cancellation cannot interrupt trailer flush / ffprobe / report writing.
        for sig in previous: signal.signal(sig, signal.SIG_IGN)
        try:
            try: stop_test(test)
            except Exception as error: info['testCleanupError'] = str(error); status = 1
            try:
                info.update(recording.stop())
            except Exception as error:
                info['recordingError'] = str(error)
                status = 1
            info['testExit'] = test.returncode if test is not None else None
            (output / 'recording.json').write_text(json.dumps(info, indent=2) + '\n')
            caption = html.escape(json.dumps(info, indent=2))
            (output / 'recording.html').write_text('<!doctype html><meta charset="utf-8"><title>UIE2E recording</title>'
                '<h1>UIE2E recording receipt</h1><a href="' + html.escape(info['path'], quote=True) +
                '">Screen recording (.mov)</a><pre>' + caption + '</pre>')
            print(f"{'PASS' if info['valid'] else 'FAIL'} recording: {output / info['path']} "
                  f"duration={info.get('durationSeconds', 'N/A')}s bytes={info.get('bytes', 0)}", flush=True)
        finally:
            for sig, handler in previous.items(): signal.signal(sig, handler)
    return status


if __name__ == '__main__':
    sys.exit(run_suite(pathlib.Path(sys.argv[1]).resolve()))
