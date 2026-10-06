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

spec = importlib.util.spec_from_file_location('runner', Path(__file__).with_name('run.py'))
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)


class LockTests(unittest.TestCase):
    def test_row_is_pinned_to_main_before_merge(self):
        self.assertEqual(runner.ROWS['voice-ask-lock-suspends-timeout'],
                         ('a2e25844fd98be78293ff3133122a6df0b0a50c8',
                          '7677d52e5045970485f0dd5c141f8c069f66e9d9'))

    def test_missing_deadline_ack_pcm_or_ending_is_not_a_bug_receipt(self):
        good = dict(lock_ack=True, pcm_seconds=21, held_seconds=21,
                    ended_before_release=False, completed=True, ending='stop', ending_ack=True)
        self.assertEqual(runner.lock_violations(good), 0)
        self.assertEqual(runner.lock_violations(dict(good, ended_before_release=True)), 1)
        for key, value in [('lock_ack', False), ('pcm_seconds', 0),
                           ('held_seconds', 4), ('completed', False), ('ending_ack', False), ('ending', 'cancel')]:
            with self.subTest(key=key), self.assertRaisesRegex(RuntimeError, 'lock evidence'):
                runner.lock_violations(dict(good, **{key: value}))


class ExecutableFixtureTests(unittest.TestCase):
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
