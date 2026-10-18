import importlib.util
import json
import os
import pathlib
import subprocess
import tempfile
import unittest
from unittest.mock import patch

ROOT = pathlib.Path(__file__).resolve().parent.parent

class SupervisorTests(unittest.TestCase):
    def timeout_host(self, output):
        host = self.host(output)
        host.resident.update(visibilityPolicy='leave-shown', restoreRequired=False,
                             settingsOpened=False)
        host.resident.pop('settingsWindowId')
        host.preconditions = lambda: True
        host.prepare_resident = lambda: None
        host.check = lambda: None
        host.process_rows = lambda: {}  # No native process inspection/signals.
        host.ax = lambda mode: dict(screenWindows=host.resident['initialSurface'])
        mute = [False]
        host.muted = lambda: mute[0]
        host.set_mute = lambda value: mute.__setitem__(0, value)
        # Run the actual subprocess APIs against a private, deliberately stuck helper.
        host.repo = output / 'fixture-repo'
        helper = host.repo / 'scripts/voicebar-ui-e2e-results.py'
        helper.parent.mkdir(parents=True)
        helper.write_text('import time; time.sleep(30)\n')
        return host

    def test_configure_timeout_records_failure_before_runner_launch(self):
        module = self.module()
        real_run = subprocess.run
        with tempfile.TemporaryDirectory() as tmp:
            host = self.timeout_host(pathlib.Path(tmp))
            def bounded_run(args, **kwargs):
                limit = kwargs.get('timeout')
                self.assertIsInstance(limit, (int, float), 'configure has no finite deadline')
                self.assertTrue(0 < limit <= 120)
                return real_run(args, **dict(kwargs, timeout=.05))
            with patch.object(module.subprocess, 'run', side_effect=bounded_run), \
                    patch.object(module.subprocess, 'Popen', wraps=subprocess.Popen) as launch:
                self.assertEqual(module.supervise(host), 1)
                # Only the configure helper ran; no runner or export was dispatched.
                launch_count = launch.call_count
            receipt = json.loads((host.output / 'operator-state.json').read_text())
            self.assertIn('TimeoutExpired', receipt['error'])
            self.assertEqual(launch_count, 1)
            self.assertIsNone(receipt['suiteExit'])
            self.assertIsNone(receipt['exportExit'])
            self.assertFalse(host.runner_launch_attempted)
            self.assertTrue(receipt['ownedTerminationProven'])
            self.assertTrue(receipt['muteRestored'])
            self.assertTrue(host.resident['shownUnchanged'])
            self.assertFalse((host.output / 'supervisor-authority.json').exists())

    def test_export_timeout_preserves_completed_verdict_and_retained_mute(self):
        module = self.module()
        real_call = subprocess.call
        with tempfile.TemporaryDirectory() as tmp:
            host = self.timeout_host(pathlib.Path(tmp))
            # Completed QA run, but launch completeness remains unknown.
            host.start = lambda: setattr(host, 'runner_launch_attempted', True)
            host.poll = lambda: 0
            def bounded_call(args, **kwargs):
                before = json.loads((host.output / 'operator-state.json').read_text())
                self.assertEqual(before['suiteExit'], 0)
                self.assertTrue(before['muteRetained'])
                self.assertTrue(host.resident['shownUnchanged'])
                limit = kwargs.get('timeout')
                self.assertIsInstance(limit, (int, float), 'export has no finite deadline')
                self.assertTrue(0 < limit <= 300)
                return real_call(args, **dict(kwargs, timeout=.05))
            with patch.object(module.subprocess, 'call', side_effect=bounded_call) as export:
                self.assertEqual(module.supervise(host), 1)
                self.assertEqual(export.call_count, 1)
            receipt = json.loads((host.output / 'operator-state.json').read_text())
            self.assertIn('TimeoutExpired', receipt['error'])
            self.assertEqual(receipt['suiteExit'], 0)
            self.assertIsNone(receipt['exportExit'])
            self.assertFalse(receipt['ownedTerminationProven'])
            self.assertTrue(receipt['muteRetained'])
            self.assertTrue(any('NOT_PROVEN' in e for e in receipt['cleanupErrors']))

    def test_ship2246_shown_resident_reaches_launch_and_export_without_settings(self):
        module = self.module()
        with tempfile.TemporaryDirectory() as tmp:
            host = self.host(pathlib.Path(tmp))
            actions = []
            surface = [dict(layer=25, bounds=dict(X=500, Y=0, Width=200, Height=32))]
            host.process_rows = lambda: {100: (1, '/Applications/VoiceBar.app/Contents/MacOS/VoiceBar')}
            host.preconditions = lambda: True
            def io(args):
                if len(args) == 1: return json.dumps(dict(axTrusted=True, prompts=[]))
                actions.append(args[2])
                return json.dumps(dict(nodes=[], screenWindows=surface))
            host.run = io
            mute = [False]
            host.muted = lambda: mute[0]
            host.set_mute = lambda value: mute.__setitem__(0, value)
            host.check = lambda: None
            host.remember = lambda *args: None
            def stop():
                if host.log: host.log.close()
                return False  # Unknown descendants retain mute without suppressing verdicts.
            host.stop = stop
            host.export = lambda: actions.append('export') or 0
            class Child:
                pid = 200
                def poll(self): return 0
            with patch.object(module.subprocess, 'run'), patch.object(module.subprocess, 'Popen', return_value=Child()):
                self.assertEqual(module.supervise(host), 1)  # Safety uncertainty remains explicit.
            receipt = json.loads((host.output / 'operator-state.json').read_text())
            self.assertEqual(receipt['suiteExit'], 0)
            self.assertEqual(receipt['exportExit'], 0)
            self.assertTrue(receipt['muteRetained'])
            self.assertTrue(host.resident['shownUnchanged'])
            self.assertEqual(set(actions), {'read', 'export'})

    def test_ship2246_missing_shown_surface_stops_before_any_mutation(self):
        with tempfile.TemporaryDirectory() as tmp:
            host = self.host(pathlib.Path(tmp))
            host.process_rows = lambda: {100: (1, '/Applications/VoiceBar.app/Contents/MacOS/VoiceBar')}
            host.run = lambda args: json.dumps(dict(axTrusted=True, prompts=[])) if len(args) == 1 else json.dumps(dict(nodes=[], screenWindows=[]))
            host.preconditions = lambda: True
            with self.assertRaisesRegex(RuntimeError, 'shown resident'):
                host.prepare_resident()
            self.assertFalse(host.runner_launch_attempted)

    def test_ship2246_shown_surface_and_identity_drift_never_clear_obligations(self):
        for failure in ['surface', 'resident', 'daemon']:
            with self.subTest(failure=failure), tempfile.TemporaryDirectory() as tmp:
                host = self.host(pathlib.Path(tmp))
                host.resident.update(visibilityPolicy='leave-shown', settingsOpened=False,
                                     restoreRequired=False, daemonPid=101, daemonStarted='daemon-start')
                host.resident.pop('settingsWindowId')
                host.identity = lambda pid: ('changed' if failure == 'resident' and pid == 100 else
                    'changed' if failure == 'daemon' and pid == 101 else
                    'daemon-start' if pid == 101 else 'resident-start')
                actions = []
                host.ax = lambda mode: actions.append(mode) or dict(screenWindows=[])
                with self.assertRaises(RuntimeError): host.restore_resident()
                self.assertFalse(host.resident['shownUnchanged'])
                self.assertTrue(all(mode == 'read' for mode in actions))

    def test_hrest3_native_mutations_refuse_before_helper_dispatch(self):
        # A successful receipt, including a new ID, can describe a concurrent user open.
        for outcome in ['concurrent-open', 'same-id-reopen', 'rejected', 'lost-response']:
            with self.subTest(outcome=outcome), tempfile.TemporaryDirectory() as tmp:
                host = self.host(pathlib.Path(tmp))
                host.resident.update(restoreRequired=False, settingsOpened=False)
                host.resident.pop('settingsWindowId', None)
                host.guard_mute = lambda: None
                actions = []
                visible = [False]
                def io(args):
                    mode = args[2]
                    actions.append(mode)
                    if mode == 'open': visible[0] = True  # Concurrent user's post-check lifecycle.
                    if mode == 'close': visible[0] = False
                    if mode != 'read':
                        if outcome == 'rejected': raise subprocess.CalledProcessError(2, args)
                        if outcome == 'lost-response': raise subprocess.TimeoutExpired(args, 15)
                    return json.dumps(dict(pid=100, action=mode, settingsWindowId=88 if visible[0] else None,
                        openedSettingsWindowId=88, nodes=[] if not visible[0] else
                        [dict(role='AXWindow', title='VoiceBar Settings')], screenWindows=[]))
                host.run = io  # Actual settings/settings_state/ax; no helper execution.
                with self.assertRaisesRegex(RuntimeError, 'ownership NOT_PROVEN'):
                    host.settings(True)
                self.assertEqual(actions, ['read'])
                for mode in ['open', 'close', 'hide', 'show']:
                    with self.assertRaisesRegex(RuntimeError, 'ownership NOT_PROVEN'): host.ax(mode)
                self.assertEqual(actions, ['read'])
                self.assertFalse(host.resident.get('settingsOpened'))
                self.assertNotIn('settingsWindowId', host.resident)

    def test_hrest3_same_id_is_not_a_lifecycle_lease(self):
        for boundary in ['absent', 'close-ack-read-gap', 'concurrent-close-reopen']:
            with self.subTest(boundary=boundary), tempfile.TemporaryDirectory() as tmp:
                host = self.host(pathlib.Path(tmp))
                host.guard_mute = lambda: None
                actions = []
                def io(args):
                    mode = args[2]
                    actions.append(mode)
                    if mode == 'close' and boundary == 'close-ack-read-gap':
                        # Own close ACK says absent; the user reopens ID77 before next read.
                        return json.dumps(dict(pid=100, action=mode, nodes=[], screenWindows=[]))
                    return json.dumps(dict(pid=100, action=args[2], settingsWindowId=77,
                        nodes=[] if boundary == 'absent' else
                        [dict(role='AXWindow', title='VoiceBar Settings')], screenWindows=[]))
                host.run = io
                if boundary == 'absent':
                    self.assertFalse(host.settings_state())
                else:
                    # Same physical ID may belong to a new user lifecycle; no OS invariant assumed.
                    with self.assertRaises(RuntimeError): host.settings(False)
                    with self.assertRaises(RuntimeError): host.restore_resident()
                self.assertNotIn('settingsWindowId', host.resident)
                self.assertFalse(host.resident['settingsOpened'])
                self.assertTrue(all(mode == 'read' for mode in actions))

    def test_hrest3_lost_open_obligation_survives_noop_cleanup(self):
        for phase in ['prepare', 'restore']:
            for evidence in ['visible', 'absent', 'unreadable']:
                with self.subTest(phase=phase, evidence=evidence), tempfile.TemporaryDirectory() as tmp:
                    host = self.host(pathlib.Path(tmp))
                    # Retained state at a possibly-applied dispatch, before a lost response.
                    host.resident.update(restoreRequired=phase == 'restore', settingsOpened=False,
                        settingsRestoreRequired=True, settingsActionPending='open', restored=False)
                    host.resident.pop('settingsWindowId', None)
                    host.save_resident()
                    host.guard_mute = lambda: None
                    actions = []
                    def io(args):
                        actions.append(args[2])
                        if evidence == 'unreadable': raise RuntimeError('AX unavailable')
                        return json.dumps(dict(pid=100, action=args[2], screenWindows=[],
                            nodes=[dict(role='AXWindow', title='VoiceBar Settings')]
                            if evidence == 'visible' else []))
                    host.run = io
                    host.process_rows = lambda: {}
                    self.assertTrue(host.stop())  # No runner: independent no-op cleanup succeeds.
                    for _ in range(2):
                        with self.assertRaises(RuntimeError): host.restore_resident()
                        saved = json.loads((host.output / 'resident-visibility.json').read_text())
                        self.assertTrue(saved['settingsRestoreRequired'])
                        self.assertEqual(saved['settingsActionPending'], 'open')
                        self.assertFalse(saved['restored'])
                    self.assertTrue(all(mode == 'read' for mode in actions))
                    host.prepare_resident = lambda: None
                    host.start = lambda: (_ for _ in ()).throw(RuntimeError('synthetic abort'))
                    host.muted = lambda: True
                    host.set_mute = lambda value: None
                    self.assertNotEqual(self.module().supervise(host), 0)
                    receipt = json.loads((host.output / 'operator-state.json').read_text())
                    self.assertTrue(receipt['ownedTerminationProven'])
                    self.assertTrue(any('restore_resident:' in e for e in receipt['cleanupErrors']))
                    self.assertTrue(host.resident['settingsRestoreRequired'])

    def test_hrest3_prepare_never_dispatches_possibly_applied_open(self):
        with tempfile.TemporaryDirectory() as tmp:
            host = self.host(pathlib.Path(tmp))
            actions, before_open = [], []
            host.guard_mute = lambda: None
            host.process_rows = lambda: {100: (1, '/Applications/VoiceBar.app/Contents/MacOS/VoiceBar')}
            def io(args):
                if len(args) == 1: return json.dumps(dict(axTrusted=True, prompts=[]))
                mode = args[2]
                actions.append(mode)
                if mode == 'open':
                    before_open.append(json.loads((host.output / 'resident-visibility.json').read_text()))
                    raise subprocess.TimeoutExpired(args, 15)  # Press applied, response lost.
                return json.dumps(dict(pid=100, action=mode, nodes=[], screenWindows=[]))
            host.run = io
            with self.assertRaises(RuntimeError): host.prepare_resident()
            self.assertEqual(actions, ['read'])
            self.assertFalse(before_open)  # No possibly-applied action needs a new obligation.
            self.assertFalse(host.runner_launch_attempted)
            source = (ROOT / 'scripts/voicebar-ui-e2e-resident.swift').read_text()
            self.assertLess(source.index('guard mode=="read"'), source.index('AXIsProcessTrusted()'))
            self.assertNotIn('AXUIElementPerformAction', source)
            self.assertNotIn('resident.activate', source)

    def test_open_requires_positive_helper_provenance_not_intent(self):
        for outcome in ['rejected', 'timeout', 'missing-proof', 'mismatched-proof', 'success']:
            with self.subTest(outcome=outcome), tempfile.TemporaryDirectory() as tmp:
                host = self.host(pathlib.Path(tmp))
                host.resident.update(settingsOpened=False)
                host.resident.pop('settingsWindowId', None)
                state = dict(opened=False, actions=[])
                host.guard_mute = lambda: None
                def io(args):
                    mode = args[2]
                    state['actions'].append(mode)
                    if mode == 'open':
                        state['opened'] = True  # User interleaves before helper precheck, or applied open.
                        if outcome == 'rejected':
                            raise subprocess.CalledProcessError(2, args, stderr='Settings already open')
                        if outcome == 'timeout': raise subprocess.TimeoutExpired(args, 15)
                    if mode == 'close': state['opened'] = False
                    window_id = 88 if state['opened'] else None
                    result = dict(pid=100, action=mode, settingsWindowId=window_id,
                                  nodes=[dict(role='AXWindow', title='VoiceBar Settings')] if window_id else [])
                    if mode == 'open' and outcome != 'missing-proof':
                        result['openedSettingsWindowId'] = 99 if outcome == 'mismatched-proof' else window_id
                    return json.dumps(result)
                host.run = io  # Real settings/settings_state/ax, only native I/O injected.
                with self.assertRaisesRegex(RuntimeError, 'ownership NOT_PROVEN'): host.settings(True)
                self.assertFalse(host.resident.get('settingsOpened'))
                self.assertNotIn('settingsWindowId', host.resident)
                self.assertFalse(state['opened'])
                self.assertEqual(state['actions'], ['read'])  # None of the receipts is requested.

    def test_parent_death_before_scan_never_proves_launch_completeness(self):
        for initial_muted in [False, True]:
            for exit_code in [-9, 0]:
                with self.subTest(initial_muted=initial_muted, exit_code=exit_code), tempfile.TemporaryDirectory() as tmp:
                    host = self.host(pathlib.Path(tmp))
                    class Child:
                        pid = 200
                        def poll(self): return exit_code
                    host.child = Child()
                    # Non-QA capture/xcodebuild reparented before the first PPID scan.
                    orphan = dict(started='child-start', cmd='/fixture/capture', parent=1, state='S')
                    host.owned = {200: dict(started='runner-start', cmd='python', kind='runner')}
                    host.process_rows = lambda: {201: (1, orphan['cmd'])}
                    host.process_state = lambda pid: orphan if pid == 201 else None
                    mute, writes = [initial_muted], []
                    host.muted = lambda: mute[0]
                    def set_mute(value): mute[0] = value; writes.append(value)
                    host.set_mute = set_mute
                    host.prepare_resident = host.start = host.check = host.restore_resident = lambda: None
                    host.export = lambda: 0
                    host.save = lambda receipt: setattr(host, 'receipt', dict(receipt))
                    with patch('os.kill') as kill:
                        self.assertNotEqual(self.module().supervise(host), 0)
                        kill.assert_not_called()
                    self.assertNotIn(201, host.owned)
                    self.assertFalse(host.receipt['ownedTerminationProven'])
                    self.assertTrue(host.receipt['muteRetained'])
                    self.assertFalse(host.receipt['muteRestored'])
                    self.assertTrue(all(writes))

    def test_launch_attempt_without_returned_handle_retains_mute(self):
        with tempfile.TemporaryDirectory() as tmp:
            host = self.host(pathlib.Path(tmp))
            host.resident.update(settingsOpened=False)
            self.ax_fixture(host)
            host.preconditions = lambda: True
            host.check = host.guard_mute = lambda: None
            host.process_rows = lambda: {}
            with patch('subprocess.run'), patch('subprocess.Popen', side_effect=RuntimeError('launch response lost')):
                with self.assertRaisesRegex(RuntimeError, 'launch response lost'): host.start()
            self.assertFalse(host.stop())
            self.assertIn('Launch completeness NOT_PROVEN', str(host.shutdown))

    def test_graceful_runner_cleanup_keeps_unknown_launch_proof_closed(self):
        with tempfile.TemporaryDirectory() as tmp:
            host = self.host(pathlib.Path(tmp))
            live = {200: dict(started='runner-start', cmd='runner', parent=1, state='S')}
            class Child:
                pid = 200
                def poll(self): return None if 200 in live else 0
            host.child = Child()
            host.owned = {200: dict(live[200], kind='runner')}
            host.process_rows = lambda: {pid: (s['parent'], s['cmd']) for pid, s in live.items()}
            host.process_state = lambda pid: live.get(pid)
            host.guard_mute = lambda: None
            host.shutdown_wait = lambda seconds: None
            signals = []
            def kill(pid, sig):
                signals.append((pid, sig))
                live.pop(pid)
                if pid == 200:  # Late known QA remains independently cleaned.
                    expected = str((host.sandbox / 'VoiceBarQA.app/Contents/MacOS/VoiceBar').resolve())
                    live[202] = dict(started='qa-start', cmd=expected, parent=1, state='S')
            with patch('os.kill', side_effect=kill): self.assertFalse(host.stop())
            self.assertEqual(signals[0], (200, self.module().signal.SIGINT))
            self.assertEqual({pid for pid, _ in signals}, {200, 202})
            self.assertFalse(live)

    def test_daemon_identity_failure_keeps_restore_flags_recoverable(self):
        for failure in ['mismatch', 'unreadable']:
            with self.subTest(failure=failure), tempfile.TemporaryDirectory() as tmp:
                host = self.host(pathlib.Path(tmp))
                host.resident.update(daemonPid=101, daemonStarted='daemon-start')
                state = self.ax_fixture(host)
                def identity(pid):
                    if pid == 101:
                        if failure == 'unreadable': raise RuntimeError('identity unreadable')
                        return 'changed'
                    return 'resident-start'
                host.identity = identity
                with self.assertRaises(RuntimeError): host.restore_resident()
                self.assertTrue(host.resident['restoreRequired'])
                self.assertFalse(host.resident.get('restored', False))
                saved = json.loads((host.output / 'resident-visibility.json').read_text())
                self.assertTrue(saved['restoreRequired'])
                self.assertFalse(saved.get('restored', False))
                host.identity = lambda pid: 'daemon-start' if pid == 101 else 'resident-start'
                host.restore_resident()
                self.assertTrue(host.resident['restored'])
                self.assertEqual(state['actions'].count('show'), 1)

    def host(self, output):
        (output / 'sandbox-path.txt').write_text(str(output / 'sandbox'))
        host = self.module().NativeHost(output, 'gate2246')
        host.resident = dict(pid=100, started='resident-start', restoreRequired=True,
                             settingsOpened=True, settingsWindowId=77, initialHidden=False)
        host.identity = lambda pid: 'resident-start'
        host.guard_mute = lambda: None  # Synthetic tests must never query/change host audio.
        # Permission helper contract (exit code, parsed JSON) is driven for real in its own test.
        host.permissions = lambda: (0, dict(axTrusted=True, prompts=[]))
        host.resident['initialSurface'] = [dict(bounds=dict(X=500, Y=0, Width=200, Height=32), layer=25)]
        return host

    def ax_fixture(self, host, *, surface=True, timeout=None):
        # Hypothetical owned UI adapter for downstream restoration invariants only.
        # NativeHost settings/settings_state/ax are tested separately above and refuse.
        state = dict(settings=host.resident['settingsOpened'], hidden=True, actions=[],
                     phase='initial', events=[])
        def ax(mode):
            state['actions'].append(mode)
            if mode == 'open': state['settings'] = True
            if mode == 'close':
                state['settings'] = False
                state['phase'] = 'closed-awaiting-observation'
                state['events'].append('close-applied')
            if mode == 'read' and state['phase'] == 'closed-awaiting-observation':
                state['phase'] = 'close-observed'
                state['events'].append('post-close-read')
            elif mode == 'read' and state['phase'] == 'close-observed':
                state['phase'] = 'final-surface-read'
                state['events'].append('final-surface-read')
            if mode == 'show': state['hidden'] = False
            if mode == timeout:
                raise subprocess.TimeoutExpired(mode, 15)
            nodes = []
            if state['settings']:
                nodes = [dict(role='AXWindow', title='VoiceBar Settings'),
                         dict(title='Show VoiceBar' if state['hidden'] else 'Hide VoiceBar for 1 hour')]
            return dict(pid=100, action=mode, openedSettingsWindowId=77 if mode == 'open' else None,
                        nodes=nodes, settingsWindowId=77 if state['settings'] else None, screenWindows=(host.resident['initialSurface']
                        if surface and not state['settings'] and not state['hidden'] else []))
        host.ax = ax
        def settings_state():
            result = host.ax('read')
            return any(n.get('role') == 'AXWindow' and n.get('title') == 'VoiceBar Settings'
                       for n in result['nodes'])
        def settings(opened):
            if settings_state() != opened:
                lost_response = None
                try:
                    host.ax('open' if opened else 'close')
                except subprocess.TimeoutExpired as error:
                    lost_response = error
                # A dispatch response/cache is not observation of the applied lifecycle.
                if settings_state() != opened:
                    if lost_response is not None: raise lost_response
                    raise RuntimeError('Hypothetical Settings transition unconfirmed')
            host.resident['settingsOpened'] = opened
            if opened: host.resident['settingsWindowId'] = 77
            else: host.resident.pop('settingsWindowId', None)
            host.save_resident()
        host.settings = settings
        host.settings_state = settings_state
        return state

    def test_hrest3t_adapter_observes_close_before_final_surface(self):
        for timeout in [None, 'close']:
            with self.subTest(timeout=timeout), tempfile.TemporaryDirectory() as tmp:
                host = self.host(pathlib.Path(tmp))
                state = self.ax_fixture(host, timeout=timeout)
                host.settings(False)
                self.assertEqual(state['actions'], ['read', 'close', 'read'])
                self.assertFalse(host.resident['settingsOpened'])
                self.assertNotIn('settingsWindowId', host.resident)
                final = host.ax('read')
                self.assertFalse(final['nodes'])
                self.assertEqual(state['events'],
                                 ['close-applied', 'post-close-read', 'final-surface-read'])

    def test_hrest3t_adapter_rejects_cache_only_close_proof(self):
        for timeout in [None, 'close']:
            with self.subTest(timeout=timeout), tempfile.TemporaryDirectory() as tmp:
                host = self.host(pathlib.Path(tmp))
                state = self.ax_fixture(host, timeout=timeout)
                original = host.ax
                def ax(mode):
                    result = original(mode)
                    if mode == 'read' and not state['settings']:
                        result['nodes'] = [dict(role='AXWindow', title='VoiceBar Settings')]
                    return result
                host.ax = ax
                with self.assertRaises(Exception): host.settings(False)
                self.assertTrue(host.resident['settingsOpened'])
                self.assertEqual(host.resident['settingsWindowId'], 77)
                self.assertEqual(state['actions'], ['read', 'close', 'read'])

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
                def ax(mode):
                    if mode == 'close' and failure in ['failed', 'timeout']:
                        if failure == 'timeout': raise subprocess.TimeoutExpired(mode, 15)
                        raise RuntimeError('Close rejected')
                    # User reopen occurs AFTER close reconciliation and BEFORE final proof.
                    # Change the whole synthetic lifecycle, including ID and surface evidence.
                    if mode == 'read' and failure == 'reopened' and state['phase'] == 'close-observed':
                        state.update(settings=True, phase='user-reopened')
                        state['events'].append('user-reopened')
                    result = original(mode)
                    if mode == 'read' and not state['settings']:
                        if failure == 'unreadable': raise RuntimeError('AX evidence unavailable')
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
                    with self.assertRaisesRegex(Exception, 'Settings reopened' if failure == 'reopened' else '.*'):
                        host.restore_resident()
                    self.assertTrue(host.resident['restoreRequired'])
                    self.assertFalse(host.resident.get('restored', False))
                    if failure == 'reopened':
                        self.assertEqual(state['events'], ['close-applied', 'post-close-read', 'user-reopened'])
                        self.assertTrue(state['settings'])
                        self.assertEqual(state['actions'].count('close'), 1)  # No second/user close.
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

    def test_empty_failed_ps_is_not_termination_proof_without_esrch(self):
        with tempfile.TemporaryDirectory() as tmp:
            host = self.host(pathlib.Path(tmp))
            host.run = lambda args: (_ for _ in ()).throw(subprocess.CalledProcessError(1, args, output=''))
            with patch('os.kill', return_value=None):
                with self.assertRaisesRegex(RuntimeError, 'identity unreadable'): host.process_state(200)
            with patch('os.kill', side_effect=ProcessLookupError):
                self.assertIsNone(host.process_state(200))

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

    def test_notch_idle_label_is_positive_idle_and_notch_recording_blocks(self):
        # run-03: resident 05bcc0a2 exposes only the notch group, labelled exactly 'VoiceBar'
        # when idle (VoiceBarNotchContract.accessibilityLabel(for: .idle)).
        module = self.module()
        self.assertTrue(module.safe_to_hide([], [], ['VoiceBar']))
        for labels in [['VoiceBar recording'], ['VoiceBar', 'VoiceBar recording'], ['VoiceBar launcher'],
                       ['VoiceBar status'], ['VoiceBar teleprompter'], ['VoiceBar history'], ['VoiceBar QA']]:
            self.assertFalse(module.safe_to_hide([], [], labels), labels)
        self.assertFalse(module.safe_to_hide(['rec'], [], ['VoiceBar']))
        self.assertFalse(module.safe_to_hide([], ['voicelayer-session-x.lock'], ['VoiceBar']))

    def test_unsafe_reasons_name_every_failing_check_with_observed_values(self):
        module = self.module()
        self.assertEqual(module.unsafe_reasons([], [], ['VoiceBar']), [])
        reasons = module.unsafe_reasons([4242], ['voicelayer-session-a.lock'], ['VoiceBar recording'])
        text = '\n'.join(reasons)
        for observed in ['4242', 'voicelayer-session-a.lock', 'VoiceBar recording']:
            self.assertIn(observed, text)
        self.assertEqual(len(reasons), 3)
        self.assertIn("'Status unreadable'", '\n'.join(module.unsafe_reasons([], [], ['Status unreadable'])))
        self.assertEqual(len(module.unsafe_reasons([], [], [])), 1)

    def test_failing_preflight_logs_observed_values_to_stderr(self):
        import contextlib
        import io
        module = self.module()
        with tempfile.TemporaryDirectory() as tmp:
            output = pathlib.Path(tmp)
            (output / 'sandbox-path.txt').write_text(str(output / 'sandbox'))
            host = module.NativeHost(output, 'gate2246')
            host.resident = dict(pid=100, started='start')
            host.identity = lambda pid: 'start'
            host.run = lambda args: 'bun src/mcp-server-daemon.ts'
            host.ax = lambda mode: dict(nodes=[dict(role='AXGroup', description='Status unreadable')])
            host.process_rows = lambda: {100: (1, '/Applications/VoiceBar.app/Contents/MacOS/VoiceBar'),
                                         101: (100, 'bun')}
            err = io.StringIO()
            with patch.object(pathlib.Path, 'glob', return_value=[]), contextlib.redirect_stderr(err):
                self.assertFalse(host.preconditions())
            self.assertIn('Status unreadable', err.getvalue())
            self.assertIn('precondition', err.getvalue())
            # No daemon child: also logged, never a silent False.
            host.process_rows = lambda: {100: (1, '/Applications/VoiceBar.app/Contents/MacOS/VoiceBar')}
            err = io.StringIO()
            with contextlib.redirect_stderr(err):
                self.assertFalse(host.preconditions())
            self.assertIn('daemon', err.getvalue())
            self.assertIn('[]', err.getvalue())

    def stub_permissions(self, output, payload, code):
        helper = output / 'voicebar-ui-e2e-permissions'
        helper.write_text('#!/bin/sh\nprintf %s ' + repr(payload) + '\nexit ' + str(code) + '\n')
        helper.chmod(0o755)

    def test_permission_helper_exit_2_is_parsed_recorded_then_stops(self):
        # The real helper prints its JSON and exits 2 on a prompt; the real run() must not lose it.
        module = self.module()
        prompt = json.dumps(dict(axTrusted=True, prompts=[dict(owner='com.apple.UserNotificationCenter',
                                                              labels=['Allow'])]))
        with tempfile.TemporaryDirectory() as tmp:
            output = pathlib.Path(tmp)
            (output / 'sandbox-path.txt').write_text(str(output / 'sandbox'))
            self.stub_permissions(output, prompt, 2)
            host = module.NativeHost(output, 'gate2246')
            with self.assertRaises(RuntimeError) as stop:
                host.prepare_resident()
            self.assertIn('STOP', str(stop.exception))
            self.assertIn('UserNotificationCenter', str(stop.exception))
            self.assertEqual(host.checks[-1]['permissionsExit'], 2)
            self.assertEqual(host.checks[-1]['permissions']['prompts'][0]['labels'], ['Allow'])
            host.collect_owned = lambda: None
            host.muted = lambda: True
            with self.assertRaises(RuntimeError) as stop:
                host.check()
            self.assertIn('STOP', str(stop.exception))
            self.assertEqual(host.checks[-1]['permissions']['axTrusted'], True)
            self.assertIn('UserNotificationCenter', (output / 'supervisor-preflight.log').read_text())
            self.stub_permissions(output, 'not json', 2)
            with self.assertRaises(RuntimeError) as unreadable:
                host.prepare_resident()
            self.assertIn('exit 2', str(unreadable.exception))
            self.assertIn('not json', str(unreadable.exception))

    def test_resident_count_failure_records_count_and_pids(self):
        module = self.module()
        with tempfile.TemporaryDirectory() as tmp:
            output = pathlib.Path(tmp)
            (output / 'sandbox-path.txt').write_text(str(output / 'sandbox'))
            self.stub_permissions(output, json.dumps(dict(axTrusted=True, prompts=[])), 0)
            host = module.NativeHost(output, 'gate2246')
            resident = '/Applications/VoiceBar.app/Contents/MacOS/VoiceBar'
            host.process_rows = lambda: {200: (1, resident), 300: (1, resident)}
            with self.assertRaises(RuntimeError) as error:
                host.prepare_resident()
            self.assertIn('[200, 300]', str(error.exception))
            self.assertEqual(host.preflight['residentPids'], [200, 300])
            self.assertEqual(host.preflight['residentCount'], 2)
            receipt = {}
            host.save(receipt)
            self.assertEqual(json.loads((output / 'operator-state.json').read_text())['preflight']['residentCount'], 2)

    def test_daemon_count_recorded_on_every_attempt_with_commands(self):
        import contextlib
        import io
        module = self.module()
        with tempfile.TemporaryDirectory() as tmp:
            output = pathlib.Path(tmp)
            (output / 'sandbox-path.txt').write_text(str(output / 'sandbox'))
            host = module.NativeHost(output, 'gate2246')
            host.resident = dict(pid=100, started='start')
            host.identity = lambda pid: 'start'
            host.run = lambda args: 'bun src/mcp-server-daemon.ts'
            host.process_rows = lambda: {100: (1, '/Applications/VoiceBar.app/Contents/MacOS/VoiceBar'),
                                         101: (100, 'bun'), 102: (100, 'bun')}
            err = io.StringIO()
            with contextlib.redirect_stderr(err):
                self.assertFalse(host.preconditions())
            attempt = host.resident['preconditions'][-1]
            self.assertEqual((attempt['daemonCount'], attempt['daemonPids'], attempt['safe']), (2, [101, 102], False))
            self.assertIn('101', err.getvalue())
            self.assertIn('mcp-server-daemon.ts', err.getvalue())
            # A changed daemon identity is recorded before the raise.
            host.process_rows = lambda: {100: (1, '/Applications/VoiceBar.app/Contents/MacOS/VoiceBar'),
                                         103: (100, 'bun')}
            host.resident.update(daemonPid=101, daemonStarted='start')
            with self.assertRaises(RuntimeError):
                host.preconditions()
            self.assertEqual(host.resident['preconditions'][-1]['daemonPids'], [103])
            saved = json.loads((output / 'resident-visibility.json').read_text())
            self.assertEqual(saved['preconditions'][-1]['daemonCount'], 1)

    def test_short_lived_resident_child_rechecks_instead_of_bare_error(self):
        import contextlib
        import io
        module = self.module()
        with tempfile.TemporaryDirectory() as tmp:
            output = pathlib.Path(tmp)
            (output / 'sandbox-path.txt').write_text(str(output / 'sandbox'))
            host = module.NativeHost(output, 'gate2246')
            gone = 99999
            while True:
                try:
                    os.kill(gone, 0); gone += 1
                except ProcessLookupError:
                    break
                except PermissionError:
                    gone += 1
            def run(args):
                if args[:2] == ['ps', '-p'] and args[2] == str(gone):
                    raise subprocess.CalledProcessError(1, args, output='')
                return 'bun src/mcp-server-daemon.ts'
            host.resident = dict(pid=100, started='start')
            host.identity = lambda pid: 'start'
            host.run = run
            host.ax = lambda mode: dict(nodes=[dict(role='AXGroup', description='VoiceBar')])
            host.process_rows = lambda: {100: (1, '/Applications/VoiceBar.app/Contents/MacOS/VoiceBar'),
                                         101: (100, 'bun'), gone: (100, '/usr/bin/true')}
            err = io.StringIO()
            with patch.object(pathlib.Path, 'glob', return_value=[]), contextlib.redirect_stderr(err):
                self.assertTrue(host.preconditions())
            self.assertIn(str(gone), err.getvalue())
            # A still-live PID whose args are unreadable raises with context, not a bare repr.
            live = os.getpid()
            host.process_rows = lambda: {100: (1, '/Applications/VoiceBar.app/Contents/MacOS/VoiceBar'),
                                         live: (100, 'python3')}
            host.run = lambda args: (_ for _ in ()).throw(subprocess.CalledProcessError(1, args, output=''))
            with self.assertRaises(RuntimeError) as error:
                host.preconditions()
            self.assertIn(str(live), str(error.exception))
            self.assertIn('still exists', str(error.exception))

    def test_remember_race_errors_name_pid_parent_and_observed_state(self):
        module = self.module()
        with tempfile.TemporaryDirectory() as tmp:
            output = pathlib.Path(tmp)
            host = self.host(output)
            host.owned = {500: dict(started='s', cmd='runner', state='S', parent=1, kind='runner')}
            host.process_state = lambda pid: (None if pid == 500 else
                                              dict(started='t', cmd='child', state='S', parent=500))
            with self.assertRaises(RuntimeError) as error:
                host.remember(600, 'child', 'child', 500)
            for observed in ['600', '500', 'parentAlive']:
                self.assertIn(observed, str(error.exception))
            host.process_state = lambda pid: dict(started='t', cmd='other', state='S', parent=1)
            with self.assertRaises(RuntimeError) as error:
                host.remember(600, 'qa', 'expected-cmd')
            self.assertIn('other', str(error.exception))
            self.assertIn('expected-cmd', str(error.exception))

    def test_supervise_failure_prints_summary_with_receipt_path(self):
        import contextlib
        import io
        module = self.module()
        class Host:
            output = pathlib.Path('/fixture/out')
            def muted(self): return True
            def set_mute(self, value): pass
            def guard_mute(self): pass
            def prepare_resident(self): raise RuntimeError('fixture refusal')
            def stop(self): return True
            def restore_resident(self): pass
            def save(self, receipt): pass
        err = io.StringIO()
        with contextlib.redirect_stderr(err):
            module.supervise(Host())
        line = [x for x in err.getvalue().splitlines() if 'FAILED' in x]
        self.assertEqual(len(line), 1)
        self.assertIn('fixture refusal', line[0])
        self.assertIn('/fixture/out/operator-state.json', line[0])

    def test_supervise_failure_writes_error_to_stderr(self):
        import contextlib
        import io
        module = self.module()
        class Host:
            def muted(self): return True
            def set_mute(self, value): pass
            def guard_mute(self): pass
            def prepare_resident(self): raise RuntimeError('fixture precondition failure')
            def stop(self): return True
            def restore_resident(self): pass
            def save(self, receipt): pass
        err = io.StringIO()
        with contextlib.redirect_stderr(err):
            self.assertEqual(module.supervise(Host()), 1)
        self.assertIn('fixture precondition failure', err.getvalue())

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
