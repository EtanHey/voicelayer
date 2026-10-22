#!/usr/bin/env python3
"""F2 synthetic-only regressions. Leased M1 execution; never run on the MBP.

Compile extracted production AX adapter, still observation, broker and runner methods.
All CG/AX/identity reads are injected; no native app, inventory, capture or device API runs.
"""
import importlib.util
import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location('f2_gatecap', ROOT / 'scripts/test-voicebar-gatecap1.py')
G = importlib.util.module_from_spec(spec)
spec.loader.exec_module(G)

AX_HOST = r'''
// Synthetic platform types: even the default native adapter is a trap, never an AX call.
typealias AXUIElement = Int
enum AXError: Int32 { case success, noValue, attributeUnsupported, invalidUIElement, cannotComplete, apiDisabled }
func AXUIElementCopyAttributeValue(_ e: AXUIElement, _ k: CFString,
    _ value: UnsafeMutablePointer<CFTypeRef?>) -> AXError { fatalError("native AX forbidden") }
'''

BROKER_HOST = r'''
let exe = "/synthetic/QA"
let qa = QAIdentity(pid: 42, path: exe, birth: [100, 20])
var windowReads = 0, captures = 0, failSecond = true, ended = false
func windows() -> [CGRow]? {
    windowReads += 1
    return failSecond && windowReads == 2 ? nil : []
}
func identityRead(_ pid: Int32) -> QAIdentityRead { ended ? .gone : .live(qa) }
struct Source: ModalSource {
    func windows() -> [CGRow]? { nextWindows() }
    func axWindows(_ pid: Int32) -> AXRead<[Int]> { fatalError("no foreign rows") }
    func isModal(_ e: Int) -> AXRead<Bool> { fatalError("no foreign rows") }
    func children(_ e: Int) -> AXRead<[Int]> { fatalError("no foreign rows") }
    func role(_ e: Int) -> AXRead<String> { fatalError("no foreign rows") }
    func title(_ e: Int) -> String { fatalError("no foreign rows") }
}
func nextWindows() -> [CGRow]? { windows() }
func runInventory(output: URL?, executable: String?, binding: inout QARunBinding,
    requireQA: Bool = false) -> ModalInventory { modalInventory(Source(), qaPids: []) }
func captureStill(binding: inout QARunBinding, executable: String, to path: URL)
    -> (windows: [UInt32], reason: String?, proof: [String: Any]?) {
    captures += 1
    switch observeStill(binding: &binding, executable: executable, candidates: [42], windows: nextWindows,
        read: identityRead, birth: { _ in ended ? .absent : .live(qa.birth) }, readPath: { _ in exe }) {
    case .notProven(let reason, let proof): return ([], reason, proof)
    case .windows: fatalError("SCK forbidden in synthetic test")
    }
}
func json(_ object: Any) -> Data { try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) }
func readJSON(_ path: URL) -> [String: Any] {
    try! JSONSerialization.jsonObject(with: Data(contentsOf: path)) as! [String: Any]
}
'''

RUNNER_HOST = r'''
var diagnostics: [String] = []
func XCTFail(_ reason: String) { diagnostics.append(reason) }
final class Runner {
    var foreignModalStop: String?
    var requests: [String] = []
    var answer: (String, UIE2EStopCategory?) -> [String: Any] = { kind, _ in ["count": 1, "kind": kind, "status": "clear"] }
    func boundary(_ kind: String, stop: UIE2EStopCategory? = nil) -> (count: Int, ack: [String: Any]?) {
        requests.append(kind)
        let ack = answer(kind, stop)
        return (ack["count"] as! Int, ack)
    }
    // INSERT RUNNER METHODS
}
'''


class ObservationStop(unittest.TestCase):
    def probe(self, source):
        self.assertEqual(G.run_swift(self, source + '\nprint("PASS")\n').strip(), 'PASS')

    def runner(self):
        methods = ''.join(G.block(G.FLOW_TESTS, marker) for marker in (
            'UIE2E BOUNDARY CLEAR', 'UIE2E REQUIRED FRAME', 'UIE2E FOREIGN STOP'))
        return G.block(G.FLOW_TESTS, 'UIE2E BOUNDARY') + RUNNER_HOST.replace('// INSERT RUNNER METHODS', methods)

    def test_invalid_element_adapter_fails_at_each_inventory_depth(self):
        self.probe(G.MODALS_PRELUDE + G.block(G.PERMISSIONS, 'FOREIGN MODALS') + AX_HOST
                   + G.block(G.PERMISSIONS, 'AX READ ADAPTER') + r'''
final class AdapterSource: ModalSource {
    var invalid = "", calls: [String] = []
    func read<T>(_ key: String, value: T) -> AXRead<T> {
        // Only platform bytes are substituted; the real axRead maps the result.
        let result = axRead(7, key, copy: { element, attribute, output in
            precondition(element == 7 && attribute as String == key)
            self.calls.append(key)
            output.pointee = "synthetic" as CFString
            return key == self.invalid ? .invalidUIElement : .success
        })
        switch result {
        case .value: return .value(value)
        case .absent: return .absent
        case .failed(let reason): return .failed(reason)
        }
    }
    func windows() -> [CGRow]? { [CGRow(id: 1, pid: 70, owner: "com.example.fixture", layer: 0,
        bounds: CGRect(x: 0, y: 0, width: 200, height: 100), alpha: 1, title: "Synthetic")] }
    func axWindows(_ pid: Int32) -> AXRead<[Int]> { read("AXWindows", value: [1]) }
    func isModal(_ e: Int) -> AXRead<Bool> { read("AXModal", value: false) }
    func children(_ e: Int) -> AXRead<[Int]> { read("AXChildren", value: [2]) }
    func role(_ e: Int) -> AXRead<String> { read("AXRole", value: "AXButton") }
    func title(_ e: Int) -> String { "Synthetic" }
}
for (key, kind) in [("AXWindows", "ax-windows"), ("AXModal", "ax-modal"),
                    ("AXChildren", "ax-children"), ("AXRole", "ax-role")] {
    let source = AdapterSource(); source.invalid = key
    let inventory = modalInventory(source, qaPids: [])
    precondition(source.calls.contains(key))
    precondition(inventory.errors.count == 1 && inventory.errors[0]["kind"] as? String == kind)
    precondition(inventory.errors[0]["reason"] as? String == "invalid-ui-element")
    var latch = BoundaryLatch()
    precondition(latch.decide(inventory) == "not-proven")
    source.invalid = "" // Even a later successful inventory cannot undo this observation failure.
    let clear = modalInventory(source, qaPids: [])
    precondition(clear.errors.isEmpty && clear.modals.isEmpty && latch.decide(clear) == "stop")
}
for error in [AXError.noValue, .attributeUnsupported, .success] {
    let absent = axRead(7, "AXWindows", copy: { _, _, output in output.pointee = nil; return error })
    guard case .absent = absent else { preconditionFailure("explicit absence must remain valid") }
}
''')

    def broker(self):
        return (G.MODALS_PRELUDE + G.block(G.PERMISSIONS, 'FOREIGN MODALS')
                + G.block(G.PERMISSIONS, 'STILL OBSERVATION') + BROKER_HOST
                + G.block(G.PERMISSIONS, 'BOUNDARY BROKER'))

    def test_first_clear_second_cg_failure_persists_stop_and_withholds_later_work(self):
        self.probe(self.broker() + self.runner() + r'''
let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
try! FileManager.default.createDirectory(at: root.appendingPathComponent("boundary"), withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: root) } // Only this probe's synthetic files.
let latchPath = root.appendingPathComponent("foreign-modal-stop.json")
let broker = Broker(token: "synthetic", root: root, executable: exe, latchPath: latchPath)
broker.answer("still")
let ack = readJSON(root.appendingPathComponent("boundary/ack.json"))
precondition(windowReads == 2 && captures == 1, "first clear CG read, second required CG read fails")
precondition(ack["status"] as? String == "not-proven")
let capture = ack["capture"] as! [String: Any]
precondition(capture["reason"] as? String == "cg-enumeration" && capture["absenceProof"] == nil)
let persisted = try! Data(contentsOf: latchPath)
precondition(readJSON(latchPath)["status"] as? String == "not-proven")
precondition(json(ack["latch"]!) == persisted, "latch exists when the ack is published")
let runner = Runner()
runner.answer = { kind, stop in
    broker.answer(kind, payload: stop.map { ["category": $0.rawValue] })
    return readJSON(root.appendingPathComponent("boundary/ack.json"))
}
runner.requireFrame(uie2eStillReceipt(ack, count: 1), contract: "hidden-alive")
precondition(runner.foreignModalStop != nil && diagnostics.count == 1)
let requests = runner.requests.count
var actions = 0, commands = 0
if runner.boundaryClear("action") { actions += 1 }
if runner.boundaryClear("command") { commands += 1 }
precondition(actions == 0 && commands == 0 && runner.requests.count == requests)
// Independent clients also receive STOP after every later inventory is clear.
for kind in ["action", "command", "still"] {
    broker.answer(kind)
    precondition(readJSON(root.appendingPathComponent("boundary/ack.json"))["status"] as? String == "stop")
}
precondition(captures == 1 && windowReads > 2)
precondition(try! Data(contentsOf: latchPath) == persisted)
''')

    def test_positive_absence_and_termination_remain_distinct(self):
        self.probe(self.broker() + self.runner() + r'''
failSecond = false
for terminated in [false, true] {
    ended = false
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try! FileManager.default.createDirectory(at: root.appendingPathComponent("boundary"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let latchPath = root.appendingPathComponent("foreign-modal-stop.json")
    let broker = Broker(token: "synthetic", root: root, executable: exe, latchPath: latchPath)
    precondition(broker.binding.prove(executable: exe, candidates: [42], rows: [], read: identityRead) == qa)
    ended = terminated
    broker.answer("still")
    let receipt = uie2eStillReceipt(readJSON(root.appendingPathComponent("boundary/ack.json")), count: 1)
    let runner = Runner()
    runner.requireFrame(receipt, contract: terminated ? "terminated" : "hidden-alive")
    precondition(runner.foreignModalStop == nil && diagnostics.isEmpty)
    precondition(broker.latch.stopped == nil && !FileManager.default.fileExists(atPath: latchPath.path))
    precondition(runner.boundaryClear("command"))
    precondition(uie2eFrameFailure(receipt, contract: terminated ? "hidden-alive" : "terminated") != nil)
}
''')

    def test_required_frame_failure_stops_runner_even_when_later_broker_is_clear(self):
        self.probe('import Foundation\nimport CryptoKit\n' + self.runner() + r'''
for reason in ["cg-enumeration", "still-unreadable", "no-broker-answer"] {
    let runner = Runner()
    runner.requireFrame(["status": "NOT_PROVEN", "reason": reason], contract: "visible")
    precondition(runner.foreignModalStop != nil)
    let requests = runner.requests.count
    precondition(!runner.boundaryClear("action") && !runner.boundaryClear("command"))
    precondition(runner.requests.count == requests, "later clear broker cannot undo local STOP")
}
precondition(diagnostics.count == 3)
''')


if __name__ == '__main__':
    unittest.main()
