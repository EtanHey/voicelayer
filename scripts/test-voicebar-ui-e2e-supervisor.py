import importlib.util
import json
import pathlib
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parent.parent

class SupervisorTests(unittest.TestCase):
    def module(self):
        path = ROOT / 'scripts/voicebar-ui-e2e-supervisor.py'
        self.assertTrue(path.exists(), 'Committed safety supervisor missing')
        spec = importlib.util.spec_from_file_location('supervisor', path)
        module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
        return module

    def test_abort_restores_both_even_when_child_cleanup_or_show_fails(self):
        module = self.module()
        for broken in ['check', 'stop', 'restore_resident', 'start']:
            events = []
            class Fake:
                def muted(self): return False
                def set_mute(self, value): events.append(('mute', value))
                def prepare_resident(self): events.append('prepare')
                def start(self):
                    events.append('start')
                    if broken == 'start': raise RuntimeError('start failed after hide')
                def poll(self): return None
                def check(self): raise KeyboardInterrupt('guard abort')
                def wait(self, seconds): pass
                def stop(self):
                    events.append('stop')
                    if broken == 'stop': raise RuntimeError('cleanup timeout')
                def restore_resident(self):
                    events.append('show')
                    if broken == 'restore_resident': raise RuntimeError('Show failed')
                def export(self): return 0
                def save(self, receipt): self.receipt = receipt
            host = Fake()
            self.assertNotEqual(module.supervise(host), 0)
            self.assertIn('show', events)
            self.assertEqual(events[-1], ('mute', False))
            self.assertTrue(host.receipt['muteRestored'])

    def test_preconditions_fail_closed_and_wait_before_recheck(self):
        module = self.module()
        for children, locks, labels in [(['rec'], [], ['Ready']), ([], [1], ['Ready']), ([], [], ['Recording']), ([], [], []), ([], [], ['Status unreadable'])]:
            self.assertFalse(module.safe_to_hide(children, locks, labels))
        self.assertTrue(module.safe_to_hide([], [], ['Ready. Transcribed on this Mac']))
        self.assertTrue(module.safe_to_hide([], [], ['Hidden until 23:00']))
        events=[]
        class Host:
            def preconditions(self):
                events.append('read'); return len(events)>1
            def wait(self, seconds): events.append(seconds)
        module.wait_until_safe(Host())
        self.assertEqual(events, ['read', 120, 'read'])

    def test_real_preflight_reads_processes_locks_and_positive_ax_state(self):
        from unittest.mock import patch
        module = self.module()
        with tempfile.TemporaryDirectory() as tmp:
            output = pathlib.Path(tmp)
            (output / 'sandbox-path.txt').write_text(str(output / 'sandbox'))
            host = module.NativeHost(output, 'gate2246')
            host.resident = dict(pid=100, started='start')
            host.identity = lambda pid: 'start'
            host.run = lambda args: 'bun src/mcp-server-daemon.ts'
            host.ax = lambda mode: dict(nodes=[dict(value='Ready. Transcribed on this Mac')])
            safe_rows = {100: (1, '/Applications/VoiceBar.app/Contents/MacOS/VoiceBar'), 101: (100, 'bun')}
            for capture, fresh, label, expected in [(False, False, 'Ready. Local', True),
                    (True, False, 'Ready. Local', False), (False, True, 'Ready. Local', False),
                    (False, False, 'Recording. Local', False), (False, False, '', False)]:
                host.process_rows = lambda: dict(safe_rows, **{}) | ({102: (101, '/usr/bin/rec')} if capture else {})
                host.ax = lambda mode: dict(nodes=[dict(value=label)])
                class Lock:
                    name = 'voicelayer-session-fixture.lock'
                    def stat(self):
                        from types import SimpleNamespace
                        return SimpleNamespace(st_mtime=module.time.time())
                with patch.object(pathlib.Path, 'glob', return_value=[Lock()] if fresh else []):
                    self.assertEqual(host.preconditions(), expected)

    def test_native_runner_requires_live_parent_supervisor(self):
        module=self.module()
        with tempfile.TemporaryDirectory() as tmp:
            with self.assertRaises((ValueError, FileNotFoundError)):
                module.require_supervisor(pathlib.Path(tmp), {})
        import os
        with tempfile.TemporaryDirectory() as tmp:
            output=pathlib.Path(tmp)
            proof=output/'supervisor-authority.json'
            proof.write_text(json.dumps(dict(pid=os.getppid(), token='fixture-token')))
            module.require_supervisor(output, {'VOICEBAR_UIE2E_SUPERVISOR_TOKEN':'fixture-token'})
            with self.assertRaises(ValueError):
                module.require_supervisor(output, {'VOICEBAR_UIE2E_SUPERVISOR_TOKEN':'wrong'})
            proof.write_text(json.dumps(dict(pid=0, token='fixture-token')))
            with self.assertRaises(ValueError):
                module.require_supervisor(output, {'VOICEBAR_UIE2E_SUPERVISOR_TOKEN':'fixture-token'})
        source=(ROOT/'scripts/voicebar-ui-e2e-run.py').read_text()
        self.assertIn('require_supervisor(output', source)
        self.assertIn('voicebar-ui-e2e-supervisor.py', (ROOT/'scripts/voicebar-ui-e2e.sh').read_text())

    def test_direct_native_entry_refuses_before_recording(self):
        with tempfile.TemporaryDirectory() as tmp:
            output = pathlib.Path(tmp)
            result = subprocess.run(['python3', str(ROOT/'scripts/voicebar-ui-e2e-run.py'), str(output)], capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('supervisor-authority.json', result.stderr)
            self.assertFalse((output/'recording.json').exists())

    def test_release_gate_rejects_each_new_marker(self):
        for marker in ['configureAudioLevelMonitoringForTesting', 'UIE2EGate2245', 'VOICEBAR_UIE2E_GATE2245']:
            with tempfile.NamedTemporaryFile() as binary:
                binary.write(marker.encode()); binary.flush()
                result=subprocess.run(['bash',str(ROOT/'scripts/check-voicebar-qa-free.sh'),binary.name],capture_output=True)
                self.assertEqual(result.returncode,1,marker)

if __name__=='__main__': unittest.main()
