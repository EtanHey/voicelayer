#!/usr/bin/env python3
"""Execute the actual gate assertion on synthetic AX words; never launch an app."""
import pathlib
import re
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parent.parent
SOURCE = ROOT / 'flow-bar/UIE2E/VoiceBarUIE2ETests/Gate2245Tests.swift'
SHIM = r'''
import Foundation
final class XCUIElement {
    let label: String
    let value: Any?
    let exists: Bool
    let children: [XCUIElement]
    init(_ label: String = "", value: Any? = nil, exists: Bool = true,
         children: [XCUIElement] = []) {
        self.label = label; self.value = value; self.exists = exists; self.children = children
    }
    var staticTexts: XCUIElementQuery { .init(nodes: children.filter { $0.exists }) }
    func waitForExistence(timeout: TimeInterval) -> Bool { exists }
}
struct XCUIElementQuery {
    let nodes: [XCUIElement]
    var firstMatch: XCUIElement { nodes.first ?? XCUIElement(exists: false) }
    var allElementsBoundByIndex: [XCUIElement] { nodes }
    func containing(_ predicate: NSPredicate) -> Self {
        // XCUI containing selects parents with matching descendants, not matching leaves.
        .init(nodes: nodes.filter { node in
            node.children.contains { predicate.evaluate(with: ["label": $0.label]) }
        })
    }
}
'''
FIXTURE = r'''
let phrase = "Replacement selection B"
let cases: [(String, [XCUIElement], String, Bool)] = [
    ("split words", [.init("Replacement"), .init("selection"), .init("B")], phrase, true),
    ("pending selection", [.init("Own"), .init("selection"), .init("B")], "Own selection B", true),
    ("latest selection", [.init("Own"), .init("selection"), .init("C")], "Own selection C", true),
    ("stale selection", [.init("Own"), .init("selection"), .init("B")], "Own selection C", false),
    ("whole label", [.init(phrase)], phrase, true),
    ("absent", [], phrase, false),
    ("wrong text", [.init("Replacement"), .init("selection"), .init("C")], phrase, false),
    ("missing word", [.init("Replacement"), .init("B")], phrase, false),
    ("wrong order", [.init("B"), .init("selection"), .init("Replacement")], phrase, false),
    ("word prefix", [.init("Replacement"), .init("selection"), .init("Bogus")], phrase, false),
    ("AX value fallback", [.init(value: "Replacement"), .init("selection"), .init(value: "B")], phrase, true),
    ("whitespace label fallback", [.init(" \n", value: phrase)], phrase, true),
    ("label beats stale value", [.init("Wrong", value: phrase)], phrase, false),
    ("nontext value", [.init(value: 123)], phrase, false),
    ("surrounding UI", [.init("Agent"), .init("Replacement"), .init("selection"), .init("B"), .init("Stop")], phrase, true),
    ("blank expected", [.init(phrase)], " \n", false)
]
for (name, nodes, text, expected) in cases {
    let pill = XCUIElement(children: nodes)
    let actual = ASSERTION
    print("\(name):\(actual == expected ? "PASS" : "FAIL")")
}
'''


class RenderedWords(unittest.TestCase):
    def test_actual_selection_assertion_on_word_tree(self):
        source = SOURCE.read_text()
        block = source.split('if !text.isEmpty {', 1)[1].split('if name == "busy"', 1)[0]
        assertion = re.search(r'XCTAssertTrue\((.*?),\s*"Current teleprompter text missing:',
                              block, re.S)
        self.assertIsNotNone(assertion, 'Must exercise the gate\'s real rendered-text assertion')
        helper = ''
        if '// BEGIN GATE2246 RENDERED WORDS' in source:
            helper = source.split('// BEGIN GATE2246 RENDERED WORDS\n', 1)[1].split(
                '// END GATE2246 RENDERED WORDS', 1)[0]
        with tempfile.TemporaryDirectory() as tmp:
            path = pathlib.Path(tmp)
            (path / 'main.swift').write_text(SHIM + helper + FIXTURE.replace('ASSERTION', assertion[1]))
            build = subprocess.run(['xcrun', 'swiftc', str(path / 'main.swift'), '-o', str(path / 'probe')],
                                   capture_output=True, text=True, timeout=60)
            self.assertEqual(build.returncode, 0, build.stderr)
            result = subprocess.run([str(path / 'probe')], capture_output=True, text=True, timeout=5)
            self.assertEqual(result.returncode, 0, result.stderr)
            lines = result.stdout.splitlines()
            self.assertEqual(len(lines), 16, result.stdout)
            print(result.stdout, end="")
            for line in lines:
                with self.subTest(case=line.split(':')[0]):
                    self.assertTrue(line.endswith(':PASS'), line)


if __name__ == '__main__':
    unittest.main()
