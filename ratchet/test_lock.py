"""Lock row evidence must fail closed; unit evidence only."""
import importlib.util
import ast
from pathlib import Path
import unittest
import json
import os
import subprocess
import sys
import tempfile
import wave
import shutil
import socket
import threading
import time
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('runner', Path(__file__).with_name('run.py'))
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)


class LockTests(unittest.TestCase):
    def test_row_is_pinned_to_main_before_merge(self):
        self.assertEqual(runner.ROWS['voice-ask-lock-suspends-timeout'],
                         ('a2e25844fd98be78293ff3133122a6df0b0a50c8',
                          '7677d52e5045970485f0dd5c141f8c069f66e9d9'))

    def test_missing_deadline_ack_pcm_or_ending_is_not_a_bug_receipt(self):
        good = dict(lock_ack=True, pcm_seconds=21, pcm_seconds_before_release=21, held_seconds=21,
                    ended_before_release=False, completed=True, ending='stop', ending_ack=True)
        self.assertEqual(runner.lock_violations(good), 0)
        self.assertEqual(runner.lock_violations(dict(good, ended_before_release=True)), 1)
        for key, value in [('lock_ack', False), ('pcm_seconds', 0),
                           ('pcm_seconds_before_release', 14), ('held_seconds', 4),
                           ('completed', False), ('ending_ack', False), ('ending', 'cancel')]:
            with self.subTest(key=key), self.assertRaisesRegex(RuntimeError, 'lock evidence'):
                runner.lock_violations(dict(good, **{key: value}))
        without_silence_phase = dict(good)
        del without_silence_phase['pcm_seconds_before_release']
        with self.assertRaisesRegex(RuntimeError, 'pre-speech silence'):
            runner.lock_violations(without_silence_phase)


class FixtureSetupTests(unittest.TestCase):
    def test_owned_fixture_directories_are_private_under_child_umasks(self):
        child = '''import importlib.util, json, os, sys, tempfile
from pathlib import Path
from unittest.mock import patch
spec = importlib.util.spec_from_file_location('runner', sys.argv[1])
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)
os.umask(int(sys.argv[2], 8))
with tempfile.TemporaryDirectory() as directory:
    run = runner.Run.__new__(runner.Run)
    run.root = Path(directory)
    run.source, run.ref = run.root / 'source', 'synthetic-ref'
    output = run.root / 'setup.log'
    calls = []
    def setup_command(argv, **kwargs):
        if argv == ['git', '-C', str(runner.REPO), 'worktree', 'add', '--detach', '--quiet',
                    str(run.source), run.ref]:
            run.source.mkdir()
            calls.append('git')
        elif argv == ['bun', 'install', '--frozen-lockfile'] and kwargs['cwd'] == run.source:
            calls.append('dependencies')
        else:
            raise AssertionError('unexpected setup command')
    with patch.object(runner.subprocess, 'run', side_effect=setup_command):
        run.setup(output)
    names = ('state', 'tmp', 'recordings', 'bin', 'home')
    print(json.dumps(dict(calls=calls,
        modes={name: (run.root / name).lstat().st_mode & 0o7777 for name in names},
        owned=all((run.root / name).lstat().st_uid == os.getuid() for name in names),
        physical=all((run.root / name).is_dir() and not (run.root / name).is_symlink() for name in names),
        recordings_redirect=run.env['QA_VOICE_RECORDINGS_DIR'] == str(run.root / 'recordings'),
        stub_ready=(run.root / 'bin/whisper-cli').is_file())))
'''
        for mask in ('022', '077'):
            with self.subTest(umask=mask):
                result = subprocess.run([sys.executable, '-c', child,
                                         str(Path(__file__).with_name('run.py')), mask],
                                        env=dict(os.environ), check=True, timeout=5,
                                        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
                evidence = json.loads(result.stdout)
                self.assertEqual(evidence['calls'], ['git', 'dependencies'])
                self.assertEqual(evidence['modes'], {name: 0o700 for name in
                                 ('state', 'tmp', 'recordings', 'bin', 'home')})
                for key in ('owned', 'physical', 'recordings_redirect', 'stub_ready'):
                    self.assertTrue(evidence[key], key)


class ExecutableFixtureTests(unittest.TestCase):
    # At 3 s, the unchanged 10% slack covers 200 ms of pre-signal receipt I/O.
    PACE_OBSERVATION_SECONDS = 3.0

    def test_recorder_keeps_pcm_pace_when_receipt_io_is_slow(self):
        self.assert_recorder_pace()

    def test_recorder_keeps_pcm_pace_with_late_sigterm_during_receipt_write(self):
        self.assert_recorder_pace(late_sigterm=True)

    def test_lagging_283_style_fixture_fails_pcm_pace_assertion(self):
        source = Path(__file__).with_name('fixture-rec.py').read_text()
        loop = next(node for node in ast.walk(ast.parse(source)) if isinstance(node, ast.While))
        # #283 accumulated receipt latency before every fixed 32 ms sleep.
        # Retain the head's corrected terminal clock, so that alone cannot hide drift.
        lines = source.splitlines(keepends=True)
        lines[loop.lineno - 1:loop.end_lineno] = ['''    while not stopping:
        if os.getppid() != parent:
            break
        written = os.write(1, b'\\0' * chunk_bytes)
        emitted += written
        receipt()
        time.sleep(.032)
''']
        with tempfile.TemporaryDirectory() as directory:
            fixture = Path(directory) / 'lagging-fixture.py'
            fixture.write_text(''.join(lines))
            with self.assertRaisesRegex(AssertionError, 'receipt latency must not accumulate into PCM drift'):
                self.assert_recorder_pace(fixture=fixture)

    def assert_recorder_pace(self, fixture=None, late_sigterm=False):
        fixture = str(fixture or Path(__file__).with_name('fixture-rec.py'))
        delayed = '''import json, os, runpy, sys, time
from pathlib import Path
original = Path.write_text
started, injected = None, False
def slow_receipt(self, text, *args, **kwargs):
    global started, injected
    evidence = json.loads(text)
    if started is None:
        started = time.monotonic() - evidence['elapsed_seconds']
    if os.environ['RATCHET_LATE_SIGTERM'] == '1':
        if not injected and not evidence['stopped'] and evidence['elapsed_seconds'] >= float(os.environ['RATCHET_OBSERVATION']):
            injected = True
            now = time.monotonic()
            marker = Path(os.environ['RATCHET_WRITING'])
            temporary = marker.with_suffix('.new')
            original(temporary, json.dumps(dict(clock=now, elapsed=now-started)))
            temporary.replace(marker)
            time.sleep(1.0)
    else:
        time.sleep(.12)
    return original(self, text, *args, **kwargs)
Path.write_text = slow_receipt
runpy.run_path(sys.argv[1], run_name='__main__')
'''
        with tempfile.TemporaryDirectory() as directory:
            receipt, writing = (Path(directory) / name for name in ('rec.json', 'writing'))
            proc = subprocess.Popen([sys.executable, '-c', delayed, fixture],
                                    env=dict(os.environ, RATCHET_REC_RECEIPT=str(receipt),
                                             RATCHET_LATE_SIGTERM=str(int(late_sigterm)),
                                             RATCHET_OBSERVATION=str(self.PACE_OBSERVATION_SECONDS),
                                             RATCHET_WRITING=str(writing)),
                                    stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            audio = bytearray()
            reader = threading.Thread(target=lambda: audio.extend(proc.stdout.read()))
            reader.start()
            try:
                deadline = time.monotonic() + 3
                while not receipt.exists() and time.monotonic() < deadline:
                    time.sleep(.01)
                self.assertTrue(receipt.exists(), 'recorder startup receipt missing')
                if late_sigterm:
                    deadline = time.monotonic() + self.PACE_OBSERVATION_SECONDS + 3
                    while not writing.exists() and time.monotonic() < deadline:
                        time.sleep(.001)
                    self.assertTrue(writing.exists(), 'late-SIGTERM receipt stall was not exercised')
                    stall = json.loads(writing.read_text())
                    time.sleep(max(0, stall['clock'] + .20 - time.monotonic()))
                else:
                    time.sleep(self.PACE_OBSERVATION_SECONDS)
                proc.terminate()
                self.assertEqual(proc.wait(3), 0, proc.stderr.read().decode())
                reader.join(1)
                self.assertFalse(reader.is_alive())
                evidence = json.loads(receipt.read_text())
                self.assertTrue(evidence['stopped'])
                actual_pcm = len(audio) / 32000
                self.assertEqual(audio, b'\0' * len(audio))
                self.assertAlmostEqual(evidence['pcm_seconds'], actual_pcm, places=6)
                if late_sigterm:
                    phase = evidence['elapsed_seconds'] - stall['elapsed']
                    self.assertGreaterEqual(phase, .19, 'SIGTERM must arrive late in the receipt write')
                    self.assertLess(phase, 1.0, 'SIGTERM must arrive before the receipt write finishes')
                self.assertGreaterEqual(actual_pcm, evidence['elapsed_seconds'] * .9,
                                        'receipt latency must not accumulate into PCM drift')
                self.assertLessEqual(actual_pcm, evidence['elapsed_seconds'] + .1,
                                     'silence must not be emitted ahead of the recording clock')
            finally:
                if proc.poll() is None:
                    proc.kill()
                    proc.wait()
                reader.join(1)
                proc.stdout.close()
                proc.stderr.close()

    def test_recorder_final_clock_excludes_receipt_io_after_sigterm(self):
        fixture = str(Path(__file__).with_name('fixture-rec.py'))
        delayed = '''import json, os, runpy, signal, sys, time
from pathlib import Path
write_text, register_signal = Path.write_text, signal.signal
started = None

def slow_receipt(self, text, *args, **kwargs):
    global started
    evidence = json.loads(text)
    first = started is None
    if first:
        started = time.monotonic() - evidence['elapsed_seconds']
    if not evidence['stopped'] and evidence['pcm_seconds'] >= 1:
        write_text(Path(os.environ['RATCHET_WRITING']), 'ready')
        time.sleep(.4)
    else:
        time.sleep(.28 if first else .12)
    return write_text(self, text, *args, **kwargs)

def observe_signal(number, handler):
    def stopped(*args):
        received = time.monotonic() - started
        handler(*args)
        write_text(Path(os.environ['RATCHET_STOP_CLOCK']), str(received))
    return register_signal(number, stopped)

Path.write_text, signal.signal = slow_receipt, observe_signal
runpy.run_path(sys.argv[1], run_name='__main__')
'''
        with tempfile.TemporaryDirectory() as directory:
            receipt, writing, stop_clock = (Path(directory) / name for name in ('rec.json', 'writing', 'stop-clock'))
            proc = subprocess.Popen([sys.executable, '-c', delayed, fixture],
                                    env=dict(os.environ, RATCHET_REC_RECEIPT=str(receipt),
                                             RATCHET_WRITING=str(writing), RATCHET_STOP_CLOCK=str(stop_clock)),
                                    stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            audio = bytearray()
            reader = threading.Thread(target=lambda: audio.extend(proc.stdout.read()))
            reader.start()
            try:
                deadline = time.monotonic() + 4
                while not writing.exists() and time.monotonic() < deadline:
                    time.sleep(.01)
                self.assertTrue(writing.exists(), 'slow receipt was not exercised')
                proc.terminate()
                self.assertEqual(proc.wait(3), 0, proc.stderr.read().decode())
                reader.join(1)
                self.assertFalse(reader.is_alive())
                evidence = json.loads(receipt.read_text())
                actual_pcm = len(audio) / 32000
                self.assertTrue(evidence['stopped'])
                self.assertEqual(audio, b'\0' * len(audio))
                self.assertAlmostEqual(evidence['pcm_seconds'], actual_pcm, places=6)
                self.assertGreaterEqual(actual_pcm, evidence['elapsed_seconds'] * .9,
                                        'receipt latency must not accumulate into PCM drift')
                self.assertLessEqual(actual_pcm, evidence['elapsed_seconds'] + .1,
                                     'silence must not be emitted ahead of the recording clock')
                self.assertAlmostEqual(evidence['elapsed_seconds'], float(stop_clock.read_text()), delta=.02)
            finally:
                if proc.poll() is None:
                    proc.kill()
                    proc.wait()
                reader.join(1)
                proc.stdout.close()
                proc.stderr.close()

    def test_recorder_emits_silence_and_records_termination(self):
        with tempfile.TemporaryDirectory() as directory:
            receipt = Path(directory) / 'rec.json'
            proc = subprocess.Popen([sys.executable, str(Path(__file__).with_name('fixture-rec.py')), '-t', 'raw'],
                                    env=dict(os.environ, RATCHET_REC_RECEIPT=str(receipt)), stdout=subprocess.PIPE)
            try:
                self.assertEqual(proc.stdout.read(1024), b'\0' * 1024)
                proc.terminate()
                self.assertEqual(proc.wait(3), 0)
                evidence = json.loads(receipt.read_text())
                self.assertTrue(evidence['stopped'])
                self.assertGreaterEqual(evidence['pcm_seconds'], .032)
            finally:
                if proc.poll() is None:
                    proc.kill()
                    proc.wait()
                proc.stdout.close()

    def test_prompt_fixture_writes_only_synthetic_silent_wav(self):
        with tempfile.TemporaryDirectory() as directory:
            audio, metadata = Path(directory) / 'prompt.mp3', Path(directory) / 'words.ndjson'
            subprocess.run([sys.executable, str(Path(__file__).with_name('fixture-tts.py')),
                            'edge-tts-words.py', '--write-media=' + str(audio),
                            '--write-metadata=' + str(metadata)], check=True)
            with wave.open(str(audio)) as wav:
                self.assertEqual(wav.readframes(wav.getnframes()), b'\0' * 3200)
            self.assertEqual(metadata.read_text(), '')


class DaemonLifetimeTests(unittest.TestCase):
    def test_delayed_case_is_killed_and_fails_before_its_outer_wait(self):
        proc = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(5)'])
        try:
            cap = runner.DaemonLifetime(proc, seconds=.15)
            with self.assertRaisesRegex(RuntimeError, 'daemon lifetime cap'):
                cap.wait(lambda: False, timeout=2)
            proc.wait(1)
            self.assertEqual(proc.returncode, -9)
            self.assertTrue(cap.expired.is_set())
            cap.finish()
        finally:
            if proc.poll() is None:
                proc.kill()
                proc.wait()

    def test_watchdog_kills_child_while_case_thread_is_blocked(self):
        proc = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(5)'])
        cap = runner.DaemonLifetime(proc, seconds=.15)
        try:
            proc.wait(1)  # No check/wait polling: only the independent watchdog can kill it.
            self.assertEqual(proc.returncode, -9)
            self.assertTrue(cap.expired.is_set())
        finally:
            if proc.poll() is None:
                proc.kill()
                proc.wait()
            cap.finish()

    def test_expired_cap_cannot_be_reported_as_a_pass(self):
        class ExpiredCap:
            def check(self):
                raise RuntimeError('daemon lifetime cap exhausted')
        class RunFixture:
            caps = [ExpiredCap()]
            overlay_hash = None
            def __init__(self, *args): pass
            def build(self): pass
            def close(self): pass
        with tempfile.TemporaryDirectory() as directory:
            argv = ['run.py', '--row', 'voice-ask-lock-suspends-timeout', '--output', directory]
            with patch.object(runner, 'Run', RunFixture), patch.object(runner, 'lock_row', return_value=0), \
                    patch.object(runner, 'sha', return_value='a' * 40), patch('sys.argv', argv), patch('builtins.print'):
                self.assertEqual(runner.main(), 1)
            result = json.loads((Path(directory) / 'result.json').read_text())[0]
            self.assertEqual(result['status'], 'FAIL')
            self.assertIn('daemon lifetime cap', result['error'])

    def test_cleanup_keeps_watchdog_armed_for_unresponsive_child(self):
        proc = subprocess.Popen([sys.executable, '-c',
                                 'import signal,time; signal.signal(signal.SIGTERM, signal.SIG_IGN); print("ready",flush=True); time.sleep(5)'],
                                stdout=subprocess.PIPE)
        try:
            self.assertEqual(proc.stdout.readline(), b'ready\n')
            cap = runner.DaemonLifetime(proc, seconds=.15)
            cap.finish()
            self.assertEqual(proc.returncode, -9)
            with self.assertRaisesRegex(RuntimeError, 'daemon lifetime cap'):
                cap.check()
        finally:
            if proc.poll() is None:
                proc.kill()
                proc.wait()
            proc.stdout.close()


class SdkSocketTests(unittest.TestCase):
    def test_sdk_works_with_split_unicode_frames_and_no_executables_on_path(self):
        parent = Path.home() / '.vlv'
        parent.mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(prefix='pdv-', dir=parent) as directory:
            root = Path(directory)
            listener = socket.socket(socket.AF_UNIX)
            listener.bind(str(root / 'm.sock'))
            listener.listen()
            listener.settimeout(5)
            errors = []
            def server():
                try:
                    peer, _ = listener.accept()
                    with peer, peer.makefile('rb') as stream:
                        peer.settimeout(5)
                        for line in stream:
                            request = json.loads(line)
                            if 'id' not in request:
                                continue
                            if request['method'] == 'initialize':
                                result = dict(protocolVersion=request['params']['protocolVersion'],
                                              capabilities={'tools': {}}, serverInfo={'name': 'fixture', 'version': '1'})
                            else:
                                self.assertEqual(request['method'], 'tools/call')
                                self.assertEqual(request['params']['name'], 'voice_ask')
                                result = {'content': [{'type': 'text', 'text': 'Synthetic אבג'}]}
                            frame = (json.dumps(dict(jsonrpc='2.0', id=request['id'], result=result), ensure_ascii=False) + '\n').encode()
                            for i in range(0, len(frame), 3):
                                peer.sendall(frame[i:i + 3])
                except Exception as error:
                    errors.append(error)
            thread = threading.Thread(target=server)
            thread.start()
            try:
                env = dict(os.environ, PATH=str(root), VOICELAYER_MCP_SOCKET_PATH=str(root / 'm.sock'))
                output = root / 'sdk.json'
                subprocess.run([shutil.which('bun'), str(Path(__file__).with_name('lock-client.ts')), str(output)],
                               env=env, timeout=8, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                self.assertEqual(json.loads(output.read_text()), {'completed': True, 'isError': False})
            finally:
                listener.close()
                thread.join(6)
            self.assertFalse(thread.is_alive())
            self.assertEqual(errors, [])
