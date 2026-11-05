import importlib.util
import pathlib
import unittest
import tempfile
import json
import subprocess
import sys
from types import SimpleNamespace
from unittest.mock import patch
ROOT = pathlib.Path(__file__).resolve().parents[2]

def load(name, file):
    s = importlib.util.spec_from_file_location(name, ROOT / 'scripts' / file)
    m = importlib.util.module_from_spec(s)
    s.loader.exec_module(m)
    return m
shard = load('shard', 'ui-e2e-shard.py')
guest = load('guest', 'ui-e2e-guest.py')
CONFIG = {'hosts': [{'id': 'm4', 'repo': '/repo'}], 'environments': [{'id': 'm4-host', 'kind': 'host', 'host': 'm4'}, {'id': 'a', 'kind': 'tart', 'host': 'm4', 'pointer_ok': True}, {'id': 'b', 'kind': 'tart', 'host': 'm4', 'pointer_ok': True}]}

class SafetyAndAllocation(unittest.TestCase):

    def test_round_robin_every_case_once(self):
        p = shard.plan(CONFIG)
        self.assertEqual(p['jobs'], {'a': ['full', 'hide1'], 'b': ['focused-338', 'gate2246']})
        self.assertEqual(p['excluded_hosts'], ['m4-host'])

    def test_duration_assignment_balances_long_cases(self):
        p = shard.plan(CONFIG, {'full': 900, 'focused-338': 700, 'hide1': 200, 'gate2246': 300})
        self.assertEqual(p['jobs'], {'a': ['full', 'hide1'], 'b': ['focused-338', 'gate2246']})
        self.assertEqual(p['predicted_seconds'], {'a': 1100, 'b': 1000})

    def test_host_only_refused_before_execution(self):
        with self.assertRaisesRegex(ValueError, 'host execution refused'):
            shard.plan(CONFIG, host_only=True)

    def test_authorized_m1_host_can_be_baseline(self):
        config = dict(CONFIG, hosts=CONFIG['hosts'] + [{'id': 'm1', 'model': 'MacBookPro18,3'}], environments=CONFIG['environments'] + [{'id': 'm1-host', 'kind': 'host', 'host': 'm1', 'pointer_ok': True}])
        self.assertEqual(shard.plan(config, host_only=True)['jobs'], {'m1-host': list(shard.SCENARIOS)})

    def test_m4_host_cannot_opt_in(self):
        config = dict(CONFIG, environments=[{'id': 'bad', 'kind': 'host', 'host': 'm4', 'pointer_ok': True}])
        with self.assertRaisesRegex(ValueError, 'non-allowlisted'):
            shard.plan(config)

    def test_renamed_daily_host_still_cannot_opt_in(self):
        config = {'hosts': [{'id': 'rig', 'model': 'Mac16,5'}], 'environments': [{'id': 'host', 'kind': 'host', 'host': 'rig', 'pointer_ok': True}]}
        with self.assertRaisesRegex(ValueError, 'non-allowlisted'):
            shard.plan(config)

    def test_serial_has_same_cases(self):
        p = shard.plan(CONFIG, serial=True)
        self.assertEqual(p['jobs'], {'a': list(shard.SCENARIOS)})

    def test_duplicate_environment_rejected(self):
        config = dict(CONFIG, environments=CONFIG['environments'] + [CONFIG['environments'][0]])
        with self.assertRaisesRegex(ValueError, 'Duplicate'):
            shard.plan(config)

    def test_unknown_case_cannot_be_classified_host_safe(self):
        with self.assertRaisesRegex(ValueError, 'existing UIE2E'):
            shard.plan(dict(CONFIG, scenarios=['unsafeCase']))

    def test_guest_entry_refuses_physical_mac(self):
        with patch.object(guest.subprocess, 'check_output', return_value='Mac16,5\n'):
            with self.assertRaisesRegex(RuntimeError, 'physical host'):
                guest.require_guest()

    def test_guest_entry_accepts_virtual_mac(self):
        with patch.object(guest.subprocess, 'check_output', return_value='VirtualMac2,1\n'):
            self.assertEqual(guest.require_guest(), 'VirtualMac2,1')

class ReviewRegressions(unittest.TestCase):

    def tearDown(self):
        shard.io.CANCELLED.clear()



    def test_serial_vm_ignores_authorized_host_even_when_first(self):
        config = {'hosts': [{'id': 'm1', 'model': 'MacBookPro18,3'}], 'environments': [{'id': 'host', 'host': 'm1', 'kind': 'host', 'pointer_ok': True}, {'id': 'vm', 'host': 'm1', 'kind': 'tart', 'pointer_ok': True}]}
        self.assertEqual(shard.plan(config, serial=True)['jobs'], {'vm': list(shard.SCENARIOS)})

    def test_no_vm_is_refused_in_serial_vm_mode(self):
        config = {'hosts': [{'id': 'm1', 'model': 'MacBookPro18,3'}], 'environments': [{'id': 'host', 'host': 'm1', 'kind': 'host', 'pointer_ok': True}]}
        with self.assertRaises(ValueError):
            shard.plan(config, serial=True)

    def test_runtime_model_is_checked_before_copy_or_mute(self):
        with patch.object(shard, 'command', return_value=SimpleNamespace(stdout='Mac16,5')) as command:
            with self.assertRaisesRegex(ValueError, 'non-allowlisted'):
                shard.run_cases('/does/not/exist', ['hide1'], guest=False)
            self.assertEqual(command.call_count, 1)




    def test_collection_skips_missing_result_and_keeps_next(self):
        with tempfile.TemporaryDirectory() as tmp:
            tests = [{'scenario': 'hide1', 'output': '/guest/hide1/output'}, {'scenario': 'full', 'output': '/guest/full/output'}]

            def copy(destination, source, target, python):
                if 'hide1' in source:
                    raise FileNotFoundError(source)
                (target / 'VoiceBar.xcresult').mkdir(parents=True)
            with patch.object(shard.io, 'collect_remote', side_effect=copy) as collect:
                errors = shard.io.collect_tests('guest', tests, tmp)
            self.assertEqual(collect.call_count, 2)
            self.assertEqual(len(errors), 1)
            self.assertTrue(pathlib.Path(tests[1]['collected_xcresult']).is_dir())
            self.assertTrue(all((call.args[1].endswith('/output') for call in collect.call_args_list)))

    def test_collection_checks_disk_before_scp(self):
        with tempfile.TemporaryDirectory() as tmp, patch.object(shard.io, 'ssh', return_value=SimpleNamespace(stdout='100')), patch.object(shard.shutil, 'disk_usage', return_value=SimpleNamespace(free=shard.DISK_FLOOR)), patch.object(shard.io, 'command') as command:
            with self.assertRaisesRegex(RuntimeError, 'floor'):
                shard.io.collect_remote('guest', '/output', pathlib.Path(tmp) / 'output')
            command.assert_not_called()

    def test_ssh_and_scp_boundaries_and_keepalives(self):
        with patch.object(shard.io, 'command', return_value=SimpleNamespace(stdout='1')) as command:
            shard.io.ssh('guest', ['echo', 'hello'], tty=True, timeout=10)
            argv = command.call_args.args[0]
            self.assertEqual(argv[argv.index('--') + 1], 'guest')
            self.assertIn('-tt', argv)
            self.assertIn('ServerAliveInterval=15', argv)
        with tempfile.TemporaryDirectory() as tmp, patch.object(shard.io, 'ssh', return_value=SimpleNamespace(stdout='1')), patch.object(shard.shutil, 'disk_usage', return_value=SimpleNamespace(free=2 * shard.DISK_FLOOR)), patch.object(shard.io, 'command') as command:
            shard.io.collect_remote('guest', '/owned/output', pathlib.Path(tmp) / 'output')
            argv = command.call_args.args[0]
            self.assertEqual(argv[argv.index('--') + 1], 'guest:/owned/output')
            self.assertEqual(command.call_args.kwargs['timeout'], shard.TRANSFER_SECONDS)

    def test_summary_is_written_on_build_failure(self):
        with tempfile.TemporaryDirectory() as tmp, patch.object(shard, 'on_host', side_effect=RuntimeError('build failed')):
            summary = shard.execute(CONFIG, shard.plan(CONFIG), pathlib.Path(tmp))
            self.assertFalse(summary['passed'])
            self.assertEqual(json.loads(pathlib.Path(tmp, 'summary.json').read_text())['errors'], ['build failed'])

    def test_summary_survives_missing_remote_xcresult(self):
        config = {'hosts': [{'id': 'm1', 'model': 'MacBookPro18,3', 'repo': '/repo', 'ssh': 'rig'}], 'environments': [{'id': 'host', 'host': 'm1', 'kind': 'host', 'pointer_ok': True}], 'scenarios': ['hide1']}
        receipt = {'root': '/root', 'provenance': {'sha': 'abc', 'status': ''}}

        def worker(host, args):
            if args[0] == '_build':
                return receipt
            if args[0] == '_provenance':
                return receipt['provenance']
            return {'environment': 'host', 'exit': 0, 'tests': [{'scenario': 'hide1', 'exit': 0, 'output': '/output'}]}
        with tempfile.TemporaryDirectory() as tmp, patch.object(shard, 'on_host', side_effect=worker), patch.object(shard.io, 'collect_remote', side_effect=FileNotFoundError('missing')):
            summary = shard.execute(config, shard.plan(config), pathlib.Path(tmp))
            self.assertFalse(summary['passed'])
            self.assertIn('missing', summary['environments'][0]['collection_errors'][0]['error'])
            self.assertTrue(pathlib.Path(tmp, 'summary.json').is_file())




    def test_result_inspection_allows_internal_file_links_but_refuses_escape(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp) / 'output'
            root.mkdir()
            (root / 'file').write_text('ok')
            (root / 'link').symlink_to('file')

            def remote(destination, argv, **kwargs):
                return subprocess.run([sys.executable, '-O', *argv[1:]], check=True, **kwargs)
            with patch.object(shard.io, 'ssh', side_effect=remote), patch.object(shard.shutil, 'disk_usage', return_value=SimpleNamespace(free=2 * shard.DISK_FLOOR)), patch.object(shard.io, 'command'):
                shard.io.collect_remote('guest', str(root), pathlib.Path(tmp) / 'collected')
                (root / 'escape').symlink_to('/etc/passwd')
                with self.assertRaises(subprocess.CalledProcessError):
                    shard.io.collect_remote('guest', str(root), pathlib.Path(tmp) / 'other')


    def test_remote_bootstrap_stages_support_and_parses_only_marker(self):
        calls = []
        def remote(destination, argv, **kwargs):
            calls.append((argv, kwargs))
            result = '/owned/ui-e2e-shard.py' if len(calls) == 1 else {'sha': 'abc', 'status': ''}
            return SimpleNamespace(stdout='warning from PTY\n' + shard.io.RESULT_MARKER + json.dumps(result) + '\n')
        with patch.object(shard, 'ssh', side_effect=remote):
            self.assertEqual(shard.on_host({'ssh': 'rig'}, ['_provenance', '/repo']), {'sha': 'abc', 'status': ''})
        self.assertIn('ui_e2e_shard_io.py', json.loads(calls[0][1]['input']))
        self.assertTrue(calls[1][1]['tty'])

if __name__ == '__main__':
    unittest.main()
