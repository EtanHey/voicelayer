import importlib.util
import json
import pathlib
import subprocess
import tempfile
import unittest
from unittest.mock import patch

ROOT = pathlib.Path(__file__).resolve().parent.parent

class SupervisorTests(unittest.TestCase):
    def host(self, output):
        (output / 'sandbox-path.txt').write_text(str(output / 'sandbox'))
        host = self.module().NativeHost(output, 'gate2246')
        host.resident = dict(pid=100, started='resident-start', restoreRequired=True,
                             settingsOpened=True, initialHidden=False)
        host.identity = lambda pid: 'resident-start'
        host.resident['initialSurface'] = [dict(bounds=dict(X=500, Y=0, Width=200, Height=32), layer=25)]
        return host

    def ax_fixture(self, host, *, surface=True, timeout=None):
        state = dict(settings=host.resident['settingsOpened'], hidden=True, actions=[])
        def ax(mode):
            state['actions'].append(mode)
            if mode == 'open': state['settings'] = True
            if mode == 'close': state['settings'] = False
            if mode == 'show': state['hidden'] = False
            if mode == timeout:
                raise subprocess.TimeoutExpired(mode, 15)
            nodes = []
            if state['settings']:
                nodes = [dict(role='AXWindow', title='VoiceBar Settings'),
                         dict(title='Show VoiceBar' if state['hidden'] else 'Hide VoiceBar for 1 hour')]
            return dict(nodes=nodes, settingsWindowId=77 if state['settings'] else None, screenWindows=(host.resident['initialSurface']
                        if surface and not state['settings'] and not state['hidden'] else []))
        host.ax = ax
        return state

    def test_applied_close_timeout_reconciles_settings_and_restores_surface(self):
        with tempfile.TemporaryDirectory() as tmp:
            host = self.host(pathlib.Path(tmp))
            host.preconditions = lambda: True
            host.check = lambda: (_ for _ in ()).throw(RuntimeError('synthetic abort after reconciled close'))
            state = self.ax_fixture(host, timeout='close')
            with self.assertRaisesRegex(RuntimeError, 'synthetic abort'): host.start()
            # The close applied despite its lost response. Do not repeat it or trust the cache.
            state['actions'].clear()
            # Restore has the same response-timeout ambiguity on its own final close.
            host.restore_resident()
            self.assertTrue(host.resident['restored'])
            self.assertEqual(state['actions'].count('open'), 1)
            self.assertEqual(state['actions'].count('show'), 1)

    def test_show_label_without_original_surface_fails_closed(self):
        with tempfile.TemporaryDirectory() as tmp:
            host = self.host(pathlib.Path(tmp))
            self.ax_fixture(host, surface=False)
            with self.assertRaises(RuntimeError): host.restore_resident()
            self.assertFalse(host.resident.get('restored', False))
            self.assertTrue(host.resident['restoreRequired'])

    def test_show_then_close_ambiguity_retains_recovery_until_surface_proven(self):
        for failure in ['applied-timeout', 'failed', 'timeout', 'unreadable', 'settings-only', 'reopened']:
            with self.subTest(failure=failure), tempfile.TemporaryDirectory() as tmp:
                host = self.host(pathlib.Path(tmp))
                state = self.ax_fixture(host, timeout='close' if failure == 'applied-timeout' else None)
                original = host.ax
                closed_reads = [0]
                def ax(mode):
                    if mode == 'close' and failure in ['failed', 'timeout']:
                        if failure == 'timeout': raise subprocess.TimeoutExpired(mode, 15)
                        raise RuntimeError('Close rejected')
                    result = original(mode)
                    if mode == 'read' and not state['settings']:
                        closed_reads[0] += 1
                        if failure == 'unreadable': raise RuntimeError('AX evidence unavailable')
                        if failure == 'reopened' and closed_reads[0] > 1:
                            result['nodes'] = [dict(role='AXWindow', title='VoiceBar Settings')]
                        if failure == 'settings-only':
                            result['screenWindows'] = [dict(layer=0, bounds=dict(X=300, Y=300, Width=640, Height=480))]
                    return result
                host.ax = ax
                if failure == 'applied-timeout':
                    host.restore_resident()
                    self.assertTrue(host.resident['restored'])
                    self.assertFalse(host.resident['restoreRequired'])
                    self.assertFalse(state['settings'])
                else:
                    with self.assertRaises(Exception): host.restore_resident()
                    self.assertTrue(host.resident['restoreRequired'])
                    self.assertFalse(host.resident.get('restored', False))
                    host.ax = original
                    host.restore_resident()
                    self.assertTrue(host.resident['restored'])
                self.assertEqual(state['actions'].count('show'), 1)

    def test_stubborn_runner_cannot_skip_qa_cleanup_or_unmute(self):
        module = self.module()
        with tempfile.TemporaryDirectory() as tmp:
            host = self.host(pathlib.Path(tmp))
            events = []
            class Child:
                pid = 200
                def poll(self): return None
                def send_signal(self, sig): events.append(('legacy-runner', sig))
                def wait(self, timeout): raise subprocess.TimeoutExpired('runner', timeout)
            host.child = Child()
            expected = str((host.sandbox / 'VoiceBarQA.app/Contents/MacOS/VoiceBar').resolve())
            live = {200: dict(started='runner-start', cmd='python-runner', parent=1, state='S'),
                    201: dict(started='qa-start', cmd=expected, parent=200, state='S')}
            host.owned = {200: dict(live[200], kind='runner')}
            host.process_state = lambda pid: live.get(pid)
            host.process_rows = lambda: {pid: (row['parent'], row['cmd']) for pid, row in live.items()}
            host.guard_mute = lambda: events.append('guard')
            host.shutdown_wait = lambda seconds: events.append('guard')
            mute = [False]
            host.muted = lambda: mute[0]
            def set_mute(value):
                mute[0] = value
                events.append(('mute', value))
            host.set_mute = set_mute
            host.prepare_resident = lambda: None
            host.start = lambda: (_ for _ in ()).throw(RuntimeError('abort'))
            host.restore_resident = lambda: events.append('restore')
            host.save = lambda receipt: setattr(host, 'receipt', dict(receipt))
            def kill(pid, sig):
                events.append((pid, sig))
                if pid == 201: live.pop(pid, None)
            with patch.object(module.os, 'kill', side_effect=kill):
                self.assertNotEqual(module.supervise(host), 0)
            self.assertTrue(any(isinstance(event, tuple) and event[0] == 201 for event in events))
            self.assertNotIn(('mute', False), events)
            self.assertFalse(host.receipt['ownedTerminationProven'])
            self.assertTrue(host.receipt['muteRetained'])
            self.assertIn('guard', events)

    def test_restore_success_hidden_preservation_and_missing_surface_evidence(self):
        for hidden, evidence in [(False, True), (True, True), (False, False)]:
            with self.subTest(hidden=hidden, evidence=evidence), tempfile.TemporaryDirectory() as tmp:
                host = self.host(pathlib.Path(tmp))
                host.resident.update(initialHidden=hidden, restoreRequired=not hidden)
                if not evidence: host.resident.pop('initialSurface')
                state = self.ax_fixture(host)
                if hidden:
                    host.resident['initialSurface'] = []
                    host.restore_resident()
                    self.assertNotIn('show', state['actions'])
                    self.assertNotIn('open', state['actions'])
                elif evidence:
                    host.restore_resident()
                    self.assertTrue(host.resident['restored'])
                    self.assertFalse(state['settings'])
                else:
                    # Supply current surface independently of the missing initial evidence.
                    host.ax = lambda mode: dict(nodes=[dict(title='Hide VoiceBar for 1 hour')],
                                                screenWindows=[])
                    with self.assertRaises(RuntimeError): host.restore_resident()
                    self.assertFalse(host.resident.get('restored', False))

    def test_settings_user_window_or_replacement_is_never_closed(self):
        for owned, window_id in [(False, 77), (True, 88)]:
            with tempfile.TemporaryDirectory() as tmp:
                host = self.host(pathlib.Path(tmp))
                host.resident.update(settingsOpened=owned, settingsWindowId=77)
                actions = []
                def ax(mode):
                    actions.append(mode)
                    return dict(nodes=[dict(role='AXWindow', title='VoiceBar Settings')],
                                settingsWindowId=window_id)
                host.ax = ax
                with self.assertRaises(RuntimeError): host.restore_resident()
                self.assertEqual(actions, ['read'])

    def test_each_signal_rechecks_identity_and_never_signals_reused_pid(self):
        with tempfile.TemporaryDirectory() as tmp:
            host = self.host(pathlib.Path(tmp))
            host.owned = {200: dict(started='start', cmd='fixture')}
            live = dict(started='start', cmd='fixture', state='S')
            host.process_state = lambda pid: live
            host.guard_mute = lambda: None
            host.shutdown_wait = lambda seconds: None
            host.process_rows = lambda: {}
            def signal_sent(pid, sig): live['started'] = 'replacement-start'
            with patch('os.kill', side_effect=signal_sent) as kill:
                with self.assertRaisesRegex(RuntimeError, 'identity changed'):
                    host.terminate_owned(200, runner=True)
                self.assertEqual(kill.call_count, 1)

    def test_successful_owned_shutdown_and_unreadable_identity_fail_closed(self):
        with tempfile.TemporaryDirectory() as tmp:
            host = self.host(pathlib.Path(tmp))
            host.owned = {200: dict(started='start', cmd='fixture')}
            host.process_rows = lambda: {}
            host.process_state = lambda pid: None
            self.assertTrue(host.stop())
            def unreadable(pid): raise RuntimeError('identity unavailable')
            host.process_state = unreadable
            with patch('os.kill') as kill:
                self.assertFalse(host.stop())
                kill.assert_not_called()

    def module(self):
        path = ROOT / 'scripts/voicebar-ui-e2e-supervisor.py'
        self.assertTrue(path.exists(), 'Committed safety supervisor missing')
        spec = importlib.util.spec_from_file_location('supervisor', path)
        module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
        return module

    def test_abort_restores_visibility_but_requires_shutdown_proof_to_unmute(self):
        module = self.module()
        for broken in ['check', 'stop', 'restore_resident', 'start']:
            events = []
            class Fake:
                mute = False
                def muted(self): return self.mute
                def set_mute(self, value): self.mute = value; events.append(('mute', value))
                def guard_mute(self): pass
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
                    return True
                def restore_resident(self):
                    events.append('show')
                    if broken == 'restore_resident': raise RuntimeError('Show failed')
                def export(self): return 0
                def save(self, receipt): self.receipt = receipt
            host = Fake()
            self.assertNotEqual(module.supervise(host), 0)
            self.assertIn('show', events)
            self.assertEqual(events[-1], ('mute', broken == 'stop'))
            self.assertEqual(host.receipt['muteRestored'], broken != 'stop')

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
