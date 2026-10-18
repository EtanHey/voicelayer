#!/usr/bin/env python3
"""GATECAP1: no global-shortcut collisions, QA-only frames, foreign-modal STOP. No native app or capture."""
import contextlib
import importlib.util
import io
import json
import pathlib
import plistlib
import re
import subprocess
import tempfile
import unittest
from types import SimpleNamespace
from unittest.mock import patch

ROOT = pathlib.Path(__file__).resolve().parent.parent
GATE_APP = ROOT / 'flow-bar/Sources/VoiceBar/UIE2EGate2245.swift'
GATE_TESTS = ROOT / 'flow-bar/UIE2E/VoiceBarUIE2ETests/Gate2245Tests.swift'
FLOW_TESTS = ROOT / 'flow-bar/UIE2E/VoiceBarUIE2ETests/VoiceBarFlowTests.swift'
PERMISSIONS = ROOT / 'scripts/voicebar-ui-e2e-permissions.swift'
GATEKEEPER_TITLE = 'BrainBar is an app downloaded from the Internet'
# Retained FASTBC1 host entry: symbolic hotkey 52 "Turn Dock Hiding On/Off" = ⌥⌘D, enabled.
HOST_HOTKEYS = plistlib.dumps({'AppleSymbolicHotKeys': {
    '52': {'enabled': True, 'value': {'parameters': [100, 2, 1572864], 'type': 'standard'}},
    '65': {'enabled': True, 'value': {'parameters': [32, 49, 1572864], 'type': 'standard'}},
    '7': {'enabled': False, 'value': {'parameters': [97, 0, 1048576], 'type': 'standard'}},
    '99': {'enabled': True}}})


def supervisor():
    spec = importlib.util.spec_from_file_location('gatecap1_supervisor', ROOT / 'scripts/voicebar-ui-e2e-supervisor.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def block(path, marker):
    source = path.read_text()
    begin, end = '// BEGIN ' + marker + '\n', '// END ' + marker
    if begin not in source:
        raise AssertionError(marker + ' block missing from ' + path.name)
    return source.split(begin, 1)[1].split(end, 1)[0]


def run_swift(test, source):
    with tempfile.TemporaryDirectory() as tmp:
        path = pathlib.Path(tmp)
        (path / 'main.swift').write_text(source)
        build = subprocess.run(['xcrun', 'swiftc', str(path / 'main.swift'), '-o', str(path / 'probe')],
                               capture_output=True, text=True)
        test.assertEqual(build.returncode, 0, build.stderr)
        result = subprocess.run([str(path / 'probe')], capture_output=True, text=True)
        test.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result.stdout


class FixtureCommandChannel(unittest.TestCase):
    def test_fixture_commands_are_notifications_never_keystrokes(self):
        app = GATE_APP.read_text()
        self.assertNotIn('keyEquivalentModifierMask', app)
        self.assertNotIn('Array("0123456789abcdef")', app)
        tests = GATE_TESTS.read_text()
        self.assertNotIn('typeKey(', tests)
        self.assertNotIn('.option', tests)
        # The sandboxed runner can only post name-only notifications (no userInfo, no file writes).
        self.assertIn('postNotificationName(', tests)
        self.assertIn('object: nil, userInfo: nil, deliverImmediately: true', tests)

    def test_app_and_runner_agree_on_names_and_reject_foreign_tokens(self):
        probe = r'''
let token = "vl-ui-AbC123"
let names = ["start", "pending", "fast-bc"]
let posted = uie2eFixtureCommandName(token: token, command: "fast-bc")
precondition(posted == UIE2EFixtureCommand.notificationName(token: token, command: "fast-bc"), "prefix drift")
precondition(UIE2EFixtureCommand.command(from: posted, token: token, allowed: names) == "fast-bc")
precondition(UIE2EFixtureCommand.command(from: uie2eFixtureCommandName(token: "vl-ui-Other1", command: "fast-bc"),
    token: token, allowed: names) == nil, "another sandbox's command must be ignored")
precondition(UIE2EFixtureCommand.command(from: uie2eFixtureCommandName(token: token, command: "rm"),
    token: token, allowed: names) == nil, "unknown command must be ignored")
precondition(UIE2EFixtureCommand.command(from: "com.apple.dock.autohide", token: token, allowed: names) == nil)
let ack = try! JSONSerialization.data(withJSONObject: ["count": 14, "name": "fast-bc"])
precondition(uie2eFixtureAck(ack)! == (14, "fast-bc"))
precondition(uie2eFixtureAck(nil) == nil && uie2eFixtureAck(Data("x".utf8)) == nil)
// FASTBC1: the swallowed ⌥⌘D left step 28's pending receipt; it must never pass as fast-bc's.
let stale: [String: Any] = ["action": "selection:pending", "fixtureCommand": ["count": 13, "name": "pending"]]
precondition(!uie2eReceiptIsFrom(stale, count: 14, name: "fast-bc"))
precondition(!uie2eReceiptIsFrom(["action": "selection:fast-bc"], count: 14, name: "fast-bc"))
precondition(uie2eReceiptIsFrom(["fixtureCommand": ["count": 14, "name": "fast-bc"]], count: 14, name: "fast-bc"))
print("PASS")
'''
        source = ('import Foundation\n' + block(GATE_APP, 'UIE2E FIXTURE COMMANDS')
                  + block(GATE_TESTS, 'UIE2E FIXTURE COMMANDS') + probe)
        self.assertEqual(run_swift(self, source).strip(), 'PASS')

    def test_listener_acks_before_running_never_under_a_modal_and_stamps_receipts(self):
        app = GATE_APP.read_text()
        listener = app.split('final class UIE2EFixtureCommandListener', 1)[1].split('extension UIE2EHost', 1)[0]
        self.assertIn('NSApp.modalWindow == nil', listener)
        self.assertLess(listener.index('file: UIE2EFixtureCommand.ackFile'), listener.index('host.hide1VisualCommand(command)'),
                        'a capture-failure command enters the NSAlert modal loop; ack must precede it')
        snapshot = app.split('    func snapshot(_ action: String) {', 1)[1].split('\n    }\n', 1)[0]
        self.assertIn('"fixtureCommand"', snapshot)
        sel = GATE_TESTS.read_text().split('step("GATE2246 SEL " + name) {', 1)[1].split('let messages', 1)[0]
        self.assertIn('uie2eReceiptIsFrom', sel)
        self.assertLess(sel.index('uie2eReceiptIsFrom'), sel.index('let receipt = gateRead'))

    def test_symbolic_hotkey_preflight_finds_the_run03_collision(self):
        module = supervisor()
        old_fixture_keys = [(k, ('command', 'option')) for k in '0123456789abcdef']
        self.assertEqual(module.symbolic_hotkey_collisions(HOST_HOTKEYS, old_fixture_keys), [52])
        self.assertEqual(module.symbolic_hotkey_collisions(HOST_HOTKEYS, [('a', ('command',))]), [],
                         'disabled hotkeys never collide')
        self.assertEqual(module.symbolic_hotkey_collisions(HOST_HOTKEYS, []), [])
        with self.assertRaises(module.HotkeyCollision):
            module.symbolic_hotkey_collisions(b'not a plist', [('a', ('command',))])
        self.assertEqual(module.SCENARIO_KEYSTROKES['gate2246'], ())
        self.assertEqual(module.SCENARIO_KEYSTROKES['hide1'], ())

    def test_every_modifier_keystroke_in_the_suite_is_declared_for_its_preflight(self):
        module = supervisor()
        declared = {(key, tuple(sorted(mods))) for keys in module.SCENARIO_KEYSTROKES.values() for key, mods in keys}
        for path in FLOW_TESTS.parent.glob('*.swift'):
            for key, flags in re.findall(r'typeKey\("(.)", modifierFlags:\s*(\[[^\]]*\]|\.\w+)\)', path.read_text()):
                mods = tuple(sorted({'command': 'command', 'option': 'option', 'control': 'control', 'shift': 'shift'}[m]
                                    for m in re.findall(r'\.(\w+)', flags)))
                if mods:
                    self.assertIn((key, mods), declared, path.name + ' sends an undeclared shortcut')

    def test_native_preflight_refuses_a_bound_keystroke_before_mute_or_launch(self):
        module = supervisor()
        with tempfile.TemporaryDirectory() as tmp:
            output = pathlib.Path(tmp)
            (output / 'sandbox-path.txt').write_text(str(output / 'sandbox'))
            host = module.NativeHost(output, 'full')
            bound = plistlib.dumps({'AppleSymbolicHotKeys': {'200': {'enabled': True,
                                    'value': {'parameters': [97, 0, 1048576], 'type': 'standard'}}}})
            host.symbolic_hotkeys = lambda: SimpleNamespace(returncode=0, stdout=bound)
            touched = []
            host.host_settings = lambda: touched.append('settings') or {}
            host.muted = lambda: touched.append('mute') or True
            host.prepare_resident = lambda: touched.append('launch')
            host.stop = lambda: True
            host.restore_resident = lambda: None
            host.guard_mute = lambda: None
            with contextlib.redirect_stderr(io.StringIO()), contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(module.supervise(host), 2)
            receipt = json.loads((output / 'operator-state.json').read_text())
            self.assertEqual(receipt['verdict'], 'PREFLIGHT_REFUSED')
            self.assertEqual(receipt['preflight']['symbolicHotkeyCollisions'], [200])
            self.assertEqual(touched, [], 'nothing may run once a keystroke collides')
            self.assertIn('global macOS shortcut', (output / 'supervisor-preflight.log').read_text())
            host = module.NativeHost(output, 'gate2246')
            host.symbolic_hotkeys = lambda: self.fail('no keystrokes: the table is not needed')
            host.refuse_hotkey_collisions()
            self.assertEqual(host.preflight['symbolicHotkeyCollisions'], [])


class HostSettings(unittest.TestCase):
    def fake(self, after):
        calls = []
        class Host:

            reads = 0
            def host_settings(self):
                Host.reads += 1
                return {'com.apple.dock autohide': '0' if Host.reads == 1 else after, '-g AppleKeyboardUIMode': '2'}
            def muted(self): return True
            def set_mute(self, value): calls.append(('mute', value))
            def guard_mute(self): pass
            def prepare_resident(self): pass
            def start(self): self.child = True
            def poll(self): return 0
            def check(self): pass
            def wait(self, seconds): pass
            def stop(self): return True
            def restore_resident(self): pass
            def export(self): return 0
            def save(self, receipt): calls.append(dict(receipt))
        return Host(), calls

    def test_dock_autohide_flip_is_reported_and_fails_without_restoring(self):
        module = supervisor()
        host, calls = self.fake('1')
        with contextlib.redirect_stderr(io.StringIO()), contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(module.supervise(host), 1)
        receipt = calls[-1]
        self.assertEqual(receipt['hostSettingsChanged'], {'com.apple.dock autohide': {'before': '0', 'after': '1'}})
        self.assertTrue(any('NOT restored' in e and 'com.apple.dock autohide' in e for e in receipt['cleanupErrors']))
        self.assertEqual(receipt['verdict'], 'FAIL')
        host, calls = self.fake('0')
        with contextlib.redirect_stderr(io.StringIO()), contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(module.supervise(host), 0)
        self.assertNotIn('hostSettingsChanged', calls[-1])

    def test_native_snapshot_reads_only_and_redacts_free_text(self):
        module = supervisor()
        with tempfile.TemporaryDirectory() as tmp:
            output = pathlib.Path(tmp)
            (output / 'sandbox-path.txt').write_text(str(output / 'sandbox'))
            host = module.NativeHost(output, 'gate2246')
            seen = []
            def run(args, **kwargs):
                seen.append(args)
                if args[:2] != ['defaults', 'read'] and args[:2] != ['defaults', 'export']:
                    raise AssertionError('only defaults read/export allowed: %r' % args)
                if args[-1] == 'autohide':
                    return SimpleNamespace(returncode=1, stdout='', stderr='does not exist')
                if args[-1] == 'AppleSelectedInputSources':
                    return SimpleNamespace(returncode=0, stdout='( { "KeyboardLayout Name" = Private; } )\n')
                if args[1] == 'export':
                    return SimpleNamespace(returncode=0, stdout=HOST_HOTKEYS)
                return SimpleNamespace(returncode=0, stdout='2\n')
            with patch.object(module.subprocess, 'run', run):
                values = host.host_settings()
            self.assertIsNone(values['com.apple.dock autohide'], 'an absent key is recorded, so absent -> 1 is caught')
            self.assertEqual(values['-g AppleKeyboardUIMode'], '2')
            self.assertRegex(values['com.apple.HIToolbox AppleSelectedInputSources'], r'^<redacted len=\d+ sha256=')
            self.assertRegex(values['com.apple.symbolichotkeys'], r'^<redacted len=\d+ sha256=')
            self.assertNotIn('Private', json.dumps(values))
            self.assertFalse(any('write' in a for a in seen))


class QAOnlyFrames(unittest.TestCase):
    def test_step_frames_never_attach_the_full_display(self):
        source = FLOW_TESTS.read_text()
        step = source.split('    func step(', 1)[1].split('    @discardableResult', 1)[0]
        self.assertNotIn('XCTAttachment(screenshot:', step)
        self.assertNotIn('HIDE1VIS-CROP', source)
        self.assertIn('qaOnlyFrame()', step)
        self.assertIn('"capture": capture', step)
        self.assertNotIn('XCTAttachment(screenshot:', ''.join(p.read_text() for p in FLOW_TESTS.parent.glob('*.swift')))

    def test_composite_keeps_only_qa_regions_and_blacks_out_the_rest(self):
        probe = r'''
// A 200x100-point display at 2x: top half "private desktop" red, bottom half blue.
let space = CGColorSpaceCreateDeviceRGB()
let ctx = CGContext(data: nil, width: 400, height: 200, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 400, height: 100))
ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1)); ctx.fill(CGRect(x: 0, y: 100, width: 400, height: 100))
let display = ctx.makeImage()!
func rgb(_ image: CGImage, _ x: Int, _ y: Int) -> [UInt8] {   // top-left pixel coordinates
    var px = [UInt8](repeating: 0, count: 4)
    let c = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: space,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    c.draw(image, in: CGRect(x: -x, y: y - image.height + 1, width: image.width, height: image.height))
    let (r, b) = (px[0], px[2])   // Colour management shifts exact values; compare dominant channels.
    return r > 200 && b < 80 ? [255, 0, 0] : b > 200 && r < 80 ? [0, 0, 255] : max(px[0], px[1], px[2]) < 20 ? [0, 0, 0] : Array(px[0..<3])
}
let one = uie2eQAOnlyFrame(display, screen: CGSize(width: 200, height: 100), regions: [CGRect(x: 10, y: 10, width: 20, height: 10)])!
precondition(one.width == 40 && one.height == 20, "canvas is the QA region only")
precondition(rgb(one, 0, 0) == [255, 0, 0] && rgb(one, 39, 19) == [255, 0, 0], "top-left orientation")
let two = uie2eQAOnlyFrame(display, screen: CGSize(width: 200, height: 100),
    regions: [CGRect(x: 0, y: 0, width: 10, height: 10), CGRect(x: 190, y: 90, width: 10, height: 10)])!
precondition(two.width == 400 && two.height == 200)
precondition(rgb(two, 5, 5) == [255, 0, 0] && rgb(two, 395, 195) == [0, 0, 255], "regions keep their pixels")
precondition(rgb(two, 200, 100) == [0, 0, 0] && rgb(two, 395, 5) == [0, 0, 0], "everything outside a region is black")
precondition(uie2eQAOnlyFrame(display, screen: CGSize(width: 200, height: 100), regions: []) == nil)
precondition(uie2eQAOnlyFrame(display, screen: CGSize(width: 200, height: 100),
    regions: [CGRect(x: 500, y: 500, width: 10, height: 10)]) == nil, "off-screen QA windows capture nothing")
print("PASS")
'''
        source = 'import AppKit\n' + block(FLOW_TESTS, 'UIE2E QA-ONLY FRAME') + probe
        self.assertEqual(run_swift(self, source).strip(), 'PASS')


    def test_exporter_rejects_any_frame_or_movie_not_sourced_from_qa_windows(self):
        spec = importlib.util.spec_from_file_location('gatecap1_results', ROOT / 'scripts/voicebar-ui-e2e-results.py')
        results = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(results)
        qa = dict(source='qa-windows', fullDisplayPersisted=False)
        movie = dict(path='run.mov', valid=True, durationSeconds=1, bytes=5,
                     captureSource=dict(kind='application', bundle='com.voicelayer.voicebar.uie2e', fullDisplay=False))
        with tempfile.TemporaryDirectory() as tmp:
            directory = pathlib.Path(tmp)
            (directory / 'a.png').write_bytes(b'png')
            manifest = [dict(attachments=[dict(suggestedHumanReadableName='UIE2E-0001', exportedFileName='a.png',
                                               isAssociatedWithFailure=False)])]
            step = dict(number=1, name='frame', attachment='UIE2E-0001', passed=True)
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertTrue(results.report(directory, [dict(step, capture=qa)], manifest, movie))
                for capture in [None, dict(source='display', fullDisplayPersisted=True), dict(source='qa-windows')]:
                    with self.subTest(capture=capture), self.assertRaisesRegex(ValueError, 'not the QA window'):
                        results.report(directory, [dict(step, capture=capture) if capture else step], manifest, movie)
                for source in [None, dict(kind='display', bundle='com.voicelayer.voicebar.uie2e', fullDisplay=True),
                               dict(kind='application', bundle='com.apple.finder', fullDisplay=False)]:
                    with self.subTest(source=source), self.assertRaisesRegex(ValueError, 'not the QA app'):
                        results.report(directory, [dict(step, capture=qa)], manifest, dict(movie, captureSource=source))


class ForeignModals(unittest.TestCase):
    def test_classifier_flags_gatekeeper_and_foreign_sheets_but_not_the_product_alert(self):
        probe = r'''
let region = CGRect(x: 600, y: 200, width: 400, height: 300)
let far = CGRect(x: 0, y: 900, width: 260, height: 274)
let over = CGRect(x: 700, y: 250, width: 200, height: 100)
let windows = [
    ObservedWindow(owner: "com.apple.coreservices.uiagent", pid: 1, title: "Gatekeeper", frame: far, modal: true, sheet: false),
    ObservedWindow(owner: "com.apple.SecurityAgent", pid: 2, title: "Password", frame: far, modal: true, sheet: false),
    ObservedWindow(owner: "com.apple.UserNotificationCenter", pid: 3, title: "", frame: .zero, modal: true, sheet: false),
    ObservedWindow(owner: qaBundle, pid: 4, title: "VoiceLayer microphone permission needs attention", frame: over, modal: true, sheet: false),
    ObservedWindow(owner: "com.apple.dt.Xcode", pid: 5, title: "Save", frame: over, modal: true, sheet: true),
    ObservedWindow(owner: "com.apple.TextEdit", pid: 6, title: "vapi.env", frame: over, modal: false, sheet: false),
    ObservedWindow(owner: "com.apple.Preview", pid: 7, title: "Print", frame: far, modal: true, sheet: true),
    ObservedWindow(owner: "com.example.app", pid: 8, title: "Quit?", frame: over, modal: true, sheet: false)]
let found = foreignModals(windows, region: region)
print(found.map { "\($0["owner"]!)|\($0["source"]!)" }.joined(separator: ","))
precondition(captureRegion([], display: CGRect(x: 0, y: 0, width: 1728, height: 1117)) == CGRect(x: 0, y: 0, width: 1728, height: 1117))
precondition(captureRegion([CGRect(x: 0, y: 0, width: 10, height: 10), CGRect(x: 20, y: 20, width: 10, height: 10)],
    display: .zero) == CGRect(x: 0, y: 0, width: 30, height: 30))
'''
        source = 'import Foundation\nimport CoreGraphics\n' + block(PERMISSIONS, 'FOREIGN MODALS') + probe
        self.assertEqual(run_swift(self, source).strip(),
                         'com.apple.coreservices.uiagent|system-owner,com.apple.SecurityAgent|system-owner,'
                         'com.apple.dt.Xcode|sheet,com.example.app|modal')

    def test_helper_reports_modals_and_keeps_its_prompt_exit_status(self):
        source = PERMISSIONS.read_text()
        self.assertIn('"modals":modals', source)
        self.assertIn('exit(prompts.isEmpty && AXIsProcessTrusted() ? 0:2)', source)
        for action in ['AXPress', 'AXUIElementPerformAction', 'CGEventPost', 'AXRaise']:
            self.assertNotIn(action, source, 'the helper must never interact with any window')

    def native(self, module, output, modals):
        (output / 'sandbox-path.txt').write_text(str(output / 'sandbox'))
        payload = dict(axTrusted=True, prompts=[])
        if modals is not None:
            payload['modals'] = modals
        helper = output / 'voicebar-ui-e2e-permissions'
        helper.write_text('#!/bin/sh\nprintf %s ' + repr(json.dumps(payload)) + '\nexit 0\n')
        helper.chmod(0o755)
        return module.NativeHost(output, 'gate2246')

    def test_gatekeeper_dialog_refuses_preflight_with_owner_and_redacted_title(self):
        module = supervisor()
        gatekeeper = [dict(owner='com.apple.coreservices.uiagent', pid=611, title=GATEKEEPER_TITLE, source='system-owner')]
        with tempfile.TemporaryDirectory() as tmp:
            output = pathlib.Path(tmp)
            host = self.native(module, output, gatekeeper)
            with self.assertRaises(module.ForeignModal) as stop:
                host.prepare_resident()
            log = (output / 'supervisor-preflight.log').read_text()
            for text in [str(stop.exception), log]:
                self.assertIn('owner=com.apple.coreservices.uiagent', text)
                self.assertRegex(text, r'title=<redacted len=%d sha256=' % len(GATEKEEPER_TITLE))
                self.assertNotIn('BrainBar', text)
            self.assertEqual(stop.exception.modals[0]['source'], 'system-owner')
            host.save({})
            self.assertNotIn('BrainBar', '\n'.join(p.read_text() for p in output.iterdir() if p.suffix in ['.json', '.log']))
            host.collect_owned = lambda: None
            host.muted = lambda: True
            with self.assertRaises(module.ForeignModal):
                host.check()  # Every fixture boundary falls inside the supervisor's 1 s check loop.

    def test_missing_inventory_and_free_text_owner_fail_closed(self):
        module = supervisor()
        with tempfile.TemporaryDirectory() as tmp:
            host = self.native(module, pathlib.Path(tmp), None)
            with self.assertRaisesRegex(RuntimeError, 'modal inventory unreadable'):
                host.prepare_resident()
        receipt = module.modal_receipt(dict(modals=[dict(owner='Etan private window', title='x', source='weird')]))
        self.assertRegex(receipt[0]['owner'], r'^<redacted len=19 ')
        self.assertEqual(receipt[0]['source'], 'unknown')

    def test_mid_run_modal_stops_with_exit_2_and_never_signals_the_dialog(self):
        module = supervisor()
        for launched in [False, True]:
            calls = []
            modal = module.ForeignModal('STOP: foreign modal', [dict(owner='com.apple.coreservices.uiagent', pid=611,
                                                                       source='system-owner', title='<redacted len=1 sha256=0>')])
            class Host:

                def muted(self): return True
                def set_mute(self, value): pass
                def guard_mute(self): pass
                def prepare_resident(self):
                    if not launched: raise modal
                def start(self): self.child = True
                def poll(self): return None
                def check(self): raise modal
                def wait(self, seconds): pass
                def stop(self): calls.append('stop'); return True
                def restore_resident(self): calls.append('restore')
                def save(self, receipt): calls.append(dict(receipt))
            with self.subTest(launched=launched), contextlib.redirect_stderr(io.StringIO()), \
                    contextlib.redirect_stdout(io.StringIO()) as out:
                self.assertEqual(module.supervise(Host()), 2)
                receipt = calls[-1]
                self.assertEqual(receipt['verdict'], 'FOREIGN_MODAL_STOP' if launched else 'PREFLIGHT_REFUSED')
                self.assertEqual(receipt['foreignModal'][0]['owner'], 'com.apple.coreservices.uiagent')
                self.assertIn('stop', calls, 'owned processes are still cleaned up; the dialog itself is untouched')
                self.assertIn('exit=2', out.getvalue())


if __name__ == '__main__':
    unittest.main()
