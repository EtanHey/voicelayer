import importlib.util
import json
import pathlib
import subprocess
import sys
import tempfile
import unittest
ROOT = pathlib.Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('transport', ROOT / 'scripts/ui_e2e_shard_io.py')
transport = importlib.util.module_from_spec(spec)
spec.loader.exec_module(transport)


class TransportProof(unittest.TestCase):
    def tearDown(self):
        transport.CANCELLED.clear()

    def test_tmp_alias_resolves_in_both_directions(self):
        self.assertEqual(transport.guest_relative('/private/tmp/run/a/output/VoiceBar.xcresult', '/tmp/run'), pathlib.Path('a/output/VoiceBar.xcresult'))
        self.assertEqual(transport.guest_relative('/tmp/run/a/output', '/private/tmp/run'), pathlib.Path('a/output'))

    def test_guest_artifact_cannot_escape(self):
        for path in ['/private/tmp/other/output', '/tmp/run/../other/output']:
            with self.assertRaises(ValueError):
                transport.guest_relative(path, '/tmp/run')

    def test_missing_dirty_or_different_builds_are_refused(self):
        for receipts in [{}, {'a': {}}, {'a': {'provenance': {'sha': 'abc', 'status': ' M file'}}}, {'a': {'provenance': {'sha': 'abc', 'status': ''}}, 'b': {'provenance': {'sha': 'def', 'status': ''}}}]:
            with self.assertRaises(ValueError):
                transport.verify_provenance(receipts)

    def test_reuse_requires_current_clean_sha(self):
        receipts = {'a': {'provenance': {'sha': 'abc', 'status': ''}}}
        transport.verify_provenance(receipts, {'sha': 'abc', 'status': ''})
        for current in [{'sha': 'def', 'status': ''}, {'sha': 'abc', 'status': '?? untracked'}]:
            with self.assertRaises(ValueError):
                transport.verify_provenance(receipts, current)

    def test_real_git_provenance_detects_untracked_files(self):
        with tempfile.TemporaryDirectory() as tmp:
            subprocess.run(['git', 'init', '-q', tmp], check=True)
            subprocess.run(['git', '-C', tmp, '-c', 'user.name=QA', '-c', 'user.email=qa@example.invalid', 'commit', '--allow-empty', '-qm', 'test'], check=True)
            self.assertEqual(transport.provenance(tmp)['status'], '')
            pathlib.Path(tmp, 'untracked').write_text('dirty')
            self.assertIn('?? untracked', transport.provenance(tmp)['status'])

    def test_timeout_reaps_real_owned_process_group(self):
        with tempfile.TemporaryDirectory() as tmp:
            pidfile = pathlib.Path(tmp, 'child.pid')
            script = 'import subprocess,sys,time; from pathlib import Path; p=subprocess.Popen([sys.executable,"-c","import time; time.sleep(30)"]); Path(sys.argv[1]).write_text(str(p.pid)); time.sleep(30)'
            with self.assertRaises(TimeoutError):
                transport.command([sys.executable, '-c', script, str(pidfile)], timeout=0.4)
            child = int(pidfile.read_text())
            status = subprocess.run(['ps', '-p', str(child), '-o', 'stat='], capture_output=True, text=True).stdout.strip()
            self.assertTrue(not status or status.startswith('Z'), status)
            self.assertEqual(len(transport.ACTIVE), 0)

    def test_cancel_prevents_new_commands(self):
        transport.cancel_owned()
        with self.assertRaises(InterruptedError):
            transport.command(['false'])

    def test_large_input_survives_slow_reader_and_communicate_retry(self):
        data = 'x' * 200000
        result = transport.command([sys.executable, '-c', 'import sys,time; time.sleep(1.2); print(len(sys.stdin.read()))'], input=data, stdout=subprocess.PIPE, text=True, timeout=4)
        self.assertEqual(int(result.stdout), len(data))

    def test_worker_result_marker_tolerates_pty_stderr(self):
        self.assertEqual(transport.parse_result('Warning: host key added\r\n' + transport.RESULT_MARKER + '{"exit":0}\r\nConnection closed.\r\n'), {'exit': 0})

    def test_missing_or_duplicate_result_marker_is_refused(self):
        for output in ['warning only', transport.RESULT_MARKER + '{}\n' + transport.RESULT_MARKER + '{}']:
            with self.assertRaises(ValueError):
                transport.parse_result(output)

if __name__ == '__main__':
    unittest.main()
