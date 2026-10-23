#!/usr/bin/env python3
"""Extracted production F3b regressions; offline leased-M1 packet only, never MBP.

Compile real mutation/STOP/body/gallery methods against synthetic XCUI adapters.
No live helper, app, AX, notification, clipboard, process or device calls.
"""
import importlib.util
import pathlib
import re
import unittest

ROOT = pathlib.Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location('f3b_f2', ROOT / 'scripts/test-voicebar-f2-observation-stop.py')
F2 = importlib.util.module_from_spec(spec)
spec.loader.exec_module(F2)
G = F2.G
GALLERY = G.FLOW_TESTS.with_name('Focused338GalleryTests.swift')
# Include every XCUI input family, clipboard writes and the fixture's effectful notification.
EFFECT = re.compile(r'\.(?:click|rightClick|doubleClick|tap|doubleTap|typeText|typeKey|activate|launch|terminate|hover|scroll|swipe\w*|press\w*|drag\w*|adjust|pinch|rotate|clearContents|setString|writeObjects|postNotificationName)\s*\(')

HOST = r'''
var effects: [String] = [], queries: [String] = []
var onEffect: (() -> Void)?, onQuery: (() -> Void)?
func record(_ name: String) { effects.append(name); onEffect?() }
final class XCUIElement {
    let id: String
    init(_ id: String) { self.id = id }
    var isHittable: Bool { true }; var isEnabled: Bool { true }
    var frame: CGRect { CGRect(x: 0, y: 0, width: 20, height: 20) }
    var firstMatch: XCUIElement { self }
    subscript(_ name: String) -> XCUIElement {
        queries.append(name); onQuery?(); return XCUIElement(name)
    }
    func activate() { record("activate") }
    func click() { record(id) }
    func waitForExistence(timeout: Double) -> Bool { true }
    func descendants(matching: Kind) -> XCUIElement { self }
    func matching(identifier: String) -> XCUIElement { XCUIElement(identifier) }
    enum Kind { case any }
    var windows: XCUIElement { self }
}
final class XCTNSPredicateExpectation {
    let predicate: NSPredicate
    init(predicate: NSPredicate, object: Any?) { self.predicate = predicate }
}
enum XCTWaiter {
    enum Result: Equatable { case completed }
    static func wait(for values: [XCTNSPredicateExpectation], timeout: Double) -> Result {
        precondition(values.allSatisfy { $0.predicate.evaluate(with: nil) }); return .completed
    }
}
func XCTAssertEqual<T: Equatable>(_ a: T, _ b: T, _ message: String) { precondition(a == b, message) }
'''


class MutationAuthorization(unittest.TestCase):
    def source(self):
        methods = ''.join(G.block(G.FLOW_TESTS, marker) for marker in (
            'UIE2E BOUNDARY CLEAR', 'UIE2E FOREIGN STOP', 'UIE2E MUTATION'))
        gallery = G.block(GALLERY, 'UIE2E GALLERY CLICK') + G.block(GALLERY, 'UIE2E GALLERY OBSERVE')
        host = F2.RUNNER_HOST.replace('// INSERT RUNNER METHODS', methods + gallery + r'''
    let app = XCUIElement("app")
    var generation = 0
    func gallerySnapshot() throws -> [String: Any] {
        generation += 1
        return ["observationGeneration": generation, "reason": "read-current"]
    }
''')
        return 'import Foundation\nimport CoreGraphics\nimport CryptoKit\n' + G.block(G.FLOW_TESTS, 'UIE2E BOUNDARY') + HOST + host

    def probe(self, body):
        self.assertEqual(G.run_swift(self, self.source() + body + '\nprint("PASS")\n').strip(), 'PASS')

    def test_clear_then_refuse_aborts_body_and_sticky_stop_withholds_later_clear(self):
        self.probe(r'''
let runner = Runner()
let first = XCUIElement("first"), second = XCUIElement("second"), third = XCUIElement("third")
var decisions = ["clear", "not-proven", "clear"], bodyFinished = false
runner.answer = { kind, _ in
    ["count": 1, "kind": kind, "status": kind == "stop" ? "not-proven" : decisions.removeFirst()]
}
runner.runStepBody {
    try runner.mutate { first.click() }
    try runner.mutate { second.click() }
    try runner.mutate { third.click() }
    bodyFinished = true
}
precondition(effects == ["first"] && !bodyFinished)
precondition(runner.requests == ["action", "action", "stop"] && diagnostics.count == 1)
let requests = runner.requests
runner.answer = { kind, _ in ["count": 1, "kind": kind, "status": "clear"] }
runner.runStepBody { try runner.mutate { record("later") } }
precondition(effects == ["first"] && runner.requests == requests && runner.foreignModalStop != nil)
''')

    def test_local_interruption_during_wait_or_effect_aborts_without_later_mutation(self):
        self.probe(r'''
for phase in ["wait", "effect", "query"] {
    effects = []; queries = []; diagnostics = []
    let runner = Runner()
    var finished = false
    runner.answer = { kind, _ in
        if kind == "action" && phase == "wait" { runner.latchForeignStop("synthetic wait") }
        return ["count": 1, "kind": kind, "status": "clear"]
    }
    onEffect = { if phase == "effect" { runner.latchForeignStop("synthetic effect") } }
    onQuery = { if phase == "query" { runner.latchForeignStop("synthetic query") } }
    runner.runStepBody {
        let target = runner.app.windows["target"] // Pure query, even when interruption arrives here.
        try runner.mutate { target.click() }
        try runner.mutate { record("second") }
        finished = true
    }
    precondition(!finished && effects == (phase == "effect" ? ["target"] : []))
    precondition(diagnostics.count == 1 && runner.foreignModalStop != nil)
    onEffect = nil; onQuery = nil
}
''')

    def test_actual_gallery_click_and_observe_check_each_activation_and_click(self):
        self.probe(r'''
for refused in 0..<4 {
    let runner = Runner(); effects = []; queries = []; diagnostics = []
    var reads = 0, finished = false
    runner.answer = { kind, _ in
        if kind == "stop" { return ["count": 1, "kind": kind, "status": "not-proven"] }
        defer { reads += 1 }
        return ["count": 1, "kind": kind, "status": reads == refused ? "not-proven" : "clear"]
    }
    runner.runStepBody {
        try runner.galleryClick("page")
        _ = try runner.galleryObserve()
        finished = true
    }
    let ordered = ["activate", "page", "activate", "qa-gallery-observe"]
    precondition(effects == Array(ordered.prefix(refused)) && !finished)
    precondition(reads == refused + 1 && diagnostics.count == 1)
    let requests = runner.requests
    runner.answer = { kind, _ in ["count": 1, "kind": kind, "status": "clear"] }
    runner.runStepBody { _ = try runner.galleryObserve() }
    precondition(runner.requests == requests && effects == Array(ordered.prefix(refused)))
}
let allowed = Runner(); effects = []; diagnostics = []
allowed.runStepBody { try allowed.galleryClick("page"); _ = try allowed.galleryObserve() }
precondition(effects == ["activate", "page", "activate", "qa-gallery-observe"])
precondition(allowed.requests == ["action", "action", "action", "action"] && diagnostics.isEmpty)
''')

    def test_inventory_guard_is_sensitive_at_every_effect_site(self):
        # Supplement the causal probes: strip comments/strings while retaining offsets, find each
        # real effect, and require exactly one effect inside its immediate throwing guard closure.
        def coverage(source):
            clean = re.sub(r'//[^\n]*|/\*.*?\*/|"(?:\\.|[^"\\])*"',
                           lambda m: ' ' * len(m[0]), source, flags=re.S)
            guards = []
            for match in re.finditer(r'try mutate(?:\([^)]*\))?\s*\{', clean):
                start = match.end(); end = start; depth = 1
                while depth and end < len(clean):
                    depth += (clean[end] == '{') - (clean[end] == '}'); end += 1
                guards.append((match.start(), end, len(EFFECT.findall(clean[start:end]))))
            effects = list(EFFECT.finditer(clean))
            return effects, [(m.start(), m.end()) for m in effects
                             if not any(a <= m.start() < b and count == 1 for a, b, count in guards)]
        total = 0
        for path in sorted(G.FLOW_TESTS.parent.glob('*.swift')):
            source = path.read_text()
            # Boundary requests (including explicit STOP) are control transport, not UI effects.
            if path == G.FLOW_TESTS:
                source = source.replace(G.block(path, 'UIE2E BOUNDARY TRANSPORT'), '')
            effects, uncovered = coverage(source)
            self.assertEqual(uncovered, [], path.name)
            total += len(effects)
            for match in effects:
                start = source.rfind('try mutate', 0, match.start())
                self.assertGreaterEqual(start, 0)
                changed = source[:start] + source[start:].replace('try mutate', 'unguarded', 1)
                self.assertTrue(coverage(changed)[1], (path.name, match.start()))
        self.assertEqual(total, 37, 'Review additions/removals against the real mutation inventory')


if __name__ == '__main__':
    unittest.main()
