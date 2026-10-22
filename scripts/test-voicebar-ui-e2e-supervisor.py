import importlib.util
import contextlib
import io
import hashlib
import hmac
import json
import os
import pathlib
import plistlib
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
from types import SimpleNamespace

ROOT = pathlib.Path(__file__).resolve().parent.parent

class SupervisorTests(unittest.TestCase):
    def hotkey_table(self, parameters, enabled=True):
        return plistlib.dumps({'AppleSymbolicHotKeys': {
            '200': dict(enabled=enabled, value=dict(type='standard', parameters=parameters))}})

    def test_enabled_hotkey_domains_refuse_before_matching(self):
        module = self.module()
        cmd = module.HOTKEY_MODIFIERS['command']
        sentinel = module.HOTKEY_SENTINEL
        # Each field is invalid independently, even when the other field would
        # collide or is a sentinel. No modifier combination makes it unassigned.
        invalid_pairs = [(1114112, 99999)]
        for character in [-1, 0xD800, 0xDBFF, 0xDC00, 0xDFFF, 0x110000, 1 << 32]:
            invalid_pairs.extend([(character, 0), (character, sentinel)])
        for keycode in [-1, 0x10000, 99999, 1 << 32]:
            invalid_pairs.extend([(ord('a'), keycode), (sentinel, keycode)])
        for character, keycode in invalid_pairs:
            for mask in [0, cmd, module.HOTKEY_CAPS_LOCK, cmd | module.HOTKEY_CAPS_LOCK]:
                with self.subTest(character=character, keycode=keycode, mask=mask):
                    with self.assertRaisesRegex(module.HotkeyCollision, '200.*NOT_PROVEN'):
                        module.symbolic_hotkey_collisions(
                            self.hotkey_table([character, keycode, mask]), [('a', 0, ('command',))])

    def test_valid_hotkey_domains_sentinels_and_modifiers_are_retained(self):
        module = self.module()
        cmd = module.HOTKEY_MODIFIERS['command']
        caps = module.HOTKEY_CAPS_LOCK
        sentinel = module.HOTKEY_SENTINEL
        cases = [([ord('a'), 0, cmd], [200]), ([ord('A'), 0, cmd | caps], [200]),
                 ([sentinel, 0, cmd], [200]), ([ord('a'), sentinel, cmd], [200]),
                 ([ord('a'), sentinel, cmd | caps], [200]),
                 ([ord('b'), 11, cmd], []), ([sentinel, sentinel, 0], []),
                 ([sentinel, sentinel, caps], [])]
        for modifier in module.HOTKEY_MODIFIERS.values():
            if modifier != cmd:
                cases.append(([ord('a'), 0, cmd | modifier], []))
            with self.subTest(unassigned_modifier=modifier):
                with self.assertRaisesRegex(module.HotkeyCollision, 'NOT_PROVEN'):
                    module.symbolic_hotkey_collisions(
                        self.hotkey_table([sentinel, sentinel, modifier | caps]), [('a', 0, ('command',))])
        for parameters, expected in cases:
            with self.subTest(parameters=parameters):
                self.assertEqual(module.symbolic_hotkey_collisions(
                    self.hotkey_table(parameters), [('a', 0, ('command',))]), expected)
        # Scalar and uint16 edges remain evaluable, including codes above 127.
        for character in [0, 0xD7FF, 0xE000, 0xFFFE, 0x10000, 0x10FFFF]:
            for keycode in [0, 128, 0xFFFE, sentinel]:
                with self.subTest(character=character, keycode=keycode):
                    self.assertEqual(module.symbolic_hotkey_collisions(
                        self.hotkey_table([character, keycode, cmd]), [('b', 11, ('command',))]), [])
        for parameters, expected in [([sentinel, 12, 0], [200]),
                                     ([ord('a'), sentinel, caps], [200]),
                                     ([ord('a'), sentinel, cmd], [])]:
            with self.subTest(text_entry=parameters):
                self.assertEqual(module.symbolic_hotkey_collisions(
                    self.hotkey_table(parameters), [module.TEXT_ENTRY]), expected)
        self.assertEqual(module.symbolic_hotkey_collisions(
            self.hotkey_table([1114112, 99999, cmd], enabled=False), [('a', 0, ('command',))]), [])
        self.assertEqual(module.symbolic_hotkey_collisions(
            self.hotkey_table([0x10400, sentinel, cmd]), [(chr(0x10428), None, ('command',))]), [200])
        for character, keycode in [(sentinel, sentinel), (sentinel, 0), (ord('a'), sentinel)]:
            for mask in [-1, cmd | (1 << 30)]:
                with self.subTest(character=character, keycode=keycode, mask=mask):
                    with self.assertRaisesRegex(module.HotkeyCollision, 'NOT_PROVEN'):
                        module.symbolic_hotkey_collisions(
                            self.hotkey_table([character, keycode, mask]), [('a', 0, ('command',))])

    def test_native_hotkey_preflight_propagates_invalid_domain_refusal(self):
        module = self.module()
        host = module.NativeHost.__new__(module.NativeHost)
        host.scenario, host.preflight = 'full', {}
        host.symbolic_hotkeys = lambda: SimpleNamespace(returncode=0, stdout=self.hotkey_table(
            [1114112, 99999, module.HOTKEY_MODIFIERS['command']]))
        with self.assertRaisesRegex(module.HotkeyCollision, 'NOT_PROVEN'):
            host.refuse_hotkey_collisions()
        self.assertNotIn('symbolicHotkeyCollisions', host.preflight, 'invalid table must not record safe []')

    def test_redaction_uses_one_memory_only_32_byte_hmac_key_per_run(self):
        import secrets
        key = secrets.token_bytes(32)
        with patch.object(secrets, 'token_bytes', return_value=key) as generate:
            module = self.module()
        generate.assert_called_once_with(32)
        text = 'hello'
        tag = hmac.new(key, text.encode(), hashlib.sha256).hexdigest()[:8]
        expected = '<redacted len=5 hmac-sha256=%s>' % tag
        self.assertEqual(module.redacted(text), expected)
        self.assertEqual(module.redacted(text), expected)
        self.assertNotEqual(tag, hashlib.sha256(text.encode()).hexdigest()[:8])
        with tempfile.TemporaryDirectory() as tmp:
            output = pathlib.Path(tmp)
            module.note(module.redacted(text), output / 'supervisor-preflight.log')
            (output / 'receipt.json').write_text(json.dumps(module.ax_receipt([
                dict(role='AXStaticText', value=text)])))
            host = module.NativeHost.__new__(module.NativeHost)
            host.output, host.checks, host.shutdown, host.preflight = output, [], [], {}
            host.owned = {}
            host.ownership_races = []
            host.unproven = {}
            host.save(dict(error=module.redacted(text)))
            with patch.object(module, 'SUPERVISOR_LOCK_PATH', self.lock_path(tmp)):
                with module.supervisor_lock():
                    for path in output.rglob('*'):
                        if path.is_file():
                            data = path.read_bytes()
                            for encoded in [key, key.hex().encode(), repr(key).encode()]:
                                self.assertNotIn(encoded, data, path.name)

    def test_redaction_tags_differ_across_supervisor_processes(self):
        script = ('import runpy; m = runpy.run_path(%r); '
                  'print(m["redacted"]("hello"))' %
                  str(ROOT / 'scripts/voicebar-ui-e2e-supervisor.py'))
        tags = [subprocess.check_output([sys.executable, '-c', script], text=True, timeout=10).strip()
                for _ in range(2)]
        self.assertNotEqual(tags[0], tags[1])
        for tag in tags:
            self.assertRegex(tag, r'^<redacted len=5 hmac-sha256=[0-9a-f]{8}>$')

    def lock_path(self, tmp):
        return pathlib.Path(tmp) / ('voicebar-ui-e2e-supervisor-%d.lock' % os.getuid())

    def supervisor_fixture_script(self, tmp):
        # Inject only in this test process, never via a production env override.
        return ('import runpy, sys, pathlib; m = runpy.run_path(%r); '
                'm["main"].__globals__["SUPERVISOR_LOCK_PATH"] = pathlib.Path(%r); ' %
                (str(ROOT / 'scripts/voicebar-ui-e2e-supervisor.py'), str(self.lock_path(tmp))))

    @contextlib.contextmanager
    def locked_supervisor(self, tmp):
        script = self.supervisor_fixture_script(tmp) + (
            'lock = m["supervisor_lock"](); lock.__enter__(); '
            'print("locked", flush=True); sys.stdin.read()')
        process = subprocess.Popen([sys.executable, '-c', script],
                                   env=dict(os.environ, TMPDIR=tmp), stdin=subprocess.PIPE,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            # Bound readiness so a broken fixture cannot hang the test suite.
            import select
            self.assertTrue(select.select([process.stdout], [], [], 10)[0], 'lock helper not ready')
            self.assertEqual(process.stdout.readline().strip(), 'locked')
            yield process
        finally:
            if process.poll() is None:
                process.kill()  # Only this test's own subprocess; exercise kernel lock release.
            process.communicate(timeout=10)

    def test_second_supervisor_refuses_before_native_host_or_mute_access(self):
        with tempfile.TemporaryDirectory() as tmp, self.locked_supervisor(tmp) as owner:
            module = self.module()
            first_output, second_output = pathlib.Path(tmp) / 'one', pathlib.Path(tmp) / 'two'
            first_output.mkdir()
            second_output.mkdir()
            # The first run's output root is independent of the second run's root.
            lock = next(pathlib.Path(tmp).glob('*.lock'))
            owner_record = lock.read_text()
            self.assertEqual(owner_record.strip(), str(owner.pid))
            with patch.object(module, 'SUPERVISOR_LOCK_PATH', self.lock_path(tmp)), \
                    patch.object(module, 'NativeHost') as host, \
                    contextlib.redirect_stderr(io.StringIO()) as err:
                self.assertEqual(module.main([str(first_output)]), 2)
                host.assert_not_called()
            self.assertIn('Another supervisor run is active', err.getvalue())
            script = self.supervisor_fixture_script(tmp) + 'sys.exit(m["main"]([%r]))' % str(second_output)
            result = subprocess.run([sys.executable, '-c', script], env=dict(os.environ, TMPDIR=tmp),
                                    capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 2, result.stderr)
            self.assertIn('Another supervisor run is active', result.stderr)
            self.assertIn('Another supervisor run is active',
                          (second_output / 'supervisor-preflight.log').read_text())
            self.assertEqual(lock.read_text(), owner_record, 'contender rewrote owner PID')
            self.assertIsNone(owner.poll())

    def test_dead_supervisor_lock_is_reclaimed_without_replacing_lockfile(self):
        with tempfile.TemporaryDirectory() as tmp:
            with self.locked_supervisor(tmp) as owner:
                lock = next(pathlib.Path(tmp).glob('*.lock'))
                inode = lock.stat().st_ino
            self.assertIsNotNone(owner.returncode)
            self.assertEqual(lock.read_text().strip(), str(owner.pid))
            module = self.module()
            with patch.object(module, 'SUPERVISOR_LOCK_PATH', self.lock_path(tmp)):
                for _ in range(2):
                    with module.supervisor_lock():
                        self.assertEqual(lock.read_text().strip(), str(os.getpid()))
                        self.assertEqual(lock.stat().st_ino, inode)
                        with self.assertRaisesRegex(RuntimeError, 'Another supervisor run is active'):
                            with module.supervisor_lock():
                                self.fail('overlapping supervisor admitted')

    def test_startup_lock_covers_host_and_supervision_then_releases_on_error(self):
        module = self.module()
        for fail in [False, True]:
            with self.subTest(fail=fail), tempfile.TemporaryDirectory() as tmp:
                def assert_locked(*args):
                    with self.assertRaises(module.SupervisorActiveError):
                        with module.supervisor_lock():
                            self.fail('supervisor lifecycle is unlocked')
                def supervise(host):
                    assert_locked()
                    if fail:
                        raise RuntimeError('synthetic supervisor failure')
                    return 0
                with patch.object(module, 'SUPERVISOR_LOCK_PATH', self.lock_path(tmp)), \
                        patch.object(module, 'NativeHost', side_effect=assert_locked) as host, \
                        patch.object(module, 'supervise', side_effect=supervise) as run, \
                        patch.object(module.signal, 'signal'):
                    if fail:
                        with self.assertRaisesRegex(RuntimeError, 'synthetic supervisor failure'):
                            module.main([tmp])
                    else:
                        self.assertEqual(module.main([tmp]), 0)
                    host.assert_called_once()
                    run.assert_called_once()
                    with module.supervisor_lock():
                        pass

    def test_supervisor_lock_is_shared_across_different_tmpdirs(self):
        with tempfile.TemporaryDirectory() as tmp, self.locked_supervisor(tmp):
            other_tmp = pathlib.Path(tmp) / 'different-tmpdir'
            other_tmp.mkdir()
            script = self.supervisor_fixture_script(tmp) + 'sys.exit(m["main"]([%r]))' % tmp
            result = subprocess.run([sys.executable, '-c', script],
                                    env=dict(os.environ, TMPDIR=str(other_tmp)),
                                    capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 2, result.stderr)
            self.assertIn('Another supervisor run is active', result.stderr)
            # Production path is fixed, with no test/environment override.
            module = self.module()
            self.assertEqual(module.SUPERVISOR_LOCK_PATH,
                             pathlib.Path('/tmp/voicebar-ui-e2e-supervisor-%d.lock' % os.getuid()))

    def test_lock_refusal_with_missing_output_directory_still_exits_two(self):
        module = self.module()
        with tempfile.TemporaryDirectory() as tmp, self.locked_supervisor(tmp):
            with patch.object(module, 'SUPERVISOR_LOCK_PATH', self.lock_path(tmp)), \
                    patch.object(module, 'NativeHost') as native, \
                    contextlib.redirect_stderr(io.StringIO()) as err:
                self.assertEqual(module.main([str(pathlib.Path(tmp) / 'missing' / 'output')]), 2)
                native.assert_not_called()
            self.assertIn('PREFLIGHT_REFUSED', err.getvalue())
            self.assertIn('Another supervisor run is active', err.getvalue())
            self.assertNotIn('Traceback', err.getvalue())

    def test_symlink_lock_is_refused_without_modifying_its_target(self):
        module = self.module()
        with tempfile.TemporaryDirectory() as tmp:
            output = pathlib.Path(tmp)
            target = output / 'preserved.txt'
            target.write_text('preserve this fixture\n')
            lock = self.lock_path(tmp)
            lock.symlink_to(target)
            with patch.object(module, 'SUPERVISOR_LOCK_PATH', lock), \
                    patch.object(module, 'NativeHost') as native, \
                    patch.object(module, 'supervise', return_value=0), \
                    contextlib.redirect_stderr(io.StringIO()) as err:
                self.assertEqual(module.main([tmp]), 2)
                native.assert_not_called()
            self.assertEqual(target.read_text(), 'preserve this fixture\n')
            self.assertTrue(lock.is_symlink())
            self.assertIn('PREFLIGHT_REFUSED', err.getvalue())
            self.assertIn('Cannot open supervisor lock', err.getvalue())

    def test_each_scenario_launch_uses_its_pinned_budget(self):
        module = self.module()
        for scenario, seconds in [('full', 2400), ('focused-338', 2400),
                                  ('gate2246', 600), ('hide1', 300)]:
            with self.subTest(scenario=scenario), tempfile.TemporaryDirectory() as tmp:
                host = self.timeout_host(pathlib.Path(tmp))
                host.scenario = scenario
                host.remember = lambda *args: None
                with patch.object(module.time, 'monotonic', return_value=100), \
                        patch.object(module.subprocess, 'run'), \
                        patch.object(module.subprocess, 'Popen'):
                    try:
                        host.start()
                        self.assertEqual(host.deadline, 100 + seconds)
                    finally:
                        if host.log: host.log.close()

    def test_full_survives_300_seconds_and_stops_at_its_own_deadline(self):
        module = self.module()
        with tempfile.TemporaryDirectory() as tmp:
            host = self.timeout_host(pathlib.Path(tmp))
            host.scenario = 'full'
            host.remember = host.collect_owned = lambda *args: None
            with patch.object(module.time, 'monotonic', return_value=100), \
                    patch.object(module.subprocess, 'run'), \
                    patch.object(module.subprocess, 'Popen'):
                try:
                    host.start()
                finally:
                    if host.log: host.log.close()
            host.child = None  # No real child, permissions, disk or audio I/O.
            host.set_mute(True)
            host.run = lambda args: json.dumps(dict(axTrusted=True, prompts=[]))
            host.check = module.NativeHost.check.__get__(host)
            with patch('shutil.disk_usage', return_value=SimpleNamespace(free=20 * 1024**3)):
                with patch.object(module.time, 'monotonic', return_value=401):
                    host.check()
                with patch.object(module.time, 'monotonic', return_value=2501):
                    with self.assertRaisesRegex(InterruptedError, 'deadline'):
                        host.check()

    def test_exit_codes_and_stdout_verdict_cover_retention_and_real_failures(self):
        module = self.module()
        cases = [('clean-pass', 0, 'PASS'), ('retained-pass', 3, 'PASS'),
                 ('suite', 1, 'FAIL'), ('export', 1, 'FAIL'),
                 ('preflight', 2, 'PREFLIGHT_REFUSED'), ('configure', 2, 'PREFLIGHT_REFUSED'),
                 ('launch', 1, 'FAIL'), ('check', 1, 'FAIL'),
                 ('stop', 1, 'FAIL'), ('restore', 1, 'FAIL'), ('mute', 1, 'FAIL'),
                 ('preflight-cleanup', 1, 'FAIL')]
        for failure, expected, verdict in cases:
            with self.subTest(failure=failure), tempfile.TemporaryDirectory() as tmp:
                host = self.timeout_host(pathlib.Path(tmp))
                def fail(): raise RuntimeError('synthetic ' + failure)
                def start():
                    if failure == 'configure': fail()
                    host.runner_launch_attempted = failure != 'clean-pass'
                    if failure == 'launch': fail()
                host.start = start
                host.poll = lambda: 1 if failure == 'suite' else 0
                host.export = lambda: 1 if failure == 'export' else 0
                if failure in ['preflight', 'preflight-cleanup']: host.prepare_resident = fail
                if failure in ['stop', 'preflight-cleanup']: host.collect_owned = fail
                if failure == 'restore': host.restore_resident = fail
                if failure == 'check': host.check = fail
                if failure == 'mute':
                    original = host.set_mute
                    def set_mute(value):
                        if host.shutdown: fail()
                        original(value)
                    host.set_mute = set_mute
                stdout = io.StringIO()
                with contextlib.redirect_stdout(stdout):
                    result = module.supervise(host)
                receipt = json.loads((host.output / 'operator-state.json').read_text())
                self.assertEqual(result, expected)
                self.assertEqual(receipt['exitCode'], expected)
                self.assertEqual(receipt['verdict'], verdict)
                self.assertIn('verdict=' + verdict, stdout.getvalue())
                self.assertIn('exit=' + str(expected), stdout.getvalue())
                self.assertIn(str(host.output / 'operator-state.json'), stdout.getvalue())
                if failure == 'retained-pass':
                    self.assertFalse(receipt['ownedTerminationProven'])
                    self.assertTrue(receipt['muteRetained'])
                    self.assertFalse(receipt['muteRestored'])
                    self.assertEqual(receipt['cleanupErrors'], [])
                    self.assertIn('Launch completeness NOT_PROVEN', receipt['muteRetentionReason'])
                    self.assertIn('Launch completeness NOT_PROVEN', str(receipt['shutdown']))
                if failure in ['stop', 'preflight-cleanup']:
                    self.assertTrue(receipt['cleanupErrors'])

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
                self.assertEqual(module.supervise(host), 2)
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
            self.assertIn('NOT_PROVEN', receipt['muteRetentionReason'])
            self.assertEqual(receipt['cleanupErrors'], [])

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
            host.export = lambda: actions.append('export') or 0
            class Child:
                pid = 200
                def poll(self): return 0
            with patch.object(module.subprocess, 'run'), patch.object(module.subprocess, 'Popen', return_value=Child()):
                self.assertEqual(module.supervise(host), 3)  # Expected retention, with proof still unknown.
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
                    live[202] = dict(started='9999999999.000000', cmd=expected, parent=1, state='S')
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
        self.hermetic_host_settings(host)
        host.resident = dict(pid=100, started='resident-start', restoreRequired=True,
                             settingsOpened=True, settingsWindowId=77, initialHidden=False)
        host.identity = lambda pid: 'resident-start'
        host.guard_mute = lambda: None  # Synthetic tests must never query/change host audio.
        # The pre-signal kernel birth follows the synthetic process table, never a real PID.
        host.current_birth = lambda pid: (lambda state: state and state['started'])(host.process_state(pid))
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
                    201: dict(started='9999999999.000000', cmd=expected, parent=200, state='S')}
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
                # SUP3: a new start time means the owned process exited; its PID is retired, never re-signalled.
                host.terminate_owned(200, runner=True)
                self.assertEqual(kill.call_count, 1)
            self.assertEqual(host.owned[200]['retired']['reason'], 'pid-reused')

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
            host.kernel_birth = lambda pid: (7, 7)  # Same lifetime still present: no death proof.
            with self.assertRaisesRegex(RuntimeError, 'identity unreadable'): host.process_state(200)
            births = iter([(7, 7), None])  # Kernel ESRCH after the failed ps: proven gone.
            host.kernel_birth = lambda pid: next(births)
            self.assertIsNone(host.process_state(200))

    def module(self):
        path = ROOT / 'scripts/voicebar-ui-e2e-supervisor.py'
        self.assertTrue(path.exists(), 'Committed safety supervisor missing')
        spec = importlib.util.spec_from_file_location('supervisor', path)
        module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
        return module

    def test_native_mute_adapter_only_confirms_shell_guard_state(self):
        module = self.module()
        host = module.NativeHost.__new__(module.NativeHost)
        for muted in [False, True]:
            host.muted = lambda: muted
            with patch.object(module.subprocess, 'run') as run:
                host.set_mute(muted)
                with self.assertRaisesRegex(RuntimeError, 'Shell output-mute guard state unconfirmed'):
                    host.set_mute(not muted)
                run.assert_not_called()

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
        self.assertFalse(module.safe_to_hide([], [], ['Ready. Transcribed on this Mac']))
        self.assertFalse(module.safe_to_hide([], [], ['Hidden until 23:00']))
        events=[]
        class Host:
            def preconditions(self):
                events.append('read'); return len(events)>1
            def wait(self, seconds): events.append(seconds)
        module.wait_until_safe(Host())
        self.assertEqual(events, ['read', 120, 'read'])

    # The run-03 resident 05bcc0a2 AX read, verbatim in shape: the notch state group is the
    # first labelled node (VoiceBarNotchContract.accessibilityLabel(for: .idle) == 'VoiceBar').
    IDLE_TREE = [dict(role='AXWindow', title='', description='', value=''),
                 dict(role='AXGroup', title='', description='', value=''),
                 dict(role='AXGroup', title='', description='VoiceBar', value='')]

    def tree(self, *extra, state='VoiceBar'):
        group = dict(role='AXGroup', title='', description=state, value='')
        return self.IDLE_TREE[:2] + [group] + [dict(role=r, title='', description=d, value='') for r, d in extra]

    def test_notch_idle_state_group_is_positive_idle_structurally(self):
        module = self.module()
        self.assertTrue(module.safe_to_hide([], [], self.IDLE_TREE))
        # Arbitrary text 'VoiceBar' (e.g. a teleprompter word) never qualifies.
        self.assertFalse(module.safe_to_hide([], [], ['VoiceBar']))
        word_first = self.IDLE_TREE[:2] + [dict(role='AXButton', title='', description='VoiceBar', value='')]
        self.assertFalse(module.safe_to_hide([], [], word_first))
        for state in ['VoiceBar recording', 'VoiceBar launcher', 'VoiceBar status', 'VoiceBar teleprompter',
                      'VoiceBar history', 'VoiceBar QA']:
            self.assertFalse(module.safe_to_hide([], [], self.tree(state=state)), state)
        self.assertFalse(module.safe_to_hide(['rec'], [], self.IDLE_TREE))
        self.assertFalse(module.safe_to_hide([], ['voicelayer-session-x.lock'], self.IDLE_TREE))

    def test_busy_evidence_overrides_every_idle_looking_signal(self):
        module = self.module()
        speaking = self.tree(('AXButton', 'Stop speaking'), ('AXButton', 'VoiceBar'), state='VoiceBar teleprompter')
        transcribing = self.tree(('AXButton', 'Cancel transcription'), ('AXStaticText', 'Transcribing'),
                                 state='VoiceBar status')
        self.assertFalse(module.safe_to_hide([], [], speaking))
        self.assertFalse(module.safe_to_hide([], [], transcribing))
        for busy in ['Transcribing', 'Agent speaking', 'Stop speaking', 'Cancel transcription',
                     'VoiceBar teleprompter', 'VoiceBar status', 'VoiceBar recording']:
            self.assertFalse(module.safe_to_hide([], [], [busy]), busy)
            self.assertFalse(module.safe_to_hide([], [], ['Ready', busy]), busy)
            self.assertFalse(module.safe_to_hide([], [], self.tree(('AXStaticText', busy))), busy)
            self.assertTrue(any(busy in r for r in module.unsafe_reasons([], [], self.tree(('AXStaticText', busy))))
                            , busy)

    def hermetic_host_settings(self, host):
        # Synthetic hosts never read the operator's real defaults; GATECAP1 tests drive these directly.
        host.host_settings = lambda: {'com.apple.dock autohide': '0'}
        host.symbolic_hotkeys = lambda: SimpleNamespace(returncode=0, stdout=b'')

    def busy_host(self, output, nodes, children):
        module = self.module()
        (output / 'sandbox-path.txt').write_text(str(output / 'sandbox'))
        host = module.NativeHost(output, 'gate2246')
        self.hermetic_host_settings(host)
        host.resident = dict(pid=100, started='start')
        host.identity = lambda pid: 'start'
        host.run = lambda args: 'bun src/mcp-server-daemon.ts' if args[-1] == 'args=' else ''
        host.ax = lambda mode: dict(nodes=nodes)
        rows = {100: (1, '/Applications/VoiceBar.app/Contents/MacOS/VoiceBar'), 101: (100, 'bun')}
        rows.update({200 + i: (101, cmd) for i, cmd in enumerate(children)})
        host.process_rows = lambda: dict(rows)
        host.child_args = lambda pid: 'bun src/mcp-server-daemon.ts' if pid == 101 else None
        return module, host

    def lock(self, module, age):
        class Lock:
            name = 'voicelayer-session-fixture.lock'
            def stat(self):
                from types import SimpleNamespace
                return SimpleNamespace(st_mtime=module.time.time() - age)
        return Lock()

    def test_real_preconditions_require_idle_group_despite_start_button_or_ready_text(self):
        trees = [[dict(role='AXStaticText', value='Ready')]]
        for state in ['VoiceBar launcher', 'VoiceBar history', 'VoiceBar unknown']:
            trees.append(self.tree(('AXButton', 'Start voice recording'), state=state))
        trees.append(self.tree(('AXButton', 'Start voice recording'),
                               ('AXGroup', 'Re-transcribing stored audio'),
                               ('AXStaticText', 'Re-transcribing…'), state='VoiceBar history'))
        for nodes in trees:
            for age in [None, 400]:
                with self.subTest(nodes=nodes, lock_age=age), tempfile.TemporaryDirectory() as tmp:
                    module, host = self.busy_host(pathlib.Path(tmp), nodes, [])
                    locks = [] if age is None else [self.lock(module, age)]
                    with patch.object(pathlib.Path, 'glob', return_value=locks), contextlib.redirect_stderr(io.StringIO()):
                        self.assertFalse(host.preconditions())

    def test_real_preconditions_refuse_all_unallowlisted_daemon_descendants(self):
        for name in ['whisper-cpp', 'whisper-cli', 'afplay', 'rec', 'sox', 'python3', 'unknown-worker']:
            for age in [None, 400]:
                with self.subTest(child=name, lock_age=age), tempfile.TemporaryDirectory() as tmp:
                    module, host = self.busy_host(pathlib.Path(tmp), self.IDLE_TREE, ['/fixture/' + name])
                    rows = host.process_rows()
                    rows[201] = (200, '/fixture/nested-worker')
                    host.process_rows = lambda: dict(rows)
                    locks = [] if age is None else [self.lock(module, age)]
                    with patch.object(pathlib.Path, 'glob', return_value=locks), contextlib.redirect_stderr(io.StringIO()):
                        self.assertFalse(host.preconditions())
                    saved = json.loads((host.output / 'resident-visibility.json').read_text())
                    self.assertEqual(saved['preconditions'][-1]['capturePids'], [200, 201])

    def test_every_failed_recheck_persists_new_inventory_after_success(self):
        for failure in ['resident-change', 'daemon-change', 'resident-read', 'daemon-read', 'child-read', 'ax-read', 'rows-read']:
            with self.subTest(failure=failure), tempfile.TemporaryDirectory() as tmp:
                module, host = self.busy_host(pathlib.Path(tmp), self.IDLE_TREE, [])
                rows = host.process_rows()
                with patch.object(pathlib.Path, 'glob', return_value=[]), contextlib.redirect_stderr(io.StringIO()):
                    self.assertTrue(host.preconditions())
                    rows[222] = (101, '/usr/bin/afplay')
                    host.process_rows = lambda: dict(rows)
                    def fail(*args): raise RuntimeError('fixture ' + failure)
                    if failure.endswith('-change'):
                        changed = 100 if failure == 'resident-change' else 101
                        host.identity = lambda pid: 'changed' if pid == changed else 'start'
                    elif failure in ['resident-read', 'daemon-read']:
                        unreadable = 100 if failure == 'resident-read' else 101
                        host.identity = lambda pid: fail() if pid == unreadable else 'start'
                    else:
                        setattr(host, {'child-read': 'child_args', 'ax-read': 'ax', 'rows-read': 'process_rows'}[failure], fail)
                    with self.assertRaises(RuntimeError): host.preconditions()
                saved = json.loads((host.output / 'resident-visibility.json').read_text())
                self.assertEqual(len(saved['preconditions']), 2)
                attempt = saved['preconditions'][-1]
                self.assertFalse(attempt['safe'])
                self.assertTrue(attempt['error'])
                if failure != 'rows-read':
                    self.assertEqual(attempt['processRows']['222'], [101, '/usr/bin/afplay'])
                else:
                    self.assertEqual(attempt['processRows'], {})

    def test_real_preconditions_allow_only_the_two_long_lived_server_modes(self):
        whisper = '/opt/homebrew/bin/whisper-server -m fixture --port 8178'
        polish = '/fixture/Python /fixture/mlx_lm.server --model fixture --port 8179'
        cases = [(None, whisper, polish, 'Python', False, False, True),
                 ('afplay', whisper, polish, 'Python', False, False, False),
                 ('whisper-cpp', whisper, polish, 'Python', False, False, False),
                 ('nested-whisper-server', whisper, polish, 'Python', False, False, False),
                 (None, 'whisper-server -m fixture', polish, 'Python', False, False, False),
                 (None, 'whisper-server --port --help', polish, 'Python', False, False, False),
                 (None, whisper, 'Python other.py --tag mlx_lm.server', 'Python', False, False, False),
                 (None, whisper, polish, 'unrelated', False, False, False),
                 (None, whisper, 'python3 -m mlx_lm.server', 'python3', False, False, True),
                 (None, whisper, polish, 'Python', True, False, False),
                 (None, whisper, polish, 'Python', False, True, False)]
        for extra, stt_args, llm_args, executable, transcribing, locked, expected in cases:
            with self.subTest(extra=extra, stt=stt_args, llm=llm_args, transcribing=transcribing, locked=locked), tempfile.TemporaryDirectory() as tmp:
                nodes = self.tree(('AXStaticText', 'Transcribing'), state='VoiceBar status') if transcribing else self.IDLE_TREE
                module, host = self.busy_host(pathlib.Path(tmp), nodes, ['/fixture/' + executable, '/opt/homebrew/bin/whisper-server'])
                rows = host.process_rows()
                if extra:
                    rows[202] = ((200, '/fixture/whisper-server') if extra == 'nested-whisper-server'
                                 else (101, '/fixture/' + extra))
                host.process_rows = lambda: dict(rows)
                host.child_args = lambda pid: {101: 'bun src/mcp-server-daemon.ts', 200: llm_args,
                                               201: stt_args, 202: whisper}.get(pid)
                with patch.object(pathlib.Path, 'glob', return_value=[self.lock(module, 10)] if locked else []), \
                        contextlib.redirect_stderr(io.StringIO()):
                    self.assertEqual(host.preconditions(), expected)

    def test_ax_receipts_and_logs_redact_teleprompter_words_and_unknown_labels(self):
        word = 'synthetic-private-מילה'
        # Exercise both diagnostic paths: busy substring and missing idle evidence.
        for text, state in [(word, 'VoiceBar teleprompter'), ('Transcribing ' + word, 'VoiceBar'), (word, 'VoiceBar unknown')]:
            with self.subTest(state=state, text=text), tempfile.TemporaryDirectory() as tmp:
                node = dict(role='AXStaticText', identifier='fixture-word', frame=dict(X=1, Y=2, Width=3, Height=4),
                            title=text, description=text, value=text, help=word)
                nodes = self.tree(state=state) + [node]
                module, host = self.busy_host(pathlib.Path(tmp), nodes, [])
                err = io.StringIO()
                with patch.object(pathlib.Path, 'glob', return_value=[]), contextlib.redirect_stderr(err):
                    self.assertFalse(host.preconditions())
                host.save({})
                persisted = '\n'.join(json.dumps(json.loads(p.read_text()), ensure_ascii=False)
                                      if p.suffix == '.json' else p.read_text()
                                      for p in host.output.iterdir() if p.is_file()) + err.getvalue()
                self.assertNotIn(word, persisted)
                redacted = module.redacted(text)
                self.assertIn(redacted, persisted)
                saved = json.loads((host.output / 'resident-visibility.json').read_text())
                retained = saved['preconditions'][-1]['axNodes'][-1]
                for key in ['role', 'identifier', 'frame']: self.assertEqual(retained[key], node[key])
                for key in ['title', 'description', 'value']: self.assertEqual(retained[key], redacted)
                self.assertNotIn('help', retained)
                self.assertIn(state if state != 'VoiceBar unknown' else '<redacted', persisted)

    def test_ax_read_error_payload_never_reaches_operator_or_resident_receipts(self):
        for phase in ['prepare', 'recheck']:
            with self.subTest(phase=phase), tempfile.TemporaryDirectory() as tmp:
                word = 'syntheticPrivateErrorPayload'
                module, host = self.busy_host(pathlib.Path(tmp), self.IDLE_TREE, [])
                def fail(mode): raise RuntimeError(word)
                host.ax = fail
                host.permissions = lambda: (0, dict(axTrusted=True, prompts=[]))
                host.muted = lambda: True
                host.set_mute = lambda value: None
                host.stop = lambda: True
                host.restore_resident = lambda: None
                if phase == 'recheck': host.prepare_resident = host.preconditions
                err = io.StringIO()
                with patch.object(pathlib.Path, 'glob', return_value=[]), contextlib.redirect_stderr(err), \
                        contextlib.redirect_stdout(io.StringIO()):
                    self.assertEqual(module.supervise(host), 2)
                persisted = '\n'.join(p.read_text() for p in host.output.iterdir() if p.is_file()) + err.getvalue()
                self.assertNotIn(word, persisted)
                self.assertIn('<redacted len=28 hmac-sha256=', persisted)

    def test_prepare_errors_preserve_initial_inventory_without_claiming_resident(self):
        for failure in ['count', 'identity', 'ax', 'rows']:
            with self.subTest(failure=failure), tempfile.TemporaryDirectory() as tmp:
                module, host = self.busy_host(pathlib.Path(tmp), self.IDLE_TREE, ['/usr/bin/afplay'])
                host.resident = {}
                rows = host.process_rows()
                if failure == 'count': rows[300] = (1, module.RESIDENT_EXECUTABLE)
                host.process_rows = lambda: dict(rows)
                host.permissions = lambda: (0, dict(axTrusted=True, prompts=[]))
                def fail(*args): raise RuntimeError('fixture ' + failure)
                if failure != 'count':
                    setattr(host, {'identity': 'identity', 'ax': 'ax', 'rows': 'process_rows'}[failure], fail)
                with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(RuntimeError): host.prepare_resident()
                saved = json.loads((host.output / 'resident-visibility.json').read_text())
                attempt = saved['preflight']['prepareInventory']
                self.assertFalse(attempt['safe'])
                self.assertTrue(attempt['error'])
                if failure != 'rows': self.assertIn('200', attempt['processRows'])

    def test_real_preconditions_refuse_mixed_busy_trees_players_and_transcribers(self):
        import contextlib
        import io
        speaking = self.tree(('AXButton', 'Stop speaking'), ('AXButton', 'VoiceBar'), state='VoiceBar teleprompter')
        transcribing = self.tree(('AXButton', 'Cancel transcription'), ('AXStaticText', 'Transcribing'),
                                 state='VoiceBar status')
        cases = [(speaking, ['/usr/bin/afplay'], False), (speaking, [], False),
                 (transcribing, ['/opt/homebrew/bin/whisper-cli'], False), (transcribing, [], False),
                 (self.IDLE_TREE, ['/usr/bin/afplay'], False), (self.IDLE_TREE, ['/opt/homebrew/bin/whisper-cli'], False),
                 (self.IDLE_TREE, ['/opt/homebrew/bin/rec'], False), (self.IDLE_TREE, ['/opt/homebrew/bin/sox'], False),
                 (self.IDLE_TREE, [], True)]
        for nodes, children, expected in cases:
            with self.subTest(children=children, state=nodes[2]['description']), tempfile.TemporaryDirectory() as tmp:
                module, host = self.busy_host(pathlib.Path(tmp), nodes, children)
                err = io.StringIO()
                with patch.object(pathlib.Path, 'glob', return_value=[]), contextlib.redirect_stderr(err):
                    self.assertEqual(host.preconditions(), expected)
                attempt = host.resident['preconditions'][-1]
                self.assertEqual(attempt['safe'], expected)
                for cmd in children:
                    self.assertIn(pathlib.Path(cmd).name, err.getvalue())
        for age, expected in [(None, True), (400, True), (10, False)]:
            with self.subTest(lock_age=age), tempfile.TemporaryDirectory() as tmp:
                module, host = self.busy_host(pathlib.Path(tmp), self.IDLE_TREE, [])
                locks = [] if age is None else [self.lock(module, age)]
                with patch.object(pathlib.Path, 'glob', return_value=locks), \
                        contextlib.redirect_stderr(io.StringIO()):
                    self.assertEqual(host.preconditions(), expected)

    def test_resident_inventory_recorded_every_attempt_and_singleton_rechecked(self):
        import contextlib
        import io
        module = self.module()
        resident = '/Applications/VoiceBar.app/Contents/MacOS/VoiceBar'
        with tempfile.TemporaryDirectory() as tmp:
            output = pathlib.Path(tmp)
            (output / 'sandbox-path.txt').write_text(str(output / 'sandbox'))
            self.stub_permissions(output, json.dumps(dict(axTrusted=True, prompts=[])), 0)
            host = module.NativeHost(output, 'gate2246')
            rows = {100: (1, resident), 101: (100, 'bun')}
            host.process_rows = lambda: dict(rows)
            host.identity = lambda pid: 'start'
            host.child_args = lambda pid: 'bun src/mcp-server-daemon.ts' if pid == 101 else None
            host.ax = lambda mode: dict(nodes=self.IDLE_TREE,
                                        screenWindows=[dict(bounds=dict(X=768, Y=0, Width=192, Height=49), layer=25)])
            with patch.object(pathlib.Path, 'glob', return_value=[]), contextlib.redirect_stderr(io.StringIO()):
                host.prepare_resident()
            attempt = host.resident['preconditions'][-1]
            self.assertEqual((attempt['residentPids'], attempt['residentCount'], attempt['safe']), ([100], 1, True))
            self.assertIn('100', attempt['processRows'])
            # Inventory changes between prepare and start: a second installed resident appears.
            rows[300] = (1, resident)
            err = io.StringIO()
            with patch.object(pathlib.Path, 'glob', return_value=[]), contextlib.redirect_stderr(err):
                with self.assertRaises(RuntimeError) as error:
                    host.start()
            self.assertIn('[100, 300]', str(error.exception))
            attempt = host.resident['preconditions'][-1]
            self.assertEqual((attempt['residentPids'], attempt['residentCount'], attempt['safe']), ([100, 300], 2, False))
            self.assertEqual(host.preflight['residentPids'], [100, 300])
            saved = json.loads((output / 'resident-visibility.json').read_text())
            self.assertEqual(saved['preconditions'][-1]['residentCount'], 2)
            self.assertIn('[100, 300]', err.getvalue())

    def test_unsafe_reasons_name_every_failing_check_with_observed_values(self):
        module = self.module()
        self.assertEqual(module.unsafe_reasons([], [], self.IDLE_TREE), [])
        reasons = module.unsafe_reasons([4242], ['voicelayer-session-a.lock'], ['VoiceBar recording'])
        text = '\n'.join(reasons)
        for observed in ['4242', 'voicelayer-session-a.lock', 'VoiceBar recording']:
            self.assertIn(observed, text)
        self.assertEqual(len(reasons), 3)
        self.assertIn('<redacted len=17 hmac-sha256=', '\n'.join(module.unsafe_reasons([], [], ['Status unreadable'])))
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
            self.assertIn('<redacted len=17 hmac-sha256=', err.getvalue())
            self.assertIn('precondition', err.getvalue())
            # No daemon child: also logged, never a silent False.
            host.process_rows = lambda: {100: (1, '/Applications/VoiceBar.app/Contents/MacOS/VoiceBar')}
            err = io.StringIO()
            with contextlib.redirect_stderr(err):
                self.assertFalse(host.preconditions())
            self.assertIn('daemon', err.getvalue())
            self.assertIn('[]', err.getvalue())

    def stub_permissions(self, output, payload, code):
        # The helper always reports its foreign-modal inventory (GATECAP1); fixtures default to none.
        try:
            parsed = json.loads(payload)
        except ValueError:
            parsed = None
        if isinstance(parsed, dict):
            payload = json.dumps(dict(dict(modals=[], inventoryErrors=[]), **parsed))
        helper = output / 'voicebar-ui-e2e-permissions'
        helper.write_text('#!/bin/sh\nprintf %s ' + repr(payload) + '\nexit ' + str(code) + '\n')
        helper.chmod(0o755)

    def test_permission_prompt_text_is_redacted_before_stop_logs_and_receipts(self):
        for kind, label in [('microphone', 'access your microphone'), ('accessibility', 'Accessibility access'),
                            ('input-monitoring', 'Input Monitoring'), ('screen-recording', 'record your screen'),
                            ('unknown', 'permission needed')]:
            for phase in ['preflight', 'check']:
                with self.subTest(kind=kind, phase=phase), tempfile.TemporaryDirectory() as tmp:
                    output = pathlib.Path(tmp)
                    module, host = self.busy_host(output, self.IDLE_TREE, [])
                    word = 'syntheticPrivatePromptWords'
                    payload = dict(axTrusted=True, prompts=[dict(owner='com.apple.SecurityAgent',
                                                                 labels=[label + ' ' + word, 'Allow'], extra=word)])
                    self.stub_permissions(output, json.dumps(payload), 2)
                    host.collect_owned = lambda: None
                    host.muted = lambda: True
                    host.set_mute = lambda value: None
                    host.stop = lambda: True
                    host.restore_resident = lambda: None
                    if phase == 'check': host.prepare_resident = host.check
                    err = io.StringIO()
                    with contextlib.redirect_stderr(err), contextlib.redirect_stdout(io.StringIO()):
                        self.assertEqual(module.supervise(host), 2)
                    files = [p for p in output.iterdir() if p.suffix in ['.json', '.log']]
                    persisted = '\n'.join(p.read_text() for p in files) + err.getvalue()
                    self.assertNotIn(word, persisted)
                    self.assertNotIn(label, persisted)
                    self.assertIn('STOP', persisted)
                    prompt = json.loads((output / 'operator-state.json').read_text())['checks'][-1]['permissions']['prompts'][0]
                    self.assertEqual(prompt['owner'], 'com.apple.SecurityAgent')
                    self.assertEqual(prompt['kind'], kind)
                    self.assertTrue(all(x.startswith('<redacted len=') for x in prompt['labels']))
                    self.assertNotIn('extra', prompt)

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
            self.assertRegex(host.checks[-1]['permissions']['prompts'][0]['labels'][0],
                             r'^<redacted len=5 hmac-sha256=[0-9a-f]{8}>$')
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
            self.assertNotIn('not json', str(unreadable.exception))
            self.assertIn('<redacted len=8 hmac-sha256=', str(unreadable.exception))

    def test_permission_owner_or_process_name_rejects_free_text(self):
        for field in ['owner', 'processName']:
            with self.subTest(field=field), tempfile.TemporaryDirectory() as tmp:
                output = pathlib.Path(tmp)
                module, host = self.busy_host(output, self.IDLE_TREE, [])
                private = 'synthetic private owner words'
                prompt = dict(labels=['Allow'], **{field: private})
                self.stub_permissions(output, json.dumps(dict(axTrusted=True, prompts=[prompt])), 2)
                err = io.StringIO()
                with contextlib.redirect_stderr(err), self.assertRaisesRegex(RuntimeError, 'STOP'):
                    host.prepare_resident()
                host.save({})
                persisted = err.getvalue() + '\n'.join(p.read_text() for p in output.iterdir()
                                                       if p.suffix in ['.json', '.log'])
                self.assertNotIn(private, persisted)
                self.assertRegex(host.checks[-1]['permissions']['prompts'][0]['owner'],
                                 r'^<redacted len=29 hmac-sha256=[0-9a-f]{8}>$')

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
            self.assertEqual(module.supervise(Host()), 2)  # HARN-SUP: pre-launch refusal is PREFLIGHT_REFUSED.
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
            safe_rows = {100: (1, '/Applications/VoiceBar.app/Contents/MacOS/VoiceBar'), 101: (100, 'bun')}
            for capture, fresh, nodes, expected in [(False, False, self.IDLE_TREE, True),
                    (True, False, self.IDLE_TREE, False), (False, True, self.IDLE_TREE, False),
                    (False, False, self.tree(state='VoiceBar recording'), False), (False, False, [], False)]:
                host.process_rows = lambda: dict(safe_rows, **{}) | ({102: (101, '/usr/bin/rec')} if capture else {})
                host.ax = lambda mode: dict(nodes=nodes)
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
            birth = list(module.kernel_birth(os.getppid()))
            proof.write_text(json.dumps(dict(pid=os.getppid(), birth=birth, token='fixture-token')))
            self.assertEqual(module.require_supervisor(output, {'VOICEBAR_UIE2E_SUPERVISOR_TOKEN':'fixture-token'}),
                             dict(pid=os.getppid(), birth=tuple(birth)))
            for stale in [None, [birth[0], birth[1] + 1]]:  # Same PID, different/missing birth.
                proof.write_text(json.dumps(dict(pid=os.getppid(), birth=stale, token='fixture-token')))
                with self.assertRaises(ValueError):
                    module.require_supervisor(output, {'VOICEBAR_UIE2E_SUPERVISOR_TOKEN':'fixture-token'})
            proof.write_text(json.dumps(dict(pid=os.getppid(), birth=birth, token='fixture-token')))
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

    # SUP3 (run-03, 2026-10-18): the runner was launched through framework Python's bin/python3
    # stub, which re-execs Python.app in place. Same PID, same start time, new comm; the
    # supervisor called that an identity change, aborted, and then refused to signal anything.
    STUB = '/Library/Frameworks/Python.framework/Versions/3.13/bin/python3'
    APP = '/Library/Frameworks/Python.framework/Versions/3.13/Resources/Python.app/Contents/MacOS/Python'

    def sup3_tree(self, host):
        live = {200: dict(started='runner-start', cmd=self.STUB, parent=99, state='S')}
        class Child:
            pid = 200
            def poll(self): return None if 200 in live else 0
        host.child = Child()
        host.process_state = lambda pid: dict(live[pid]) if pid in live else None
        host.process_rows = lambda: {pid: (s['parent'], s['cmd']) for pid, s in live.items()}
        host.guard_mute = lambda: None
        host.shutdown_wait = lambda seconds: None
        host.remember(200, 'runner')
        live[200]['cmd'] = self.APP  # The stub's execv lands after Popen returned.
        qa = str((host.sandbox / 'VoiceBarQA.app/Contents/MacOS/VoiceBar').resolve())
        live[201] = dict(started='xcodebuild-start', cmd='/usr/bin/xcodebuild', parent=200, state='S')
        live[202] = dict(started='9999999999.000000', cmd=qa, parent=1, state='S')
        return live

    def test_sup3_runner_reexec_is_not_an_identity_change_and_run_continues(self):
        with tempfile.TemporaryDirectory() as tmp:
            host = self.host(pathlib.Path(tmp))
            live = self.sup3_tree(host)
            host.collect_owned()  # run-03 raised 'Owned PID identity changed; no signal: 46884' here.
            self.assertEqual(set(host.owned), {200, 201, 202})
            # xcrun's /usr/bin/xcodebuild shim also execs in place; still the same owned process.
            live[201]['cmd'] = '/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild'
            self.assertTrue(host.owned_alive(201))
            self.assertTrue(host.owned_alive(200))

    def test_sup3_supervisor_failure_terminates_runner_xcodebuild_and_qa_with_proof(self):
        module = self.module()
        with tempfile.TemporaryDirectory() as tmp:
            host = self.host(pathlib.Path(tmp))
            state = {}
            def start():
                state['live'] = self.sup3_tree(host)
                host.runner_launch_attempted = True
            host.start = start
            host.prepare_resident = host.restore_resident = lambda: None
            host.export = lambda: 0
            host.save = lambda receipt: setattr(host, 'receipt', json.loads(json.dumps(receipt)))
            mute = [False]
            host.muted = lambda: mute[0]
            host.set_mute = lambda value: mute.__setitem__(0, value)
            checks = []
            def check():
                host.collect_owned()
                checks.append(1)
                if len(checks) == 3: raise RuntimeError('Device tripwire invoked')
            host.check = check
            host.wait = lambda seconds: None
            signals = []
            def kill(pid, sig):
                live = state['live']
                signals.append((pid, sig))
                if pid == 200:
                    # The runner dies; its xcodebuild (exec'd, own session) is reparented.
                    live.pop(200)
                    live[201].update(parent=1, cmd='/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild')
                else:
                    live.pop(pid, None)
            with patch.object(module.os, 'kill', side_effect=kill), \
                    contextlib.redirect_stdout(io.StringIO()):
                code = module.supervise(host)
            self.assertEqual(code, 1)
            self.assertIn('Device tripwire', host.receipt['error'])
            self.assertEqual(signals[0], (200, module.signal.SIGINT))
            self.assertEqual({pid for pid, _ in signals}, {200, 201, 202})
            self.assertFalse(state['live'], 'owned xcodebuild/runner/QA left orphaned')
            errors = host.shutdown[-1]['errors']
            self.assertNotIn('identity changed', str(errors))
            self.assertNotIn('Runner termination NOT_PROVEN', errors)
            self.assertEqual(errors, ['Launch completeness NOT_PROVEN; discovered subset is not all-owned proof'])
            self.assertTrue(host.receipt['muteRetained'])  # Launch completeness is still never claimed.

    def test_sup3_reused_pid_is_retired_and_never_signalled(self):
        with tempfile.TemporaryDirectory() as tmp:
            host = self.host(pathlib.Path(tmp))
            host.owned = {300: dict(started='start', cmd='/fixture/qa', parent=1, state='S', kind='qa')}
            reused = dict(started='other-start', cmd='/fixture/qa', parent=1, state='S')
            host.process_state = lambda pid: dict(reused)
            host.process_rows = lambda: {300: (1, '/fixture/qa'), 301: (300, '/fixture/grandchild')}
            host.guard_mute = lambda: None
            host.shutdown_wait = lambda seconds: None
            with patch('os.kill') as kill:
                host.collect_owned()  # A transient reuse never aborts the run.
                self.assertFalse(host.owned_alive(300))
                host.terminate_owned(300)
                self.assertTrue(host.stop())  # The original exited: reuse is termination proof.
                kill.assert_not_called()
            self.assertNotIn(301, host.owned)  # A reused PID's children are not ours.
            self.assertIn('pid-reused', json.dumps(host.owned[300]))
            self.assertNotIn('NOT_PROVEN: 300', str(host.shutdown))

    def test_sup3_reaped_runner_is_never_signalled_even_if_ps_matches(self):
        with tempfile.TemporaryDirectory() as tmp:
            host = self.host(pathlib.Path(tmp))
            class Child:
                pid = 200
                def poll(self): return 0  # Reaped: PID 200 is free for reuse.
            host.child = Child()
            host.owned = {200: dict(started='s', cmd='python', parent=1, state='S', kind='runner')}
            host.process_state = lambda pid: dict(started='s', cmd='python', parent=1, state='S')
            host.process_rows = lambda: {}
            host.guard_mute = lambda: None
            with patch('os.kill') as kill:
                host.stop()
                kill.assert_not_called()

    def test_sup3_unreaped_runner_is_signalled_from_its_handle_even_if_ps_is_unreadable(self):
        with tempfile.TemporaryDirectory() as tmp:
            host = self.host(pathlib.Path(tmp))
            alive = [True]
            class Child:
                pid = 200
                def poll(self): return None if alive[0] else 130
            host.child = Child()
            host.owned = {200: dict(started='s', cmd=self.STUB, parent=1, state='S', kind='runner')}
            def unreadable(pid): raise RuntimeError('identity unavailable')
            host.process_state = unreadable
            host.process_rows = lambda: {}
            host.guard_mute = lambda: None
            host.shutdown_wait = lambda seconds: None
            def kill(pid, sig): alive[0] = False
            with patch('os.kill', side_effect=kill) as kill_mock:
                host.terminate_owned(200, runner=True)
            kill_mock.assert_called_once_with(200, self.module().signal.SIGINT)

    def test_sup3_reparent_race_during_scan_is_skipped_not_fatal(self):
        with tempfile.TemporaryDirectory() as tmp:
            host = self.host(pathlib.Path(tmp))
            host.owned = {500: dict(started='s', cmd='runner', parent=1, state='S', kind='qa')}
            states = {500: dict(started='s', cmd='runner', parent=1, state='S'),
                      600: dict(started='t', cmd='helper', parent=1, state='S')}  # Reparented after the rows read.
            host.process_state = lambda pid: dict(states[pid])
            host.process_rows = lambda: {500: (1, 'runner'), 600: (500, 'helper')}
            host.collect_owned()
            self.assertNotIn(600, host.owned)
            self.assertIn('600', json.dumps(host.ownership_races))

    def test_sup3_owned_identity_reads_are_locale_and_timezone_pinned(self):
        with tempfile.TemporaryDirectory() as tmp:
            host = self.host(pathlib.Path(tmp))
            calls = []
            def run(args):
                calls.append(args)
                return 'Sun Oct 18 07:14:49 2026 S 46291 /usr/bin/python3'
            host.run = run
            host.kernel_birth = lambda pid: (1792308889, 42)
            state = host.process_state(46884)
            self.assertEqual(state['started'], '1792308889.000042')  # Kernel µs birth is the identity.
            self.assertEqual(state['lstart'], 'Sun Oct 18 07:14:49 2026')  # Receipt only.
            self.assertEqual(calls[0][:3], ['env', 'LC_ALL=C', 'TZ=UTC0'])

    # SUP3 round 2 (Sol R1-R5).
    def r2_host(self, tmp, live, child_alive=None):
        host = self.host(pathlib.Path(tmp))
        if child_alive is not None:
            class Child:
                pid = 200
                def poll(self): return None if child_alive() else 0
            host.child = Child()
        host.process_state = lambda pid: dict(live[pid]) if pid in live else None
        host.process_rows = lambda: {pid: (s['parent'], s['cmd']) for pid, s in live.items()}
        host.guard_mute = lambda: None
        host.shutdown_wait = lambda seconds: None
        return host

    def test_r1_same_second_replacement_is_never_signalled(self):
        with tempfile.TemporaryDirectory() as tmp:
            host = self.host(pathlib.Path(tmp))
            births = {300: (1792308789, 100000)}
            host.kernel_birth = lambda pid: births.get(pid)
            host.run = lambda args: 'Sun Oct 18 07:14:49 2026 S 1 /owned/worker'
            host.remember(300, 'qa')
            births[300] = (1792308789, 900000)  # Same printed lstart second, different process.
            host.run = lambda args: 'Sun Oct 18 07:14:49 2026 S 1 /unrelated/replacement'
            host.guard_mute = lambda: None
            with patch('os.kill') as kill:
                host.terminate_owned(300)
                kill.assert_not_called()
            self.assertEqual(host.owned[300]['retired']['reason'], 'pid-reused')

    def test_r1_birth_is_kernel_microseconds_and_fails_closed(self):
        module = self.module()
        with tempfile.TemporaryDirectory() as tmp:
            host = self.host(pathlib.Path(tmp))
            seconds, micros = module.kernel_birth(os.getpid())
            self.assertLessEqual(seconds, __import__('time').time())
            self.assertTrue(0 <= micros < 10**6)
            self.assertEqual(module.kernel_birth(os.getpid()), (seconds, micros))
            self.assertIsNone(module.kernel_birth(2**30))  # ESRCH: no such process.
            with patch.object(module, '_proc_pidinfo', return_value=(0, 1)):  # EPERM
                with self.assertRaisesRegex(RuntimeError, 'identity unreadable'):
                    module.kernel_birth(os.getpid())
            # A birth that changes across the ps read is never one identity.
            births = iter([(1, 1), (1, 2)])
            host.kernel_birth = lambda pid: next(births)
            host.run = lambda args: 'Sun Oct 18 07:14:49 2026 S 1 /x'
            with self.assertRaisesRegex(RuntimeError, 'changed during read'): host.process_state(300)

    def test_r2_registered_child_reparented_before_first_scan_is_terminated(self):
        with tempfile.TemporaryDirectory() as tmp:
            live = {200: dict(started='runner', cmd=self.APP, parent=99, state='S'),
                    201: dict(started='1.000002', cmd='/usr/bin/xcodebuild', parent=1, state='S')}
            host = self.r2_host(tmp, live, child_alive=lambda: 200 in live)
            host.owned = {200: dict(live[200], kind='runner')}
            module = self.module()
            module.register_owned(host.registry, 'fixture-token', 'xcodebuild', 201, (1, 2))
            host.token = 'fixture-token'
            # A forged/stale row (wrong token or birth) is never adopted.
            module.register_owned(host.registry, 'other-token', 'xcodebuild', 202, (1, 3))
            live[202] = dict(started='1.000003', cmd='/bin/unrelated', parent=1, state='S')
            module.register_owned(host.registry, 'fixture-token', 'capture', 203, (1, 9))
            live[203] = dict(started='1.000004', cmd='/bin/reused', parent=1, state='S')
            signals = []
            def kill(pid, sig):
                signals.append((pid, sig)); live.pop(pid, None)
            with patch('os.kill', side_effect=kill): host.stop()
            self.assertEqual({p for p, _ in signals}, {200, 201})
            self.assertEqual(set(live), {202, 203})

    def test_r2_launchd_apps_need_exact_path_and_birth_after_launch(self):
        with tempfile.TemporaryDirectory() as tmp:
            host = self.host(pathlib.Path(tmp))
            qa = str((host.sandbox / 'VoiceBarQA.app/Contents/MacOS/VoiceBar').resolve())
            xr = str((host.output / 'DerivedData/Build/Products/Debug/VoiceBarUIE2ETests-Runner.app/Contents'
                      '/MacOS/VoiceBarUIE2ETests-Runner').resolve())
            live = {301: dict(started='5.000000', cmd=qa, parent=1, state='S'),
                    302: dict(started='20.000000', cmd=xr, parent=1, state='S'),
                    303: dict(started='20.000000', cmd='/elsewhere/VoiceBar', parent=1, state='S')}
            host.process_state = lambda pid: dict(live[pid]) if pid in live else None
            host.process_rows = lambda: {pid: (s['parent'], s['cmd']) for pid, s in live.items()}
            host.launch_birth = (10, 0)
            host.collect_owned()
            self.assertEqual(set(host.owned), {302})  # QA born before launch is not ours.

    def test_relocated_launchd_runner_adoption_and_modal_proof_stay_lifetime_bound(self):
        with tempfile.TemporaryDirectory(suffix='.noindex') as tmp:
            root = pathlib.Path(tmp)
            output = root / 'output'
            output.mkdir()
            derived = root / 'relocated.noindex/DerivedData'
            metadata = output / 'derived-data-path.txt'
            metadata.write_text(str(derived) + '\n')
            runner = (derived / 'Build/Products/Debug/VoiceBarUIE2ETests-Runner.app/Contents'
                      '/MacOS/VoiceBarUIE2ETests-Runner')
            runner.parent.mkdir(parents=True)
            runner.write_bytes(b'synthetic runner, never executed')
            host = self.host(output)
            self.assertFalse((output / 'DerivedData').exists())
            xr = str(runner.resolve())
            foreign = str((root / 'foreign.noindex' / runner.relative_to(derived)).resolve())
            legacy = str((output / 'DerivedData' / runner.relative_to(derived)).resolve())
            live = {302: dict(started='20.000001', cmd=xr, parent=1, state='S'),
                    303: dict(started='5.000000', cmd=xr, parent=1, state='S'),
                    304: dict(started='20.000001', cmd=foreign, parent=1, state='S'),
                    305: dict(started='20.000001', cmd=legacy, parent=1, state='S')}
            host.process_state = lambda pid: dict(live[pid]) if pid in live else None
            host.process_rows = lambda: {pid: (s['parent'], s['cmd']) for pid, s in live.items()}
            host.launch_birth = (10, 0)
            host.collect_owned()
            self.assertEqual(set(host.owned), {302})
            self.assertEqual(host.owned[302]['kind'], 'xctest-runner')
            self.assertEqual(host.owned[302]['cmd'], xr)
            self.assertEqual(host.owned[302]['started'], '20.000001')
            self.assertTrue(any(row['pid'] == 303 for row in host.ownership_races))
            # Exercise the actual modal-proof writer, with only its native helper stubbed.
            with patch('subprocess.run', return_value=SimpleNamespace(
                    returncode=0, stdout=json.dumps(dict(axTrusted=True, prompts=[], modals=[])))):
                type(host).permissions(host)
            proof = json.loads((output / 'modal-run-proof.json').read_text())
            self.assertEqual(proof['owned'], [dict(pid=302, birth=[20, 1], path=xr)])
            # A later metadata edit cannot grant this host authority over a new product path.
            metadata.write_text(str(root / 'foreign.noindex'))
            host.collect_owned()
            self.assertEqual(set(host.owned), {302})
            live[302]['started'] = '30.000002'  # PID reused at the same exact path.
            self.assertFalse(host.owned_alive(302))
            with patch('os.kill') as kill:
                host.terminate_owned(302)
                kill.assert_not_called()
            self.assertEqual(host.owned[302]['retired']['reason'], 'pid-reused')

    def test_r3_mute_guard_failure_never_blocks_termination(self):
        with tempfile.TemporaryDirectory() as tmp:
            live = {200: dict(started='r', cmd='runner', parent=99, state='S'),
                    201: dict(started='x', cmd='xcodebuild', parent=200, state='S'),
                    202: dict(started='q', cmd='qa', parent=1, state='S')}
            host = self.r2_host(tmp, live, child_alive=lambda: 200 in live)
            host.owned = {pid: dict(live[pid], kind='k') for pid in live}
            def broken(): raise RuntimeError('osascript timeout')
            host.guard_mute = broken
            host.shutdown_wait = lambda seconds: host.guard_mute()
            signals = []
            def kill(pid, sig): signals.append((pid, sig)); live.pop(pid, None)
            with patch('os.kill', side_effect=kill):
                self.assertFalse(host.stop())
            self.assertFalse(live)
            self.assertIn('osascript timeout', str(host.shutdown[-1]['errors']))

    def test_r3_scan_failure_between_steps_keeps_escalating(self):
        module = self.module()
        with tempfile.TemporaryDirectory() as tmp:
            live = {200: dict(started='r', cmd='runner', parent=99, state='S')}
            host = self.r2_host(tmp, live, child_alive=lambda: 200 in live)
            host.owned = {200: dict(live[200], kind='runner')}
            signals = []
            def kill(pid, sig):
                signals.append(sig)
                if sig == module.signal.SIGKILL: live.pop(pid)
                else: host.process_rows = lambda: (_ for _ in ()).throw(RuntimeError('ps timeout'))
            with patch('os.kill', side_effect=kill):
                self.assertFalse(host.stop())
            self.assertEqual(signals, [module.signal.SIGINT, module.signal.SIGTERM, module.signal.SIGKILL])
            self.assertFalse(live)
            self.assertIn('ps timeout', str(host.shutdown[-1]['errors']))

    def test_r4_child_forked_during_another_shutdown_is_drained(self):
        module = self.module()
        with tempfile.TemporaryDirectory() as tmp:
            live = {200: dict(started='q', cmd='qa', parent=1, state='S')}
            host = self.r2_host(tmp, live)
            host.owned = {200: dict(live[200], kind='qa')}
            waits = []
            def shutdown_wait(seconds):
                waits.append(1)
                if len(waits) == 2: live.pop(200, None)  # Parent ends after its helper was adopted.
            host.shutdown_wait = shutdown_wait
            signals = []
            def kill(pid, sig):
                signals.append((pid, sig))
                if pid == 200: live[201] = dict(started='h', cmd='helper', parent=200, state='S')
                else: live.pop(pid, None)
            with patch('os.kill', side_effect=kill):
                self.assertTrue(host.stop())
            self.assertIn((201, module.signal.SIGTERM), signals)
            self.assertFalse(live)

    def test_r4_cleanup_has_an_overall_deadline(self):
        module = self.module()
        with tempfile.TemporaryDirectory() as tmp:
            live = {200: dict(started='q', cmd='qa', parent=1, state='S')}
            host = self.r2_host(tmp, live)
            host.owned = {200: dict(live[200], kind='qa')}
            clock = [0.0]
            def shutdown_wait(seconds): clock[0] += 1000
            host.shutdown_wait = shutdown_wait
            with patch('os.kill'), patch.object(module.time, 'monotonic', side_effect=lambda: clock[0]):
                self.assertFalse(host.stop())
            self.assertIn('deadline', str(host.shutdown[-1]['errors']).lower())

    # SUP3.1: Sol round-2 reproductions N1-N6 as negative tests (RULINGS: safety over completeness).
    def n_host(self, tmp, live, runner=False):
        host = self.r2_host(tmp, live, child_alive=(lambda: 200 in live) if runner else None)
        host.current_birth = lambda pid: live[pid]['started'] if pid in live else None
        return host

    def test_n1_pid_reused_after_ps_before_birth_read_is_never_owned(self):
        module = self.module()
        with tempfile.TemporaryDirectory() as tmp:
            host = self.host(pathlib.Path(tmp))
            host.launch_birth = (10, 0)
            qa = str((host.sandbox / 'VoiceBarQA.app/Contents/MacOS/VoiceBar').resolve())
            world = dict(birth=(15, 1), cmd=qa)
            host.kernel_birth = lambda pid: world['birth'] if pid == 300 else None
            host.current_birth = lambda pid: module.birth_text(world['birth'])
            def run(args):
                cmd = world['cmd']
                world.update(birth=(20, 2), cmd='/unrelated/replacement')  # Reused right after ps.
                return 'Sun Oct 18 07:14:49 2026 S 1 ' + cmd
            host.run = run
            host.process_rows = lambda: {300: (1, qa)}
            host.collect_owned()
            self.assertNotIn(300, host.owned)  # Old metadata is never joined to the new birth.
            with patch('os.kill') as kill:
                host.stop()
                kill.assert_not_called()

    def test_n1_metadata_is_read_inside_the_birth_bracket(self):
        with tempfile.TemporaryDirectory() as tmp:
            host = self.host(pathlib.Path(tmp))
            order = []
            host.kernel_birth = lambda pid: order.append('birth') or (5, 5)
            host.run = lambda args: order.append('ps') or 'Sun Oct 18 07:14:49 2026 S 1 /x'
            self.assertEqual(host.process_state(300)['started'], '5.000005')
            self.assertEqual(order, ['birth', 'ps', 'birth'])

    def test_signal_requires_fresh_kernel_birth_equal_to_recorded(self):
        module = self.module()
        with tempfile.TemporaryDirectory() as tmp:
            live = {300: dict(started='10.000001', cmd='/fixture/qa', parent=1, state='S')}
            host = self.n_host(tmp, live)
            host.owned = {300: dict(live[300], kind='qa')}
            host.current_birth = lambda pid: '20.000002'  # Replaced between the check and the signal.
            with patch('os.kill') as kill:
                host.terminate_owned(300)
                kill.assert_not_called()
            plain = module.NativeHost.__new__(module.NativeHost)
            plain.kernel_birth = lambda pid: (20, 2)
            self.assertEqual(plain.current_birth(300), '20.000002')
            plain.kernel_birth = lambda pid: None
            self.assertIsNone(plain.current_birth(300))

    def test_real_current_birth_wiring_withholds_signal_from_replaced_pid(self):
        # CR outside-diff: keep the PRODUCTION current_birth; mock only the kernel birth source.
        with tempfile.TemporaryDirectory() as tmp:
            live = {300: dict(started='10.000001', cmd='/fixture/qa', parent=1, state='S')}
            host = self.r2_host(tmp, live)
            del host.current_birth  # Drop the fixture override; the real method is back.
            source_module = type(host).current_birth.__globals__  # The module this host was built from.
            self.assertIs(host.current_birth.__func__, type(host).current_birth)
            self.assertNotIn('kernel_birth', vars(host))  # The production NativeHost.kernel_birth too.
            host.owned = {300: dict(live[300], kind='qa')}
            source = dict(birth=(10, 1))
            # Only the kernel birth source (the module-level proc_pidinfo reader) is mocked.
            with patch.dict(source_module, kernel_birth=lambda pid: source['birth'] if pid == 300 else None):
                source['birth'] = (20, 2)  # Recycled after ownership was recorded.
                with patch('os.kill') as kill:
                    host.terminate_owned(300)
                    kill.assert_not_called()
                self.assertEqual(host.owned[300]['retired'], dict(reason='pid-reused', observedBirth='20.000002'))
                host.owned = {300: dict(live[300], kind='qa')}
                source['birth'] = (10, 1)  # The same lifetime: the gate lets the signal through.
                def kill(pid, sig): live.pop(pid, None)
                with patch('os.kill', side_effect=kill) as killed:
                    host.terminate_owned(300)
                killed.assert_called_once_with(300, source_module['signal'].SIGTERM)

    def test_n2_one_unreadable_registration_never_starves_other_owned_targets(self):
        module = self.module()
        with tempfile.TemporaryDirectory() as tmp:
            live = {200: dict(started='1.000000', cmd='runner', parent=99, state='S'),
                    201: dict(started='1.000001', cmd='/usr/bin/xcodebuild', parent=1, state='S'),
                    202: dict(started='1.000002', cmd='/usr/bin/recorder', parent=1, state='S')}
            host = self.n_host(tmp, live, runner=True)
            host.owned = {200: dict(live[200], kind='runner')}
            host.token = 'fixture-token'
            module.register_owned(host.registry, 'fixture-token', 'test', 201, (1, 1))
            module.register_owned(host.registry, 'fixture-token', 'recorder', 202, (1, 2))
            def state(pid):
                if pid == 201: raise RuntimeError('identity unreadable: 201 (EPERM)')
                return dict(live[pid]) if pid in live else None
            host.process_state = state
            signals = []
            def kill(pid, sig): signals.append((pid, sig)); live.pop(pid, None)
            with patch('os.kill', side_effect=kill):
                self.assertFalse(host.stop())
            self.assertIn((202, module.signal.SIGTERM), signals)
            self.assertNotIn(201, [pid for pid, _ in signals])
            report = host.unproven_targets()
            self.assertEqual([r['pid'] for r in report], [201])
            self.assertEqual(report[0]['path'], '/usr/bin/xcodebuild')
            self.assertIn('EPERM', report[0]['reason'])

    def test_n3_slow_failing_discovery_still_escalates_runner_within_budget(self):
        module = self.module()
        with tempfile.TemporaryDirectory() as tmp:
            live = {200: dict(started='1.000000', cmd='runner', parent=99, state='S')}
            host = self.n_host(tmp, live, runner=True)
            host.owned = {200: dict(live[200], kind='runner')}
            clock = [0.0]
            def slow_rows():
                clock[0] += 15  # The native ps bound, then failure.
                raise RuntimeError('ps timeout')
            host.process_rows = slow_rows
            def shutdown_wait(seconds): clock[0] += seconds
            host.shutdown_wait = shutdown_wait
            signals = []
            def kill(pid, sig):
                signals.append(sig)
                if sig == module.signal.SIGKILL: live.pop(pid)
            with patch('os.kill', side_effect=kill), \
                    patch.object(module.time, 'monotonic', side_effect=lambda: clock[0]):
                self.assertFalse(host.stop())
            self.assertEqual(signals, [module.signal.SIGINT, module.signal.SIGTERM, module.signal.SIGKILL])
            self.assertFalse(live)
            self.assertLessEqual(clock[0], module.CLEANUP_BUDGET_SECONDS)
            self.assertNotIn('Runner termination NOT_PROVEN', host.shutdown[-1]['errors'])

    def test_n3_slow_mute_guard_still_escalates_runner_within_budget(self):
        module = self.module()
        with tempfile.TemporaryDirectory() as tmp:
            live = {200: dict(started='1.000000', cmd='runner', parent=99, state='S')}
            host = self.n_host(tmp, live, runner=True)
            host.owned = {200: dict(live[200], kind='runner')}
            del host.shutdown_wait  # The real wait, whose mute checks hang.
            clock = [0.0]
            def slow_guard(): clock[0] += 15  # osascript at its native bound.
            host.guard_mute = slow_guard
            signals = []
            def kill(pid, sig):
                signals.append(sig)
                if sig == module.signal.SIGKILL: live.pop(pid)
            with patch('os.kill', side_effect=kill), patch.object(module.time, 'sleep'), \
                    patch.object(module.time, 'monotonic', side_effect=lambda: clock[0]):
                host.stop()
            self.assertEqual(signals, [module.signal.SIGINT, module.signal.SIGTERM, module.signal.SIGKILL])
            self.assertFalse(live)
            self.assertLessEqual(clock[0], module.CLEANUP_BUDGET_SECONDS)

    def test_n4_transient_identity_failure_is_retried_not_abandoned(self):
        module = self.module()
        with tempfile.TemporaryDirectory() as tmp:
            live = {201: dict(started='1.000001', cmd='/fixture/helper', parent=1, state='S')}
            host = self.n_host(tmp, live)
            host.owned = {201: dict(live[201], kind='registered-test')}
            reads = []
            def state(pid):
                reads.append(pid)
                if len(reads) == 1: raise RuntimeError('temporary identity-read timeout')
                return dict(live[pid]) if pid in live else None
            host.process_state = state
            signals = []
            def kill(pid, sig): signals.append((pid, sig)); live.pop(pid, None)
            with patch('os.kill', side_effect=kill):
                host.stop()
            self.assertEqual(signals, [(201, module.signal.SIGTERM)])
            self.assertFalse(live)
            self.assertEqual(host.unproven_targets(), [])

    def test_n4_persistently_unreadable_target_is_reported_never_signalled(self):
        with tempfile.TemporaryDirectory() as tmp:
            live = {201: dict(started='1.000001', cmd='/fixture/helper', parent=1, state='S')}
            host = self.n_host(tmp, live)
            host.owned = {201: dict(live[201], kind='registered-test')}
            def unreadable(pid): raise RuntimeError('identity unreadable: 201')
            host.process_state = unreadable
            with patch('os.kill') as kill:
                self.assertFalse(host.stop())
                kill.assert_not_called()
            report = host.unproven_targets()
            self.assertEqual([(r['pid'], r['path']) for r in report], [(201, '/fixture/helper')])
            self.assertIn('unreadable', report[0]['reason'])

    def test_n5_new_birth_at_tracked_pid_is_reported_not_adopted_and_fails(self):
        module = self.module()
        with tempfile.TemporaryDirectory() as tmp:
            live = {201: dict(started='10.000002', cmd='/fixture/recorder', parent=1, state='S')}
            host = self.n_host(tmp, live)
            host.owned = {201: dict(started='10.000001', cmd='/fixture/recorder', parent=1, state='S',
                                    kind='registered-recorder')}
            host.token = 'fixture-token'
            module.register_owned(host.registry, 'fixture-token', 'recorder', 201, (10, 1))
            module.register_owned(host.registry, 'fixture-token', 'recorder', 201, (10, 2))
            host.runner_launch_attempted = True
            with patch('os.kill') as kill:
                self.assertFalse(host.stop())
                kill.assert_not_called()
            self.assertEqual(host.owned[201]['started'], '10.000001')  # Never adopted.
            report = host.unproven_targets()
            self.assertEqual([r['pid'] for r in report], [201])
            self.assertIn('new birth', report[0]['reason'])
            self.assertIsNone(host.mute_retention_reason)  # A known survivor is FAIL, never exit 3.

    def test_unproven_targets_reach_operator_state_and_stderr(self):
        module = self.module()
        with tempfile.TemporaryDirectory() as tmp:
            live = {201: dict(started='1.000001', cmd='/fixture/helper', parent=1, state='S')}
            host = self.n_host(tmp, live)
            host.owned = {201: dict(live[201], kind='registered-test')}
            def unreadable(pid): raise RuntimeError('identity unreadable: 201')
            host.process_state = unreadable
            stderr = io.StringIO()
            with patch('os.kill') as kill, contextlib.redirect_stderr(stderr):
                host.stop()
                kill.assert_not_called()
            host.save({})
            state = json.loads((host.output / 'operator-state.json').read_text())
            self.assertEqual(state['unprovenTargets'][0]['pid'], 201)
            self.assertEqual(state['unprovenTargets'][0]['path'], '/fixture/helper')
            self.assertIn('201', stderr.getvalue())
            self.assertIn('/fixture/helper', stderr.getvalue())
            self.assertIn('UNPROVEN', host.shutdown[-1]['errors'][0])

    def test_n6_registration_requires_complete_verified_record(self):
        module = self.module()
        real_write = os.write
        with tempfile.TemporaryDirectory() as tmp:
            registry = pathlib.Path(tmp) / 'owned-registrations.jsonl'
            def short(fd, data): return real_write(fd, data[:12])
            with patch.object(module.os, 'write', side_effect=short):
                with self.assertRaisesRegex(RuntimeError, 'registration'):
                    module.register_owned(registry, 'fixture-token', 'test', 201, (1, 2))
            with patch.object(module.os, 'fsync', side_effect=OSError('EIO')):
                with self.assertRaises(OSError):
                    module.register_owned(registry, 'fixture-token', 'test', 202, (1, 3))
            with patch.object(module.os, 'pread', return_value=b'x'):
                with self.assertRaisesRegex(RuntimeError, 'registration'):
                    module.register_owned(registry, 'fixture-token', 'test', 203, (1, 4))
            # The torn prefix never corrupts the framing of a later valid registration.
            module.register_owned(registry, 'fixture-token', 'recorder', 204, (1, 5))
            host = self.host(pathlib.Path(tmp))
            host.registry, host.token = registry, 'fixture-token'
            self.assertIn((204, 'recorder', '1.000005'), host.registered())
            self.assertNotIn(201, [pid for pid, _, _ in host.registered()])

if __name__=='__main__': unittest.main()
