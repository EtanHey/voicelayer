#!/usr/bin/env python3
"""F3a extracted-production offline regressions; leased M1 only, never MBP.

Only notification delivery and native inventory/capture are synthetic. Execute the real
runner transport, broker observer/answer/persistence and supervisor ingestion/refusal.
"""
import contextlib
import importlib.util
import io
import json
import pathlib
import tempfile
import unittest
from types import SimpleNamespace

ROOT = pathlib.Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location('f3a_f2', ROOT / 'scripts/test-voicebar-f2-observation-stop.py')
F2 = importlib.util.module_from_spec(spec)
spec.loader.exec_module(F2)
G = F2.G

NOTIFICATIONS = r'''
// Substitute only the external notification delivery; production constructs/decodes the payload.
final class SyntheticNotifications {
    static let shared = SyntheticNotifications()
    static func `default`() -> SyntheticNotifications { shared }
    var handlers: [Notification.Name: (Notification) -> Void] = [:]
    var posts: [Notification] = []
    func addObserver(forName name: Notification.Name, object: String?, queue: OperationQueue?,
                     using handler: @escaping (Notification) -> Void) { handlers[name] = handler }
    func postNotificationName(_ name: Notification.Name, object: String?,
                              userInfo: [AnyHashable: Any]?, deliverImmediately: Bool) {
        precondition(object == nil && deliverImmediately)
        let note = Notification(name: name, object: object, userInfo: userInfo)
        posts.append(note)
        guard let handler = handlers[name] else { preconditionFailure("missing broker subscription") }
        handler(note)
    }
}
var diagnostics: [String] = []
func XCTFail(_ reason: String) { diagnostics.append(reason) }
final class Runner {
    var root: URL
    var foreignModalStop: String?
    init(_ root: URL) { self.root = root }
    // INSERT RUNNER METHODS
}
'''

SETUP = r'''
failSecond = false
let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
try! FileManager.default.createDirectory(at: root.appendingPathComponent("boundary"), withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: root) } // Probe-owned synthetic files only.
let latchPath = root.appendingPathComponent("foreign-modal-stop.json")
let broker = Broker(token: root.lastPathComponent, root: root, executable: exe, latchPath: latchPath)
broker.start() // Registers only with SyntheticNotifications; no native observer starts.
let runner = Runner(root)
'''


class RunnerStopTransport(unittest.TestCase):
    def source(self):
        methods = ''.join(G.block(G.FLOW_TESTS, marker) for marker in (
            'UIE2E BOUNDARY TRANSPORT', 'UIE2E BOUNDARY CLEAR', 'UIE2E FOREIGN STOP'))
        source = (G.MODALS_PRELUDE + G.block(G.PERMISSIONS, 'FOREIGN MODALS')
                  + G.block(G.PERMISSIONS, 'STILL OBSERVATION') + F2.BROKER_HOST
                  + G.block(G.PERMISSIONS, 'BOUNDARY BROKER')
                  + G.block(G.FLOW_TESTS, 'UIE2E BOUNDARY')
                  + NOTIFICATIONS.replace('// INSERT RUNNER METHODS', methods))
        return source.replace('DistributedNotificationCenter', 'SyntheticNotifications')

    def probe(self, body):
        return G.run_swift(self, self.source() + SETUP + body).strip()

    def test_transient_runner_stop_persists_and_supervisor_observes_after_suite_exit(self):
        record = json.loads(self.probe(r'''
let initial = runner.boundary("action")
precondition(uie2eBoundaryClear(initial.ack, count: initial.count, kind: "action"))
let reads = windowReads
runner.latchForeignStop("interruption unknown " + uie2eRedacted("Synthetic private title Ω"))
precondition(windowReads == reads, "STOP must not depend on a second inventory")
precondition(diagnostics.count == 1 && runner.foreignModalStop != nil)
let note = SyntheticNotifications.shared.posts.last!
precondition(note.name.rawValue == uie2eBoundaryName(token: root.lastPathComponent, kind: "stop"))
precondition(note.userInfo?.count == 1 && note.userInfo?["category"] as? String == "runner-observed")
let persisted = try! Data(contentsOf: latchPath)
let ack = readJSON(root.appendingPathComponent("boundary/ack.json"))
precondition(ack["count"] as? Int == 2 && ack["kind"] as? String == "stop")
precondition(ack["status"] as? String == "not-proven" && json(ack["latch"]!) == persisted)
let posts = SyntheticNotifications.shared.posts.count
runner.latchForeignStop("Synthetic later reason")
for kind in ["action", "command", "still"] {
    precondition(!runner.boundaryClear(kind), "no later guarded work or requests")
    broker.answer(kind) // Independent client; every supplied inventory is clear.
    precondition(readJSON(root.appendingPathComponent("boundary/ack.json"))["status"] as? String == "stop")
}
precondition(SyntheticNotifications.shared.posts.count == posts && diagnostics.count == 1)
precondition(captures == 0 && windowReads > reads)
precondition(try! Data(contentsOf: latchPath) == persisted)
print(String(decoding: persisted, as: UTF8.self))
'''))
        self.assertEqual(record, dict(status='not-proven', modals=[], errors=[
            dict(kind='runner-stop', owner='unknown', reason='runner-observed')]))
        module = G.supervisor()
        with tempfile.TemporaryDirectory() as tmp:
            output = pathlib.Path(tmp)
            (output / module.FOREIGN_MODAL_LATCH).write_text(json.dumps(record))
            # Bind only these production readers to an inert host. Inheriting NativeHost would
            # expose its optional native hotkey/settings hooks to supervise().
            host = SimpleNamespace(output=output, note=lambda message: None)
            host.foreign_modal_latch = lambda: module.NativeHost.foreign_modal_latch(host)
            host.refuse_modals = lambda permissions: module.NativeHost.refuse_modals(host, permissions)
            host.refuse_latched_modal = lambda: module.NativeHost.refuse_latched_modal(host)
            entries = host.foreign_modal_latch()
            self.assertEqual(len(entries), 1)
            self.assertEqual(entries[0]['source'], 'not-proven')
            with self.assertRaises(module.ForeignModal):
                host.refuse_latched_modal()
            # Let an ordinary failed suite exit before the last latch check. The actual final
            # supervisor verdict must still be FOREIGN_MODAL_STOP, using its existing reader.
            host.muted = lambda: True
            host.set_mute = lambda value: None
            host.prepare_resident = host.start = host.check = host.guard_mute = lambda: None
            host.poll = lambda: 1
            host.stop = lambda: True
            host.restore_resident = lambda: None
            host.export = lambda: 0
            saved = []
            host.save = lambda receipt: saved.append(dict(receipt))
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(module.supervise(host), 2)
            self.assertEqual(saved[-1]['verdict'], 'FOREIGN_MODAL_STOP')
            self.assertTrue(saved[-1]['foreignModal'])

    def test_malformed_and_unknown_stop_payloads_refuse_without_persisting_raw_text(self):
        self.assertEqual(self.probe(r'''
let raw = "Synthetic private title and reason Ω"
let payloads: [[AnyHashable: Any]?] = [nil, [:], ["category": raw], ["category": 1],
    ["category": NSNull()], ["category": ["runner-observed"]], [1: "runner-observed"],
    ["category": "runner-observed", "reason": raw]]
for (index, payload) in payloads.enumerated() {
    let directory = root.appendingPathComponent(String(index))
    try! FileManager.default.createDirectory(at: directory.appendingPathComponent("boundary"), withIntermediateDirectories: true)
    let path = directory.appendingPathComponent("foreign-modal-stop.json")
    let other = Broker(token: "synthetic", root: directory, executable: exe, latchPath: path)
    other.answer("stop", payload: payload)
    let ack = readJSON(directory.appendingPathComponent("boundary/ack.json"))
    let record = readJSON(path)
    precondition(ack["status"] as? String == "not-proven")
    precondition(json(record) == json(["status": "not-proven", "modals": [], "errors": [
        ["kind": "runner-stop", "owner": "unknown", "reason": "invalid-stop-payload"]]]))
    precondition(json(ack["latch"]!) == json(record))
    for kind in ["action", "command", "still"] {
        other.answer(kind)
        precondition(readJSON(directory.appendingPathComponent("boundary/ack.json"))["status"] as? String == "stop")
    }
    for file in [path, directory.appendingPathComponent("boundary/ack.json")] {
        precondition(!String(decoding: try! Data(contentsOf: file), as: UTF8.self).contains(raw))
    }
}
precondition(captures == 0)
print("PASS")
'''), 'PASS')

    def test_stop_persistence_failure_withholds_ack_and_cannot_clear_memory_latch(self):
        self.assertEqual(self.probe(r'''
let unavailable = root.appendingPathComponent("missing-parent/foreign-modal-stop.json")
let other = Broker(token: "synthetic", root: root, executable: exe, latchPath: unavailable)
other.answer("stop", payload: ["category": "runner-observed"])
precondition(other.latch.stopped != nil)
let ack = root.appendingPathComponent("boundary/ack.json")
precondition(!FileManager.default.fileExists(atPath: ack.path), "no ack without durable STOP")
for kind in ["action", "command", "still"] {
    other.answer(kind)
    precondition(!FileManager.default.fileExists(atPath: ack.path))
}
precondition(captures == 0)
print("PASS")
'''), 'PASS')


if __name__ == '__main__':
    unittest.main()
