"""Lock row evidence must fail closed; unit evidence only."""
import importlib.util
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


class ExecutableFixtureTests(unittest.TestCase):
    def test_recorder_keeps_pcm_pace_when_receipt_io_is_slow(self):
        fixture = str(Path(__file__).with_name('fixture-rec.py'))
        delayed = '''import runpy, sys, time
from pathlib import Path
original = Path.write_text
def slow_receipt(self, *args, **kwargs):
    time.sleep(.12)
    return original(self, *args, **kwargs)
Path.write_text = slow_receipt
runpy.run_path(sys.argv[1], run_name='__main__')
'''
        with tempfile.TemporaryDirectory() as directory:
            receipt = Path(directory) / 'rec.json'
            proc = subprocess.Popen([sys.executable, '-c', delayed, fixture],
                                    env=dict(os.environ, RATCHET_REC_RECEIPT=str(receipt)),
                                    stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            audio = bytearray()
            reader = threading.Thread(target=lambda: audio.extend(proc.stdout.read()))
            reader.start()
            try:
                deadline = time.monotonic() + 3
                while not receipt.exists() and time.monotonic() < deadline:
                    time.sleep(.01)
                self.assertTrue(receipt.exists(), 'recorder startup receipt missing')
                time.sleep(1.2)
                proc.terminate()
                self.assertEqual(proc.wait(3), 0, proc.stderr.read().decode())
                reader.join(1)
                self.assertFalse(reader.is_alive())
                evidence = json.loads(receipt.read_text())
                self.assertTrue(evidence['stopped'])
                actual_pcm = len(audio) / 32000
                self.assertEqual(audio, b'\0' * len(audio))
                self.assertAlmostEqual(evidence['pcm_seconds'], actual_pcm, places=6)
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
