#!/usr/bin/env python3
"""GATECAP1: no global-shortcut collisions, window-ID QA-only frames, fail-closed foreign-modal STOP.

Round 2 tests reproduce Sol's R1-R6. No native app, keystroke, click or capture is performed:
Swift probes compile and run the real marked blocks against synthetic inputs.
"""
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
CAPTURE = ROOT / 'scripts/voicebar-ui-e2e-capture.swift'
GATEKEEPER_TITLE = 'BrainBar is an app downloaded from the Internet'
CMD, OPT, FN = 1 << 20, 1 << 19, 1 << 23


def hotkeys(entries):
    return plistlib.dumps({'AppleSymbolicHotKeys': {
        str(n): ({'enabled': True, 'value': {'parameters': p, 'type': 'standard'}} if isinstance(p, list) else p)
        for n, p in entries.items()}})


# Retained FASTBC1 host entry 52 (⌥⌘D Dock hiding), the host's unassigned record 175, and a disabled entry.
HOST_HOTKEYS = hotkeys({52: [100, 2, CMD | OPT], 175: [65535, 65535, 0],
                        7: {'enabled': False, 'value': {'parameters': [97, 0, CMD], 'type': 'standard'}}})


def supervisor():
    spec = importlib.util.spec_from_file_location('gatecap1_supervisor', ROOT / 'scripts/voicebar-ui-e2e-supervisor.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def results_module():
    spec = importlib.util.spec_from_file_location('gatecap1_results', ROOT / 'scripts/voicebar-ui-e2e-results.py')
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


MODALS_PRELUDE = 'import Foundation\nimport CoreGraphics\nimport CryptoKit\n'
FAKE_SOURCE = r'''
final class Fake: ModalSource {
    typealias Element = String
    var rows: [CGRow]? = []
    var windowsByPid: [Int32: AXRead<[String]>] = [:]
    var modal: [String: AXRead<Bool>] = [:]
    var kids: [String: AXRead<[String]>] = [:]
    var roles: [String: AXRead<String>] = [:]
    func windows() -> [CGRow]? { rows }
    func axWindows(_ pid: Int32) -> AXRead<[String]> { windowsByPid[pid] ?? .value([]) }
    func isModal(_ w: String) -> AXRead<Bool> { modal[w] ?? .value(false) }
    func children(_ w: String) -> AXRead<[String]> { kids[w] ?? .value([]) }
    func role(_ e: String) -> AXRead<String> { roles[e] ?? .value("AXButton") }
    func title(_ e: String) -> String { e }
}
func row(_ id: UInt32, _ pid: Int32, _ owner: String, layer: Int = 0, _ frame: CGRect? = CGRect(x: 0, y: 0, width: 300, height: 200), alpha: Double = 1) -> CGRow {
    CGRow(id: id, pid: pid, owner: owner, layer: layer, bounds: frame, alpha: alpha, title: "t\(id)")
}
func summary(_ inv: ModalInventory) -> String {
    (inv.modals.map { "\($0["owner"]!)|\($0["source"]!)" } + inv.errors.map { "ERR \($0["kind"]!)" }).joined(separator: ",")
}
'''


class FixtureCommandChannel(unittest.TestCase):
    def test_fixture_commands_are_notifications_never_keystrokes(self):
        app = GATE_APP.read_text()
        self.assertNotIn('keyEquivalentModifierMask', app)
        self.assertNotIn('Array("0123456789abcdef")', app)
        tests = GATE_TESTS.read_text()
        self.assertNotIn('typeKey(', tests)
        self.assertNotIn('.option', tests)
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
let ack = try! JSONSerialization.data(withJSONObject: ["count": 14, "name": "fast-bc"])
precondition(uie2eFixtureAck(ack)! == (14, "fast-bc"))
precondition(uie2eFixtureAck(nil) == nil && uie2eFixtureAck(Data("x".utf8)) == nil)
// FASTBC1: the swallowed ⌥⌘D left step 28's pending receipt; it must never pass as fast-bc's.
let stale: [String: Any] = ["action": "selection:pending", "fixtureCommand": ["count": 13, "name": "pending"]]
precondition(!uie2eReceiptIsFrom(stale, count: 14, name: "fast-bc"))
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
        self.assertLess(listener.index('file: UIE2EFixtureCommand.ackFile'), listener.index('host.hide1VisualCommand(command)'))
        snapshot = app.split('    func snapshot(_ action: String) {', 1)[1].split('\n    }\n', 1)[0]
        self.assertIn('"fixtureCommand"', snapshot)
        sel = GATE_TESTS.read_text().split('step("GATE2246 SEL " + name) {', 1)[1].split('let messages', 1)[0]
        self.assertLess(sel.index('uie2eReceiptIsFrom'), sel.index('let receipt = gateRead'))


class SymbolicHotkeys(unittest.TestCase):
    """R5: physical keycode AND full modifier set; unevaluable enabled entries are NOT_PROVEN."""
    CMD_A = ('a', 0, ('command',))

    def test_sol_reproduction_keycode_entries_now_collide(self):
        module = supervisor()
        for parameters in ([97, 0, CMD], [65535, 0, CMD], [65, 0, CMD]):
            with self.subTest(parameters=parameters):
                self.assertEqual(module.symbolic_hotkey_collisions(hotkeys({200: parameters}), [self.CMD_A]), [200])

    def test_full_modifier_set_and_character_matching(self):
        module = supervisor()
        collide = module.symbolic_hotkey_collisions
        self.assertEqual(collide(hotkeys({200: [97, 0, CMD | FN]}), [self.CMD_A]), [], 'fn+⌘A is a different chord')
        self.assertEqual(collide(hotkeys({200: [97, 0, CMD | OPT]}), [self.CMD_A]), [], '⌥⌘A is a different chord')
        self.assertEqual(collide(hotkeys({200: [97, 65535, CMD]}), [self.CMD_A]), [200], 'character-only entry')
        self.assertEqual(collide(hotkeys({200: [97, 0, CMD | (1 << 16)]}), [self.CMD_A]), [200], 'caps lock is ignored')
        old_fixture_keys = [(k, None, ('command', 'option')) for k in '0123456789abcdef']
        self.assertEqual(collide(HOST_HOTKEYS, old_fixture_keys), [52])
        self.assertEqual(collide(HOST_HOTKEYS, [self.CMD_A]), [], 'disabled and unassigned records never collide')
        # Text entry (typeText): any enabled shortcut on an unmodified printable key collides.
        self.assertEqual(collide(hotkeys({201: [65535, 12, 0]}), [module.TEXT_ENTRY]), [201])
        self.assertEqual(collide(hotkeys({201: [65535, 12, CMD]}), [module.TEXT_ENTRY]), [])

    def test_unevaluable_enabled_entries_are_not_proven(self):
        module = supervisor()
        for entry in ([65535, 65535, CMD], [97, 0], ['x', 0, CMD], [97, 0, CMD | (1 << 30)], {'enabled': True},
                      {'enabled': True, 'value': {'parameters': 'junk'}}):
            with self.subTest(entry=entry), self.assertRaisesRegex(module.HotkeyCollision, 'NOT_PROVEN'):
                module.symbolic_hotkey_collisions(hotkeys({300: entry}), [self.CMD_A])
        with self.assertRaisesRegex(module.HotkeyCollision, 'NOT_PROVEN'):
            module.symbolic_hotkey_collisions(b'not a plist', [self.CMD_A])

    def test_every_injected_keystroke_is_declared_by_keycode(self):
        module = supervisor()
        declared = set(module.SCENARIO_KEYSTROKES['full'])
        names = {'.delete': (None, 51, ()), '.return': (None, 36, ()), '.escape': (None, 53, ())}
        ansi = {'a': 0}
        self.assertEqual(module.SCENARIO_KEYSTROKES['gate2246'], ())
        self.assertEqual(module.SCENARIO_KEYSTROKES['hide1'], ())
        for path in FLOW_TESTS.parent.glob('*.swift'):
            source = path.read_text()
            for key, flags in re.findall(r'typeKey\(("."|\.\w+), modifierFlags:\s*(\[[^\]]*\]|\.\w+)\)', source):
                mods = tuple(sorted(re.findall(r'\.(\w+)', flags)))
                entry = names[key] if key.startswith('.') else (key[1], ansi[key[1]], mods)
                self.assertIn(entry, declared, path.name + ' injects an undeclared keystroke')
            if 'typeText(' in source:
                self.assertIn(module.TEXT_ENTRY, declared)

    def test_native_preflight_refuses_a_bound_keystroke_before_mute_or_launch(self):
        module = supervisor()
        with tempfile.TemporaryDirectory() as tmp:
            output = pathlib.Path(tmp)
            (output / 'sandbox-path.txt').write_text(str(output / 'sandbox'))
            host = module.NativeHost(output, 'full')
            host.symbolic_hotkeys = lambda: SimpleNamespace(returncode=0, stdout=hotkeys({200: [65535, 0, CMD]}))
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
        self.assertTrue(any('NOT restored' in e for e in receipt['cleanupErrors']))
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
                assert args[:2] in (['defaults', 'read'], ['defaults', 'export']), args
                if args[-1] == 'autohide':
                    return SimpleNamespace(returncode=1, stdout='', stderr='does not exist')
                if args[-1] == 'AppleSelectedInputSources':
                    return SimpleNamespace(returncode=0, stdout='( { "KeyboardLayout Name" = Private; } )\n')
                if args[1] == 'export':
                    return SimpleNamespace(returncode=0, stdout=HOST_HOTKEYS)
                return SimpleNamespace(returncode=0, stdout='2\n')
            with patch.object(module.subprocess, 'run', run):
                values = host.host_settings()
            self.assertIsNone(values['com.apple.dock autohide'])
            self.assertRegex(values['com.apple.HIToolbox AppleSelectedInputSources'], r'^<redacted len=\d+ hmac-sha256=')  # REDACT2
            self.assertNotIn('Private', json.dumps(values))
            self.assertFalse(any('write' in a for a in seen))


class WindowIsolatedFrames(unittest.TestCase):
    """R1: no desktop crop; window-ID capture of the proven QA process only, else NOT_PROVEN."""

    def test_no_desktop_sample_or_crop_remains_anywhere(self):
        tests = ''.join(p.read_text() for p in FLOW_TESTS.parent.glob('*.swift'))
        for banned in ['XCUIScreen.main.screenshot', 'XCTAttachment(screenshot:', 'uie2eQAOnlyFrame', 'HIDE1VIS-CROP',
                       '.screenshot()']:
            self.assertNotIn(banned, tests)
        helper = PERMISSIONS.read_text()
        self.assertIn('SCContentFilter(desktopIndependentWindow: window)', helper)
        self.assertNotIn('SCContentFilter(display:', helper)
        self.assertNotIn('excludingWindows', CAPTURE.read_text())
        step = FLOW_TESTS.read_text().split('    func step(', 1)[1].split('    @discardableResult', 1)[0]
        self.assertIn('boundary("still")', step)
        self.assertIn('XCTAttachment(data: png', step)
        self.assertLess(step.index('capture["status"] as? String == "PROVEN"'), step.index('XCTAttachment(data: png'))

    def test_only_the_proven_process_windows_are_capture_targets(self):
        probe = FAKE_SOURCE + r'''
let qa = CGRect(x: 600, y: 140, width: 400, height: 120)
let rows = [row(1, 77, "com.apple.TextEdit", qa),                       // foreign editor overlapping the pill
            row(2, 42, qaBundle, qa),                                   // the QA pill
            row(3, 42, qaBundle, CGRect(x: 0, y: 0, width: 50, height: 50), alpha: 0),   // hidden QA window
            row(4, 42, qaBundle, nil),                                  // geometry unreadable / moving
            row(5, 43, qaBundle, qa)]                                   // a stale QA app from another run
precondition(provenQAWindows(rows, qaPid: 42).map(\.id) == [2], "only visible windows of the proven process")
precondition(provenQAWindows(rows, qaPid: nil).isEmpty, "no proven process: nothing is captured")
let exe = "/private/tmp/vl-ui-AbC/VoiceBarQA.app/Contents/MacOS/VoiceBar"
func candidate(_ pid: Int32, _ path: String) -> (pid: Int32, read: QAIdentityRead) {
    (pid, .live(QAIdentity(pid: pid, path: path, birth: [100, 20])))
}
precondition(provenQAPid(executable: exe, candidates: [candidate(42, exe), candidate(43, "/private/tmp/vl-ui-OLD/VoiceBarQA.app/Contents/MacOS/VoiceBar")]) == 42)
precondition(provenQAPid(executable: exe, candidates: [candidate(42, exe), candidate(44, exe)]) == nil, "ambiguous: NOT_PROVEN")
precondition(provenQAPid(executable: exe, candidates: []) == nil)
print("PASS")
'''
        self.assertEqual(run_swift(self, MODALS_PRELUDE + block(PERMISSIONS, 'FOREIGN MODALS') + probe).strip(), 'PASS')

    def test_expected_absent_proof_requires_a_successful_inventory_with_zero_qa_windows(self):
        probe = FAKE_SOURCE + r'''
let qa = CGRect(x: 600, y: 140, width: 400, height: 120)
let empty = CGRect(x: 0, y: 0, width: 0, height: 0)
let identity = QAIdentity(pid: 42, path: "/qa", birth: [100, 20])
precondition(expectedAbsentProof(nil, identity: identity) == nil, "failed CG read: no proof")
precondition(expectedAbsentProof([row(1, 42, qaBundle, qa)], identity: identity) == nil, "visible QA window")
precondition(expectedAbsentProof([row(1, 42, qaBundle, nil)], identity: identity) == nil, "unreadable QA geometry")
let hidden = expectedAbsentProof([row(1, 42, qaBundle, qa, alpha: 0), row(2, 42, qaBundle, empty), row(3, 7, "com.apple.TextEdit", qa)],
                                 identity: identity)!
precondition(hidden["cgInventory"] as? String == "ok" && hidden["qaPid"] as? Int == 42 && hidden["onScreenQAWindows"] as? Int == 0)
precondition(expectedAbsentProof([], identity: nil) == nil, "termination is not hidden proof")
precondition(expectedAbsentProof([], identity: nil) == nil, "ambiguous QA process: no proof")
print("PASS")
'''
        self.assertEqual(run_swift(self, MODALS_PRELUDE + block(PERMISSIONS, 'FOREIGN MODALS') + probe).strip(), 'PASS')

    def test_hidden_expectation_is_declared_only_on_hidden_state_steps(self):
        step = FLOW_TESTS.read_text().split('    func step(', 1)[1].split('    @discardableResult', 1)[0]
        self.assertIn('uie2eFrameFailure(capture, contract: evidenceContract)', step)
        self.assertIn('"evidenceContract": evidenceContract', step)
        probe = r'''
let hidden = [("HIDE1VIS speaking hidden", "hide1"), ("GATE2246 HIDE background failure", "gate2246"),
              ("GATE2246 HIDE recovered failure", "gate2246"), ("GATE2246 HIDE user-f5 dismiss Later", "gate2246"),
              ("launch isolated QA app", "gate2246"),
              ("GUARD launch 1 installed", "hide1"), ("HIDE1VIS no-device guard installed before fixtures", "hide1"),
              ("GATE2246 no device-start or process tripwire invoked", "gate2246")]
let visible = [("HIDE1VIS speaking before", "hide1"), ("HIDE1VIS speaking shown", "hide1"),
               ("GATE2246 HIDE user-f5 failure", "gate2246"), ("GATE2246 HIDE visible dismiss Later", "gate2246"),
               ("GATE2246 HIDE background dismiss Later", "gate2246"), ("GATE2246 HIDE user-f5 shown", "gate2246"),
               ("GATE2246 HIDE user-f5 before", "gate2246"), ("GATE2246 SEL fast-bc", "gate2246"),
               ("launch isolated QA app", "full"), ("GUARD launch 1 installed", "full"),
               ("GATE2245 no-device guard installed before fixtures", "full"), ("click Save", "full")]
for (name, scenario) in hidden { precondition(uie2eExpectsHiddenQA(step: name, scenario: scenario), name) }
for (name, scenario) in visible { precondition(!uie2eExpectsHiddenQA(step: name, scenario: scenario), name) }
print("PASS")
'''
        source = 'import Foundation\nimport CryptoKit\n' + block(FLOW_TESTS, 'UIE2E BOUNDARY') + probe
        self.assertEqual(run_swift(self, source).strip(), 'PASS')
        # Every hidden name the classifier knows is a step the suite actually records.
        gate = GATE_TESTS.read_text()
        for call in ['step("HIDE1VIS " + event + " hidden", evidenceContract: "hidden-alive")', 'step("GATE2246 HIDE " + name + " failure", evidenceContract: immediate ? "visible" : "hidden-alive")',
                     'step("GATE2246 HIDE " + name + " dismiss Later", evidenceContract: name == "visible" ? "visible" : "hidden-alive")']:
            self.assertIn(call, gate)

    def test_composite_turns_transparency_black_and_keeps_window_positions(self):
        probe = r'''
let space = CGColorSpaceCreateDeviceRGB()
func image(_ w: Int, _ h: Int, _ fill: (CGContext) -> Void) -> CGImage {
    let c = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    fill(c); return c.makeImage()!
}
func pixel(_ img: CGImage, _ x: Int, _ y: Int) -> [UInt8] {   // top-left coordinates
    var px = [UInt8](repeating: 0, count: 4)
    let c = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: space,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    c.draw(img, in: CGRect(x: -x, y: y - img.height + 1, width: img.width, height: img.height))
    let (r, b) = (px[0], px[2])
    return r > 200 && b < 80 ? [255, 0, 0] : b > 200 && r < 80 ? [0, 0, 255] : max(px[0], px[1], px[2]) < 20 ? [0, 0, 0] : Array(px[0..<3])
}
// Pill window (2x): only its centre is opaque red; its outsets are fully transparent.
let pill = image(80, 40) { c in c.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1)); c.fill(CGRect(x: 20, y: 10, width: 40, height: 20)) }
let alert = image(40, 40) { c in c.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1)); c.fill(CGRect(x: 0, y: 0, width: 40, height: 40)) }
let out = compositeOnBlack([(pill, CGRect(x: 100, y: 10, width: 40, height: 20)), (alert, CGRect(x: 100, y: 60, width: 20, height: 20))])!
precondition(out.width == 80 && out.height == 140)
precondition(pixel(out, 0, 0) == [0, 0, 0], "transparent outset is black, never what was behind it")
precondition(pixel(out, 40, 20) == [255, 0, 0], "opaque QA pixels kept")
precondition(pixel(out, 10, 130) == [0, 0, 255], "second window at its own position")
precondition(pixel(out, 70, 80) == [0, 0, 0], "between windows is black")
precondition(compositeOnBlack([]) == nil, "no proven window: no image")
print("PASS")
'''
        self.assertEqual(run_swift(self, MODALS_PRELUDE + block(PERMISSIONS, 'FOREIGN MODALS') + probe).strip(), 'PASS')

    def test_runner_frame_receipt_is_proven_only_for_this_request(self):
        probe = r'''
let good: [String: Any] = ["count": 9, "kind": "still", "status": "clear",
                           "capture": ["status": "PROVEN", "path": "/x/still-9.png", "windows": [77], "qaPid": 42]]
precondition(uie2eStillReceipt(good, count: 9)["status"] as? String == "PROVEN")
precondition(uie2eStillReceipt(good, count: 10)["status"] as? String == "NOT_PROVEN", "stale answer")
precondition(uie2eStillReceipt(nil, count: 9)["reason"] as? String == "no-broker-answer")
var noWindow = good; noWindow["capture"] = ["status": "NOT_PROVEN", "reason": "no-proven-qa-window"]
precondition(uie2eStillReceipt(noWindow, count: 9)["reason"] as? String == "no-proven-qa-window")
var empty = good; empty["capture"] = ["status": "PROVEN", "path": "/x", "windows": [Int]()]
precondition(uie2eStillReceipt(empty, count: 9)["status"] as? String == "NOT_PROVEN", "PROVEN needs window IDs")
precondition(uie2eBoundaryClear(["count": 3, "kind": "command", "status": "clear"], count: 3, kind: "command"))
precondition(!uie2eBoundaryClear(["count": 3, "kind": "action", "status": "clear"], count: 3, kind: "command"))
precondition(!uie2eBoundaryClear(["count": 2, "kind": "command", "status": "clear"], count: 3, kind: "command"))
precondition(!uie2eBoundaryClear(["count": 3, "kind": "command", "status": "stop"], count: 3, kind: "command"))
precondition(!uie2eBoundaryClear(nil, count: 3, kind: "command"))
precondition(uie2eRedacted("BrainBar dialog").hasPrefix("<redacted len=15 sha256="))
// Lead ruling on NOT_PROVEN frames.
let proof: [String: Any] = ["cgInventory": "ok", "qaPid": 42, "qaBirth": [100, 20], "pidLifetime": "alive", "onScreenQAWindows": 0]
var absent = good; absent["capture"] = ["status": "NOT_PROVEN", "reason": "no-proven-qa-window", "absenceProof": proof]
let absentReceipt = uie2eStillReceipt(absent, count: 9)
precondition(uie2eFrameFailure(absentReceipt, contract: "hidden-alive") == nil, "hidden + proof passes")
precondition(uie2eFrameFailure(absentReceipt, contract: "visible") != nil, "visible expectation fails on NOT_PROVEN")
precondition(uie2eFrameFailure(uie2eStillReceipt(noWindow, count: 9), contract: "hidden-alive") != nil, "no proof fails")
var failedRead = good; failedRead["capture"] = ["status": "NOT_PROVEN", "reason": "cg-enumeration",
    "absenceProof": ["cgInventory": "failed", "qaPid": 42, "onScreenQAWindows": 0]]
precondition(uie2eStillReceipt(failedRead, count: 9)["absenceProof"] == nil, "a failed read is never a proof")
precondition(uie2eFrameFailure(uie2eStillReceipt(failedRead, count: 9), contract: "hidden-alive") != nil)
precondition(uie2eFrameFailure(uie2eStillReceipt(good, count: 9), contract: "hidden-alive") == nil, "PROVEN frames always pass")
print("PASS")
'''
        source = 'import Foundation\nimport CryptoKit\n' + block(FLOW_TESTS, 'UIE2E BOUNDARY') + probe
        self.assertEqual(run_swift(self, source).strip(), 'PASS')

    def test_exporter_accepts_only_window_id_frames_and_imageless_not_proven(self):
        results = results_module()
        proven = dict(source='qa-window-id', status='PROVEN', windows=[77])
        movie = dict(path='run.mov', valid=True, durationSeconds=1, bytes=5,
                     captureSource=dict(kind='application', bundle='com.voicelayer.voicebar.uie2e', fullDisplay=False,
                                        executable='/private/tmp/vl-ui-a/VoiceBarQA.app/Contents/MacOS/VoiceBar', observedPids=[42]))
        with tempfile.TemporaryDirectory() as tmp:
            directory = pathlib.Path(tmp)
            (directory / 'a.png').write_bytes(b'png')
            image = [dict(attachments=[dict(suggestedHumanReadableName='UIE2E-0001', exportedFileName='a.png',
                                            isAssociatedWithFailure=False)])]
            none = [dict(attachments=[])]
            step = dict(number=1, name='frame', attachment='UIE2E-0001', passed=True, evidenceContract='visible')
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertTrue(results.report(directory, [dict(step, capture=proven)], image, movie))
                unproven = dict(source='qa-window-id', status='NOT_PROVEN', reason='no-proven-qa-window')
                proof = dict(cgInventory='ok', qaPid=42, qaBirth=[100, 20], pidLifetime='alive', onScreenQAWindows=0)
                hidden = dict(step, evidenceContract='hidden-alive')
                # Lead ruling: hidden-state step + positive expected-absent proof is the ONLY passing NOT_PROVEN.
                self.assertTrue(results.report(directory, [dict(hidden, capture=dict(unproven, absenceProof=proof))], none, movie))
                self.assertFalse(results.report(directory, [dict(hidden, capture=dict(unproven, absenceProof=dict(
                    cgInventory='ok', qaProcess='none', onScreenQAWindows=0)))], none, movie), 'termination is not hidden proof')
                for case, frame in [('visible-expected', dict(step, capture=dict(unproven, absenceProof=proof))),
                                    ('hidden-no-proof', dict(hidden, capture=unproven)),
                                    ('failed-inventory', dict(hidden, capture=dict(unproven, absenceProof=dict(proof, cgInventory='failed')))),
                                    ('windows-present', dict(hidden, capture=dict(unproven, absenceProof=dict(proof, onScreenQAWindows=1)))),
                                    ('no-pid', dict(hidden, capture=dict(unproven, absenceProof=dict(cgInventory='ok', onScreenQAWindows=0))))]:
                    with self.subTest(case=case):
                        self.assertFalse(results.report(directory, [frame], none, movie))
                with self.assertRaisesRegex(ValueError, 'NOT_PROVEN frame carries an image'):
                    results.report(directory, [dict(step, capture=unproven)], image, movie)
                for capture in [None, dict(source='qa-windows', fullDisplayPersisted=False),
                                dict(source='qa-window-id', status='PROVEN', windows=[]), dict(source='display', status='PROVEN', windows=[1])]:
                    with self.subTest(capture=capture), self.assertRaisesRegex(ValueError, 'not the QA window'):
                        results.report(directory, [dict(step, capture=capture) if capture else step], image, movie)
                for change in [dict(observedPids=[]), dict(executable=None), dict(bundle='com.apple.finder'), dict(fullDisplay=True)]:
                    with self.subTest(change=change), self.assertRaisesRegex(ValueError, 'not the QA app'):
                        results.report(directory, [dict(step, capture=proven)], image,
                                       dict(movie, captureSource=dict(movie['captureSource'], **change)))


class ForeignModals(unittest.TestCase):
    def inventory(self, setup):
        probe = FAKE_SOURCE + '\nlet f = Fake()\n' + setup + '\nprint(summary(modalInventory(f, qaPids: [42])))\n'
        return run_swift(self, MODALS_PRELUDE + block(PERMISSIONS, 'FOREIGN MODALS') + probe).strip()

    def test_r2_any_visible_modal_on_any_display_regardless_of_overlap(self):
        out = self.inventory(r'''
f.rows = [row(1, 611, "com.apple.coreservices.uiagent", layer: 8, CGRect(x: 734, y: 236, width: 260, height: 274)),
          row(2, 42, qaBundle, layer: 8),                                              // QA's own product alert
          row(3, 70, "com.apple.Preview", CGRect(x: 0, y: 900, width: 500, height: 400)),  // far from QA
          row(4, 71, "com.apple.dt.Xcode", CGRect(x: 3000, y: 100, width: 800, height: 600)), // second display
          row(5, 72, "com.example.panel", layer: 8, CGRect(x: 3100, y: 50, width: 200, height: 100)),
          row(6, 73, "com.apple.TextEdit"),                                             // ordinary window
          row(7, 74, "com.apple.menuextra", layer: 25)]                                 // menu-bar only
f.windowsByPid = [70: .value(["Print"]), 71: .value(["Main"]), 73: .value(["vapi.env"]), 72: .value([])]
f.kids = ["Print": .value(["sheet"]), "Main": .value(["button"])]
f.roles = ["sheet": .value("AXSheet")]
f.modal = ["Main": .value(true)]
''')
        self.assertEqual(out, 'com.apple.coreservices.uiagent|system-owner,com.example.panel|modal-level,'
                              'com.apple.Preview|sheet,com.apple.dt.Xcode|modal')

    def test_r3_every_read_failure_is_not_proven_never_an_empty_inventory(self):
        cases = {
            'f.rows = nil': 'ERR cg-enumeration',
            'f.rows = [row(1, 70, "com.apple.Preview", nil)]': 'ERR cg-geometry',
            'f.rows = [row(1, 70, "com.apple.Preview")]; f.windowsByPid = [70: .failed("cannot-complete")]': 'ERR ax-windows',
            'f.rows = [row(1, 70, "com.apple.Preview")]; f.windowsByPid = [70: .value(["w"])]; f.modal = ["w": .failed("ax-error-25204")]': 'ERR ax-modal',
            'f.rows = [row(1, 70, "com.apple.Preview")]; f.windowsByPid = [70: .value(["w"])]; f.kids = ["w": .failed("cannot-complete")]': 'ERR ax-children',
            'f.rows = [row(1, 70, "com.apple.Preview")]; f.windowsByPid = [70: .value(["w"])]; f.kids = ["w": .value(["c"])]; f.roles = ["c": .failed("role-type")]': 'ERR ax-role',
        }
        for setup, expected in cases.items():
            with self.subTest(expected=expected):
                self.assertEqual(self.inventory(setup), expected)
        # Explicitly unsupported attributes are absence, not failure.
        self.assertEqual(self.inventory('f.rows = [row(1, 70, "com.apple.Preview")]; f.windowsByPid = [70: .absent]'), '')

    def test_r4_latch_never_recovers_and_broker_persists_only_redacted_entries(self):
        probe = FAKE_SOURCE + r'''
var latch = BoundaryLatch()
let clear = ModalInventory()
var modal = ModalInventory(); modal.modals = [["owner": "com.apple.coreservices.uiagent", "pid": 611, "title": "BrainBar is an app", "source": "system-owner"]]
var broken = ModalInventory(); broken.errors = [["kind": "ax-windows", "owner": "Etan private owner", "reason": "Etan private reason"]]
precondition(latch.decide(clear) == "clear")
precondition(latch.decide(modal) == "stop")
precondition(latch.decide(clear) == "stop", "a modal that disappears never un-latches STOP")
var second = BoundaryLatch()
precondition(second.decide(broken) == "not-proven" && second.decide(clear) == "stop")
let persisted = String(decoding: try! JSONSerialization.data(withJSONObject: redactedEntries(modal.modals + broken.errors)), as: UTF8.self)
precondition(!persisted.contains("BrainBar") && !persisted.contains("Etan private"), persisted)
precondition(persisted.contains("com.apple.coreservices.uiagent"))
print("PASS")
'''
        self.assertEqual(run_swift(self, MODALS_PRELUDE + block(PERMISSIONS, 'FOREIGN MODALS') + probe).strip(), 'PASS')

    def test_r4_every_command_action_and_still_waits_for_a_fresh_decision(self):
        flow = FLOW_TESTS.read_text()
        step = flow.split('    func step(', 1)[1].split('    @discardableResult', 1)[0]
        self.assertLess(step.index('boundaryClear("action")'), step.index('body()'), 'decision precedes the UI action')
        command = GATE_TESTS.read_text().split('    func fixtureCommand(', 1)[1].split('    func gateRead(', 1)[0]
        self.assertLess(command.index('boundaryClear("command")'), command.index('postNotificationName('))
        monitor = flow.split('addUIInterruptionMonitor(', 1)[1].split('step("launch isolated QA app"', 1)[0]
        self.assertNotIn('activate()', monitor, 'never recover focus and continue around a foreign window')
        self.assertIn('latchForeignStop(', monitor)
        self.assertIn('return true', monitor)
        self.assertEqual(re.findall(r'\\\(alert\.debugDescription\)', flow), [], 'foreign descriptions are never logged raw')
        latch = flow.split('    func boundaryClear(', 1)[1].split('    func waitUntil(', 1)[0]
        self.assertIn('guard foreignModalStop == nil else { return false }', latch)
        run = (ROOT / 'scripts/voicebar-ui-e2e-run.py').read_text().split('def run_suite', 1)[1]
        self.assertLess(run.index('modal_gate(output)'), run.index("visibility.call('hide')"), 'R2: refuse before Hide Others')
        self.assertLess(run.index("visibility.call('hide')"), run.index('boundary.start()'))
        self.assertLess(run.index('boundary.start()'), run.index('recording.start()'))

    def native(self, module, output, payload, code=0):
        (output / 'sandbox-path.txt').write_text(str(output / 'sandbox'))
        helper = output / 'voicebar-ui-e2e-permissions'
        helper.write_text('#!/bin/sh\nprintf %s ' + repr(payload if isinstance(payload, str) else json.dumps(payload))
                          + '\nexit ' + str(code) + '\n')
        helper.chmod(0o755)
        return module.NativeHost(output, 'gate2246')

    def test_gatekeeper_dialog_refuses_preflight_with_owner_and_redacted_title(self):
        module = supervisor()
        payload = dict(axTrusted=True, prompts=[], inventoryErrors=[],
                       modals=[dict(owner='com.apple.coreservices.uiagent', pid=611, title=GATEKEEPER_TITLE, source='system-owner')])
        with tempfile.TemporaryDirectory() as tmp:
            output = pathlib.Path(tmp)
            host = self.native(module, output, payload)
            with self.assertRaises(module.ForeignModal) as stop:
                host.prepare_resident()
            log = (output / 'supervisor-preflight.log').read_text()
            for text in [str(stop.exception), log]:
                self.assertIn('owner=com.apple.coreservices.uiagent', text)
                self.assertRegex(text, r'title=<redacted len=%d hmac-sha256=' % len(GATEKEEPER_TITLE))  # REDACT2 keyed digest
                self.assertNotIn('BrainBar', text)

    def test_r3_inventory_errors_missing_fields_and_unreadable_helper_are_not_proven(self):
        module = supervisor()
        cases = [dict(axTrusted=True, prompts=[], modals=[],
                      inventoryErrors=[dict(kind='ax-windows', owner='com.example.hung', pid=9, reason='cannot-complete')]),
                 dict(axTrusted=True, prompts=[], modals=[]), dict(axTrusted=True, prompts=[], inventoryErrors=[]), 'garbage']
        for payload in cases:
            with self.subTest(payload=payload), tempfile.TemporaryDirectory() as tmp:
                host = self.native(module, pathlib.Path(tmp), payload)
                with self.assertRaisesRegex(module.ForeignModal, 'NOT_PROVEN'):
                    host.prepare_resident()

    def test_r6_permission_prompt_that_is_a_foreign_modal_exits_2_with_foreign_modal(self):
        module = supervisor()
        payload = dict(axTrusted=True, prompts=[dict(owner='com.apple.SecurityAgent', labels=['Allow'])], inventoryErrors=[],
                       modals=[dict(owner='com.apple.SecurityAgent', pid=88, title='wants to make changes', source='system-owner')])
        for launched in [False, True]:
            with self.subTest(launched=launched), tempfile.TemporaryDirectory() as tmp:
                output = pathlib.Path(tmp)
                host = self.native(module, output, payload, code=2)
                host.refuse_hotkey_collisions = lambda: None
                host.host_settings = lambda: {}
                host.muted = lambda: True
                host.set_mute = lambda value: None
                host.guard_mute = lambda: None
                host.collect_owned = lambda: None
                host.stop = lambda: True
                host.restore_resident = lambda: None
                host.wait = lambda seconds: None
                if launched:
                    host.prepare_resident = lambda: None
                    host.start = lambda: setattr(host, 'child', SimpleNamespace(poll=lambda: None))
                with contextlib.redirect_stderr(io.StringIO()), contextlib.redirect_stdout(io.StringIO()):
                    self.assertEqual(module.supervise(host), 2)
                receipt = json.loads((output / 'operator-state.json').read_text())
                self.assertEqual(receipt['verdict'], 'FOREIGN_MODAL_STOP' if launched else 'PREFLIGHT_REFUSED')
                self.assertEqual(receipt['foreignModal'][0]['owner'], 'com.apple.SecurityAgent')
                self.assertNotIn('wants to make changes', (output / 'operator-state.json').read_text())

    def test_r4_broker_latch_stops_the_supervisor_and_maps_to_exit_2(self):
        module = supervisor()
        with tempfile.TemporaryDirectory() as tmp:
            output = pathlib.Path(tmp)
            host = self.native(module, output, dict(axTrusted=True, prompts=[], modals=[], inventoryErrors=[]))
            host.collect_owned = lambda: None
            host.muted = lambda: True
            host.check()  # clear
            (output / module.FOREIGN_MODAL_LATCH).write_text(json.dumps(dict(status='stop', modals=[dict(
                owner='com.apple.coreservices.uiagent', pid=611, source='system-owner', title='raw private title')])))
            with self.assertRaises(module.ForeignModal) as stop:
                host.check()
            self.assertNotIn('raw private title', str(stop.exception))
            # The runner may exit before the next poll: supervise still maps a latched STOP to exit 2.
            calls = []
            class Host:
                def foreign_modal_latch(self): return host.foreign_modal_latch()
                def muted(self): return True
                def set_mute(self, value): pass
                def guard_mute(self): pass
                def prepare_resident(self): pass
                def start(self): self.child = True
                def poll(self): return 1
                def check(self): pass
                def wait(self, seconds): pass
                def stop(self): return True
                def restore_resident(self): pass
                def export(self): return 1
                def save(self, receipt): calls.append(dict(receipt))
            with contextlib.redirect_stderr(io.StringIO()), contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(module.supervise(Host()), 2)
            self.assertEqual(calls[-1]['verdict'], 'FOREIGN_MODAL_STOP')
            self.assertNotIn('raw private title', json.dumps(calls[-1]))


if __name__ == '__main__':
    unittest.main()
