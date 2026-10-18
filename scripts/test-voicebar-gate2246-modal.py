#!/usr/bin/env python3
"""Compile the real XCUI query helper against a retained run-03 NSAlert AX structure; no native app."""
import pathlib
import re
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parent.parent
SOURCE = ROOT / 'flow-bar/UIE2E/VoiceBarUIE2ETests/Gate2245Tests.swift'

SHIM = r'''
import Foundation
enum XCUIElementType { case staticText, button, dialog, touchBar }
final class XCUIElement {
    var identifier: String
    var label: String
    var title: String
    var value: String
    var elementType: XCUIElementType
    var exists: Bool
    var children: [XCUIElement]
    init(_ identifier: String, type: XCUIElementType = .dialog,
         label: String = "", title: String = "", value: String = "",
         exists: Bool = true, children: [XCUIElement] = []) {
        self.identifier = identifier; self.elementType = type
        self.label = label; self.title = title; self.value = value
        self.exists = exists; self.children = children
    }
    var buttons: XCUIElementQuery { .init(children.filter { $0.elementType == .button }) }
    var staticTexts: XCUIElementQuery { .init(children.filter { $0.elementType == .staticText }) }
}
struct XCUIElementQuery {
    var nodes: [XCUIElement]
    init(_ nodes: [XCUIElement]) { self.nodes = nodes.filter { $0.exists } }
    var firstMatch: XCUIElement { nodes.first ?? XCUIElement("missing", exists: false) }
    var count: Int { nodes.count }
    var allElementsBoundByIndex: [XCUIElement] { nodes }
    func containing(_ type: XCUIElementType, identifier: String) -> Self {
        .init(nodes.filter { $0.children.contains {
            $0.elementType == type && [$0.identifier, $0.label, $0.title, $0.value].contains(identifier)
        } })
    }
    func matching(identifier: String) -> Self { .init(nodes.filter { $0.identifier == identifier }) }
    func matching(_ predicate: NSPredicate) -> Self {
        .init(nodes.filter { predicate.evaluate(with:
            ["identifier": $0.identifier, "label": $0.label, "title": $0.title, "value": $0.value]) })
    }
    subscript(_ id: String) -> XCUIElement { matching(identifier: id).firstMatch }
}
final class XCUIApplication {
    // Sanitized fields from run-03's retained Dialog and TouchBar. AppKit supplies
    // AXTitle for NSButton and AXValue for NSTextField; neither has an AXLabel here.
    let alert = XCUIElement("_NS:87", label: "alert", children: [
        XCUIElement("_NS:74", type: .staticText, value: "VoiceLayer microphone permission needs attention"),
        XCUIElement("_NS:58", type: .staticText, value: "Synthetic capture failure"),
        XCUIElement("action-button-1", type: .button, title: "Open System Settings"),
        XCUIElement("action-button-2", type: .button, title: "Later")])
    let touchBar = XCUIElement("TouchBar", type: .touchBar, children: [
        XCUIElement("", type: .button, title: "Later")])
    let otherDialog = XCUIElement("other", children: [
        XCUIElement("other-heading", type: .staticText, value: "Unrelated dialog"),
        XCUIElement("action-button-2", type: .button, title: "Later")])
    var dialogs: XCUIElementQuery { .init([otherDialog, alert]) }
    var buttons: XCUIElementQuery {
        .init((alert.exists ? alert.children : []) + touchBar.children + otherDialog.children)
            .matching(NSPredicate(format: "title == %@", "Later"))
    }
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

    def test_pid_validation_compiles_in_real_nonthrowing_step_contract(self):
        source = SOURCE.read_text()
        contract = (ROOT / 'flow-bar/UIE2E/VoiceBarUIE2ETests/VoiceBarFlowTests.swift').read_text()
        signature = contract.split('    func step(', 1)[1].split('{', 1)[0]
        body_type = re.search(r'_ body: (\(\) (?:throws )?-> Void)', signature)[1]
        hidden = source.split('step("HIDE1VIS " + event + " hidden") {', 1)[1].split('attachJSON(', 1)[0]
        validation = hidden[hidden.index('                let screenWindows ='):]
        helper = source.split('// BEGIN GATE2245 WINDOW OWNERSHIP\n', 1)[1].split('// END GATE2245 WINDOW OWNERSHIP', 1)[0]
        fixture = r'''
var failures = 0
func XCTFail(_ message: String) { failures += 1 }
func XCTAssertFalse(_ value: Bool, _ message: String) { if value { failures += 1 } }
func XCTAssertGreaterThan(_ value: Int, _ minimum: Int) { if value <= minimum { failures += 1 } }
func XCTUnwrap<T>(_ value: T?, _ message: String) throws -> T {
    guard let value else { throw NSError(domain: "missing", code: 1) }; return value
}
func validate(_ receipt: [String: Any]) {
    step {
''' + validation + r'''
    }
}
let resident = [["owner": "VoiceBar", "pid": 100]] as [[String: Any]]
for pid: Any? in [nil, 0, -1, "200", 200] {
    failures = 0
    var receipt: [String: Any] = ["screenWindows": resident]
    if let pid { receipt["pid"] = pid }
    validate(receipt)
    precondition(failures == ((pid as? Int) == 200 ? 0 : 1), "PID must fail closed")
}
failures = 0
validate(["pid": 200, "screenWindows": [["pid": 200]]])
precondition(failures == 1, "QA-owned windows must still fail")
print("PASS nonthrowing step, invalid PID refusal, resident exclusion, QA surface failure")
'''
        with tempfile.TemporaryDirectory() as tmp:
            path = pathlib.Path(tmp)
            shim = 'import Foundation\n' + helper + 'func step(_ body: ' + body_type + ') { body() }\n'
            (path / 'main.swift').write_text(shim + fixture)
            build = subprocess.run(['xcrun', 'swiftc', str(path / 'main.swift'), '-o', str(path / 'probe')], capture_output=True, text=True)
            self.assertEqual(build.returncode, 0, build.stderr)
            result = subprocess.run([str(path / 'probe')], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_real_queries_ignore_stale_receipt_and_touchbar_duplicate(self):
        source = SOURCE.read_text()
        self.assertIn('// BEGIN GATE2246 MODAL QUERIES', source,
                      'run-02 query/snapshot strategy still has no modal-safe XCUI seam')
        helper = source.split('// BEGIN GATE2246 MODAL QUERIES\n', 1)[1].split('// END GATE2246 MODAL QUERIES', 1)[0]
        fixture = r'''
let app = XCUIApplication()
let staleReceipt: [String: Any] = ["action": "start", "panelVisible": true, "hidden": false]
precondition(app.buttons.count == 3, "Fixture includes TouchBar and unrelated-dialog duplicates")
precondition(app.alert.buttons.matching(NSPredicate(format: "label == %@", "Later")).count == 0,
             "Retained run-03 title-only button must reproduce the label miss")
let observation = gate2246ModalObservation(app)
precondition(observation["alertVisible"] as? Bool == true)
precondition(observation["panelVisible"] as? Bool == false,
             "Live AX must win over stale panelVisible=true receipt")
precondition(gate2246LaterButtons(app).count == 1,
             "Later must select the alert's one button, not TouchBar")
precondition(gate2246LaterButtons(app).firstMatch.identifier == "action-button-2")
let later = gate2246LaterButtons(app).firstMatch
precondition(later.title == "Later" && later.label.isEmpty)
later.title = "Later today"
precondition(gate2246LaterButtons(app).count == 0, "Title must match exactly")
later.title = "Later"
let duplicate = XCUIElement("duplicate", type: .button, title: "Later")
app.alert.children.append(duplicate)
precondition(gate2246LaterButtons(app).count == 2, "Ambiguity must reach the gate's count guard")
app.alert.children.removeLast()
app.alert.children.removeAll { $0.elementType == .button }
precondition(gate2246LaterButtons(app).count == 0, "Never fall back outside the product dialog")
app.alert.exists = false
precondition(gate2246ModalObservation(app)["alertVisible"] as? Bool == false,
             "Dismissed alert must not persist in the observation")
precondition(gate2246LaterButtons(app).count == 0, "Missing product dialog must not adopt other Later")
print("PASS retained title-only NSAlert, exact title, duplicates and missing-dialog refusal")
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
