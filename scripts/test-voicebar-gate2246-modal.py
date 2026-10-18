#!/usr/bin/env python3
"""Compile the real XCUI query helper against a fake run-02 AX tree; no native app."""
import pathlib
import re
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parent.parent
SOURCE = ROOT / 'flow-bar/UIE2E/VoiceBarUIE2ETests/Gate2245Tests.swift'

SHIM = r'''
import Foundation
enum XCUIElementType { case staticText }
final class XCUIElement {
    var identifier: String
    var exists: Bool
    var children: [XCUIElement]
    init(_ identifier: String, exists: Bool = true, children: [XCUIElement] = []) {
        self.identifier = identifier; self.exists = exists; self.children = children
    }
    var buttons: XCUIElementQuery { .init(children.filter { $0.identifier == "Later" }) }
    var staticTexts: XCUIElementQuery { .init(children.filter { $0.identifier != "Later" }) }
    var label: String { identifier }
}
struct XCUIElementQuery {
    var nodes: [XCUIElement]
    init(_ nodes: [XCUIElement]) { self.nodes = nodes.filter { $0.exists } }
    var firstMatch: XCUIElement { nodes.first ?? XCUIElement("missing", exists: false) }
    var count: Int { nodes.count }
    var allElementsBoundByIndex: [XCUIElement] { nodes }
    func containing(_ type: XCUIElementType, identifier: String) -> Self {
        .init(nodes.filter { $0.children.contains { $0.identifier == identifier } })
    }
    func matching(identifier: String) -> Self { .init(nodes.filter { $0.identifier == identifier }) }
    func matching(_ predicate: NSPredicate) -> Self {
        .init(nodes.filter { predicate.evaluate(with: ["label": $0.label]) })
    }
    subscript(_ id: String) -> XCUIElement { matching(identifier: id).firstMatch }
}
final class XCUIApplication {
    let alert = XCUIElement("alert", children: [XCUIElement("VoiceLayer microphone permission needs attention"), XCUIElement("Later")])
    let touchBar = XCUIElement("TouchBar", children: [XCUIElement("Later")])
    var dialogs: XCUIElementQuery { .init([alert]) }
    var buttons: XCUIElementQuery { .init(alert.children + touchBar.children).matching(identifier: "Later") }
}
'''

class ModalQueries(unittest.TestCase):
    def test_visual_menu_shortcuts_avoid_edit_commands_and_match_injection(self):
        menu = (ROOT / 'flow-bar/Sources/VoiceBar/UIE2EGate2245.swift').read_text()
        install = menu.split('func installHide1VisualMenu()', 1)[1].split('@objc func hide1VisualCommand', 1)[0]
        registered = re.search(r'keyEquivalentModifierMask\s*=\s*([^\n]+)', install)
        self.assertIsNotNone(registered, 'visual command modifiers must be explicit')
        # Edit's Command-A/C/V/X/Z remain reserved.
        mask = set(re.findall(r'\.(\w+)', registered[1]))
        keys = re.search(r'Array\("([0-9a-f]+)"\)', install)[1]
        self.assertFalse(mask == {'command'} and set(keys) & set('acvxz'),
                         'visual commands collide with standard Edit shortcuts')
        scenarios = SOURCE.read_text().split('extension VoiceBarFlowTests {', 1)[1]
        calls = re.findall(r'modifierFlags:\s*(\[[^\]]+\]|\.\w+)', scenarios)
        self.assertTrue(calls, 'visual scenario must send its shortcuts')
        for call in calls:
            self.assertEqual(set(re.findall(r'\.(\w+)', call)), mask,
                             'menu registration and scenario injection must agree')

    def test_unknown_scenario_lists_every_supported_choice_without_launch(self):
        with tempfile.TemporaryDirectory() as tmp:
            output = pathlib.Path(tmp) / 'never-created'
            result = subprocess.run(['bash', str(ROOT / 'scripts/voicebar-ui-e2e.sh'),
                '--output', str(output), '--scenario', 'unsupported'], capture_output=True, text=True)
            self.assertEqual(result.returncode, 2)
            for scenario in ['full', 'focused-338', 'hide1', 'gate2246']:
                self.assertIn(scenario, result.stderr)
            self.assertFalse(output.exists())

    def test_hidden_surface_check_ignores_resident_but_catches_qa_windows(self):
        source = SOURCE.read_text()
        if '// BEGIN GATE2245 WINDOW OWNERSHIP' in source:
            helper = source.split('// BEGIN GATE2245 WINDOW OWNERSHIP\n', 1)[1].split('// END GATE2245 WINDOW OWNERSHIP', 1)[0]
        else:
            # Execute the old assertion predicate to reproduce its cross-process failure.
            legacy = re.search(r'XCTAssertFalse\((screenWindows\.contains \{[^\n]+\}),', source)[1]
            helper = 'func gate2245HasOwnedScreenWindows(_ screenWindows: [[String: Any]], pid: Int) -> Bool { return ' + legacy + ' }\n'
        fixture = '''
let resident: [[String: Any]] = [["owner": "VoiceBar", "pid": 100]]
let qa = ["owner": "VoiceBarQA", "pid": 200] as [String: Any]
let unnamed = ["owner": "", "pid": 200] as [String: Any]
print(gate2245HasOwnedScreenWindows(resident, pid: 200))
print(gate2245HasOwnedScreenWindows(resident + [qa], pid: 200))
print(gate2245HasOwnedScreenWindows([unnamed], pid: 200))
'''
        with tempfile.TemporaryDirectory() as tmp:
            path = pathlib.Path(tmp)
            (path / 'main.swift').write_text('import Foundation\n' + helper + fixture)
            build = subprocess.run(['xcrun', 'swiftc', str(path / 'main.swift'), '-o', str(path / 'probe')], capture_output=True, text=True)
            self.assertEqual(build.returncode, 0, build.stderr)
            result = subprocess.run([str(path / 'probe')], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.splitlines(), ['false', 'true', 'true'])

    def test_real_queries_ignore_stale_receipt_and_touchbar_duplicate(self):
        source = SOURCE.read_text()
        self.assertIn('// BEGIN GATE2246 MODAL QUERIES', source,
                      'run-02 query/snapshot strategy still has no modal-safe XCUI seam')
        helper = source.split('// BEGIN GATE2246 MODAL QUERIES\n', 1)[1].split('// END GATE2246 MODAL QUERIES', 1)[0]
        fixture = r'''
let app = XCUIApplication()
let staleReceipt: [String: Any] = ["action": "start", "panelVisible": true, "hidden": false]
precondition(app.buttons.count == 2, "Fixture must reproduce run-02's TouchBar duplicate")
let observation = gate2246ModalObservation(app)
precondition(observation["alertVisible"] as? Bool == true)
precondition(observation["panelVisible"] as? Bool == false,
             "Live AX must win over stale panelVisible=true receipt")
precondition(gate2246LaterButtons(app).count == 1,
             "Later must select the alert's one button, not TouchBar")
precondition(gate2246LaterButtons(app).firstMatch.identifier == "Later")
app.alert.exists = false
precondition(gate2246ModalObservation(app)["alertVisible"] as? Bool == false,
             "Dismissed alert must not persist in the observation")
print("PASS stale snapshot and duplicate Later reproduced and avoided")
'''
        with tempfile.TemporaryDirectory() as tmp:
            path = pathlib.Path(tmp)
            (path / 'main.swift').write_text(SHIM + helper + fixture)
            build = subprocess.run(['xcrun', 'swiftc', str(path / 'main.swift'), '-o', str(path / 'probe')], capture_output=True, text=True)
            self.assertEqual(build.returncode, 0, build.stderr)
            result = subprocess.run([str(path / 'probe')], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_modal_steps_never_read_delayed_fixture_receipts(self):
        source = SOURCE.read_text().split('    func testHide1VisualFlow()', 1)[0]
        failure = source.split('step("GATE2246 HIDE " + name + " failure")', 1)[1].split('if immediate { step(', 1)[0]
        shown = source.split('step("GATE2246 HIDE " + name + " shown")', 1)[1].split('if name == "background"', 1)[0]
        for block in [failure, shown]:
            self.assertNotIn('gateRead(', block, 'Modal assertion reads stale run-02 fixture receipt')
            self.assertIn('gate2246ModalObservation(app)', block)
        self.assertNotIn('app.buttons["Later"]', source)
        self.assertIn('waitForExistence(timeout:', source)
        fixture = (ROOT / 'flow-bar/Sources/VoiceBar/UIE2EGate2245.swift').read_text()
        capture = fixture.split('    func captureFailure(', 1)[1].split('    func selectionCase(', 1)[0]
        self.assertNotIn('Task {', capture)
        self.assertNotIn('snapshot(', capture)

if __name__ == '__main__':
    unittest.main()
