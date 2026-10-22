#!/usr/bin/env python3
"""MODALOWN1 synthetic regressions. Never launches an app or reads live UI/settings."""
import contextlib
import io
import json
import pathlib
import tempfile
import unittest
from unittest.mock import patch

from importlib.util import spec_from_file_location, module_from_spec
ROOT = pathlib.Path(__file__).resolve().parent.parent

def load(name):
    spec = spec_from_file_location(name, ROOT / 'scripts' / (name + '.py'))
    module = module_from_spec(spec)
    spec.loader.exec_module(module)
    return module

G = load('test-voicebar-gatecap1')
# Exact RC57 receipt shape, including the duplicate CG/AX sightings and empty title.
RC57 = {"errors": [], "modals": [
    {"owner": "com.voicelayer.voicebar.uie2e", "pid": 63071, "source": "modal-level", "title": "<redacted len=0 sha256=e3b0c442>"},
    {"owner": "com.voicelayer.voicebar.uie2e", "pid": 63071, "source": "modal", "title": "<redacted len=0 sha256=e3b0c442>"}], "status": "stop"}

class OwnModal(unittest.TestCase):
    def test_lifetime_proof_rc57_launch_race_foreign_and_registered_owners(self):
        probe = G.FAKE_SOURCE + r'''
let executable = "/run/VoiceBarQA.app/Contents/MacOS/VoiceBar"
let qa = QAIdentity(pid: 63071, path: executable, birth: [100, 123456])
let runner = QAIdentity(pid: 60, path: "/usr/bin/python3", birth: [100, 4])
let xctest = QAIdentity(pid: 61, path: "/run/Tests-Runner", birth: [100, 5])
let f = Fake()
f.rows = [CGRow(id: 7, pid: qa.pid, owner: qaBundle, layer: 8,
    bounds: CGRect(x: 0, y: 0, width: 300, height: 200), alpha: 1, title: "")]
f.windowsByPid = [qa.pid: .value([""])]; f.modal = ["": .value(true)]
let receipt = try! JSONSerialization.jsonObject(with: Data(#"RC57_FIXTURE"#.utf8)) as! NSDictionary
let reproduced = ["status": "stop", "errors": [], "modals": redactedEntries(modalInventory(f, qaPids: []).modals)] as NSDictionary
precondition(receipt == reproduced, "must reproduce RC57 exactly before applying ownership proof")
var identities: [Int32: QAIdentityRead] = [qa.pid: .live(qa), 60: .live(runner), 61: .live(xctest)]
var binding = QARunBinding()
func inventory(_ required: Bool = false, registered: [QAIdentity] = []) -> ModalInventory {
    runModalInventory(f, binding: &binding, executable: executable, launchBirth: [100, 0],
        registered: registered, candidates: [], requireQA: required, read: { identities[$0] ?? .failed })
}
// NSWorkspace has not yet published QA. The on-screen CG PID proves it before the first command.
precondition(inventory(true).modals.isEmpty && binding.identity == qa, "RC57 own alert must clear")
precondition(inventory().errors.isEmpty)
f.windowsByPid[qa.pid] = .failed("cannot-complete")
precondition(inventory().errors.isEmpty, "proven own AX errors cannot become foreign-inventory errors")
f.windowsByPid[qa.pid] = .value([""])
// The same bundle ID/name at another path never grants ownership.
identities[qa.pid] = .live(QAIdentity(pid: qa.pid, path: "/other/VoiceBar", birth: [100, 123456]))
precondition(inventory().modals.count == 2, "bundle match alone is foreign")
// A reused PID at the same path cannot inherit the bound lifetime.
identities[qa.pid] = .live(QAIdentity(pid: qa.pid, path: executable, birth: [100, 123457]))
precondition(!inventory().errors.isEmpty, "reused own PID is NOT_PROVEN")
identities[qa.pid] = .failed
precondition(!inventory().errors.isEmpty, "unreadable identity is NOT_PROVEN")
identities[qa.pid] = .live(qa)
// Launch proof must not adopt an older exact-path app.
binding = QARunBinding()
identities[qa.pid] = .live(QAIdentity(pid: qa.pid, path: executable, birth: [99, 999999]))
precondition(!inventory().errors.isEmpty)
identities[qa.pid] = .live(qa); binding = QARunBinding()
// Runner/XCTest sheets are own only with registered PID plus matching microsecond birth.
f.rows = [row(1, 60, "runner", layer: 8), row(2, 61, "xctest")]
f.windowsByPid = [60: .value(["run"]), 61: .value(["test"])]
f.modal = [:]; f.kids = ["test": .value(["sheet"])]; f.roles = ["sheet": .value("AXSheet")]
precondition(inventory(registered: [runner, xctest]).modals.isEmpty)
precondition(inventory().modals.count == 2)
identities[60] = .live(QAIdentity(pid: 60, path: runner.path, birth: [100, 6]))
precondition(!inventory(registered: [runner, xctest]).errors.isEmpty)
// Foreign Gatekeeper stays STOP even beside a proven own alert.
f.rows = [row(9, 88, "com.apple.coreservices.uiagent", layer: 8)]
identities[88] = .live(QAIdentity(pid: 88, path: "/System/Gatekeeper", birth: [1, 0]))
var latch = BoundaryLatch()
precondition(latch.decide(inventory()) == "stop")
// No QA at the first fixture boundary is NOT_PROVEN, never clear.
f.rows = []; binding = QARunBinding()
precondition(!inventory(true).errors.isEmpty)
print("PASS")
'''.replace('RC57_FIXTURE', json.dumps(RC57))
        self.assertEqual(G.run_swift(self, G.MODALS_PRELUDE + G.block(G.PERMISSIONS, 'FOREIGN MODALS') + probe).strip(), 'PASS')

    def test_not_proven_retries_before_latching_with_a_hard_deadline(self):
        probe = r'''
var clock = 0.0, attempts = 0
func unresolved() -> ModalInventory {
    var inv = ModalInventory(); inv.errors = [["kind": "own-identity", "pid": 63071]]; return inv
}
let recovered = retryModalProof(seconds: 0.2, now: { clock }, pause: { clock += $0 }) {
    attempts += 1; return attempts < 3 ? unresolved() : ModalInventory()
}
precondition(attempts == 3 && recovered.errors.isEmpty)
attempts = 0; clock = 0
let failed = retryModalProof(seconds: 0.2, now: { clock }, pause: { clock += $0 }) {
    attempts += 1; return unresolved()
}
precondition(clock <= 0.2 && attempts > 1 && !failed.errors.isEmpty)
var latch = BoundaryLatch(); precondition(latch.decide(failed) == "not-proven")
var foreign = ModalInventory(); foreign.modals = [["source": "modal", "pid": 88]]
attempts = 0
_ = retryModalProof(seconds: 2, now: { clock }, pause: { clock += $0 }) { attempts += 1; return foreign }
precondition(attempts == 1, "foreign is immediate STOP")
print("PASS")
'''
        self.assertEqual(G.run_swift(self, G.MODALS_PRELUDE + G.block(G.PERMISSIONS, 'FOREIGN MODALS') + probe).strip(), 'PASS')

    def test_supervisor_supplies_lifetime_proofs_and_rc57_still_stops_without_them(self):
        m = G.supervisor()
        with tempfile.TemporaryDirectory() as tmp:
            host = G.ForeignModals().native(m, pathlib.Path(tmp), dict(
                axTrusted=True, prompts=[], inventoryErrors=[], modals=RC57['modals']))
            host.owned = {60: dict(kind='runner', started='100.000004', cmd='/python'),
                          61: dict(kind='xctest-runner', started='100.000005', cmd='/Tests-Runner')}
            host.permissions()
            proof = json.loads((pathlib.Path(tmp) / 'modal-run-proof.json').read_text())
            self.assertEqual(proof['owned'][0], dict(pid=60, birth=[100, 4], path='/python'))
            with self.assertRaises(m.ForeignModal):
                host.refuse_modals(m.permission_receipt(dict(axTrusted=True, prompts=[], inventoryErrors=[], modals=RC57['modals'])))

    def test_serialized_proof_is_consumed_by_live_helper_path_and_broker(self):
        probe = G.FAKE_SOURCE + r'''
let f = Fake()
let qa = QAIdentity(pid: 63071, path: "/run/QA", birth: [100, 123456])
f.rows = [row(1, qa.pid, qaBundle, layer: 8)]
func LiveModalSource() -> Fake { f }
func qaCandidatePids() -> [Int32] { [] }
func qaIdentityRead(_ pid: Int32) -> QAIdentityRead { .live(qa) }
let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: root) }
let proof: [String: Any] = ["executable": qa.path, "launchBirth": [100, 0], "owned": []]
try! JSONSerialization.data(withJSONObject: proof).write(to: root.appendingPathComponent("modal-run-proof.json"))
var binding = QARunBinding()
let result = runInventory(output: root, executable: qa.path, binding: &binding, requireQA: true)
precondition(result.modals.isEmpty && result.errors.isEmpty && binding.identity == qa)
// No run context never falls back to a bundle-ID exclusion.
precondition(runInventory(output: nil, executable: nil, binding: &binding).modals.count == 1)
try! Data("{}".utf8).write(to: root.appendingPathComponent("modal-run-proof.json"))
precondition(!runInventory(output: root, executable: qa.path, binding: &binding).errors.isEmpty)
print("PASS")
'''
        source = (G.MODALS_PRELUDE + G.block(G.PERMISSIONS, 'FOREIGN MODALS')
                  + G.block(G.PERMISSIONS, 'RUN MODAL PROOF') + probe)
        self.assertEqual(G.run_swift(self, source).strip(), 'PASS')
        swift = G.PERMISSIONS.read_text()
        broker = swift.split('    func answer(_ kind: String)', 1)[1]
        self.assertLess(broker.index('runInventory('), broker.index('latch.decide('))
        self.assertIn('requireQA: kind == "command"', broker)
        self.assertNotIn('excludedQAPids', swift)

    def test_input_source_drift_reports_without_failure_but_other_drift_still_fails(self):
        m = G.supervisor()
        for dock, expected in [('0', 0), ('1', 1)]:
            host, calls = G.HostSettings().fake(dock)
            original = host.host_settings
            def settings():
                result = original()
                result['com.apple.HIToolbox AppleSelectedInputSources'] = 'English' if host.reads == 1 else 'Hebrew'
                return result
            host.host_settings = settings
            with contextlib.redirect_stderr(io.StringIO()), contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(m.supervise(host), expected)
            receipt = calls[-1]
            self.assertIn('com.apple.HIToolbox AppleSelectedInputSources', receipt['hostSettingsChanged'])
            self.assertFalse(any('AppleSelectedInputSources' in e for e in receipt['cleanupErrors']))

if __name__ == '__main__':
    unittest.main()
