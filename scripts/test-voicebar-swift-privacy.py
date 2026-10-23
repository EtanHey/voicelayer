#!/usr/bin/env python3
"""Offline Swift producer regression; run on the leased M1, never the busy MBP.

Compiles real broker persistence and runner diagnostic code with synthetic inventory/boundary
adapters. Uses real XCTest failure recording, without XCUI, AX, screen or app access.
Artifacts stay in a unique worktree-local .build.noindex/qa directory for lead inspection.
"""
import hashlib
import importlib.util
import json
import os
import pathlib
import re
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location('gatecap_privacy', ROOT / 'scripts/test-voicebar-gatecap1.py')
G = importlib.util.module_from_spec(spec)
spec.loader.exec_module(G)
TITLE, OWNER, REASON = 'Synthetic dialog Ω', 'Synthetic owner Ω', 'Synthetic reason Ω'
TOKEN = r'<redacted len=\d+ hmac-sha256=[0-9a-f]{32}>'

PROBE = r'''
let output = URL(fileURLWithPath: CommandLine.arguments[1])
let title = "Synthetic dialog Ω", owner = "Synthetic owner Ω", reason = "Synthetic reason Ω"
var supplied = ModalInventory()
func runInventory(output: URL?, executable: String?, binding: inout QARunBinding,
                  requireQA: Bool = false) -> ModalInventory { supplied }
func captureStill(binding: inout QARunBinding, executable: String, to path: URL)
    -> (windows: [UInt32], reason: String?, proof: [String: Any]?) {
    fatalError("privacy test must never capture")
}
func json(_ object: Any) -> Data {
    try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
}
for mode in ["modal", "errors", "empty"] {
    let root = output.appendingPathComponent(mode)
    try! FileManager.default.createDirectory(at: root.appendingPathComponent("boundary"), withIntermediateDirectories: true)
    supplied = ModalInventory()
    if mode == "errors" {
        supplied.errors = [["kind": "ax-windows", "owner": owner, "reason": reason]]
    } else {
        supplied.modals = [["owner": owner, "title": mode == "empty" ? "" : title, "pid": 42, "source": "modal"]]
    }
    let broker = Broker(token: "synthetic", root: root, executable: "/synthetic/QA",
                        latchPath: root.appendingPathComponent("foreign-modal-stop.json"))
    for kind in ["command", "action", "still"] {
        broker.answer(kind) // Actual file writes; never start the notification observer.
        let ack = try! Data(contentsOf: root.appendingPathComponent("boundary/ack.json"))
        try! ack.write(to: root.appendingPathComponent(kind + "-ack.json"))
        supplied = ModalInventory() // A disappearing modal must retain the same STOP/digests.
    }
}

final class FailureRecorder: NSObject, XCTestObservation {
    var diagnostics: [String] = []
    func testCase(_ testCase: XCTestCase, didFailWithDescription description: String,
                  inFile filePath: String?, atLine lineNumber: Int) {
        diagnostics.append(description)
    }
}
final class StopProbe: XCTestCase {
    var foreignModalStop: String?
    var calls = 0
    func boundary(_ kind: String, stop: UIE2EStopCategory? = nil) {
        precondition(kind == "stop" && stop == .runnerObserved)
        calls += 1
        let root = output.appendingPathComponent("runner-stop")
        try! FileManager.default.createDirectory(at: root.appendingPathComponent("boundary"), withIntermediateDirectories: true)
        supplied = ModalInventory() // Runner-only interruption; broker inventory is now clear.
        let broker = Broker(token: "synthetic", root: root, executable: "/synthetic/QA",
                            latchPath: root.appendingPathComponent("foreign-modal-stop.json"))
        broker.answer(kind, payload: stop.map { ["category": $0.rawValue] })
    }
    // INSERT ACTUAL FOREIGN STOP
    @objc func testPrivacy() {
        continueAfterFailure = true
        let first = uie2eRedacted(title)
        precondition(first == uie2eRedacted(title))
        precondition(uie2eRedacted("") == uie2eRedacted(""))
        let alert = SyntheticAlert(debugDescription: title), kind = "unknown"
        // INSERT ACTUAL INTERRUPTION STOP
        latchForeignStop("synthetic later reason")
        precondition(calls == 1 && foreignModalStop == "interruption unknown " + first)
    }
}
struct SyntheticAlert { let debugDescription: String }
let recorder = FailureRecorder()
XCTestObservationCenter.shared.addTestObserver(recorder)
let suite = StopProbe.defaultTestSuite
suite.run() // Deliberate failure: exercise real XCTFail and the observer's recorded diagnostic.
precondition(suite.testRun?.executionCount == 1 && suite.testRun?.failureCount == 1)
precondition(recorder.diagnostics.count == 1)
try! json(recorder.diagnostics).write(to: output.appendingPathComponent("xctest-diagnostics.json"))
'''


class SwiftPrivacy(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        artifacts = ROOT / '.build.noindex/qa'
        artifacts.mkdir(parents=True, exist_ok=True)
        cls.root = pathlib.Path(tempfile.mkdtemp(prefix='swift-privacy-', dir=artifacts))
        source = ('import Foundation\nimport CoreGraphics\nimport CryptoKit\nimport XCTest\n'
                  + G.block(G.PERMISSIONS, 'FOREIGN MODALS')
                  + G.block(G.PERMISSIONS, 'BOUNDARY BROKER')
                  + G.block(G.FLOW_TESTS, 'UIE2E BOUNDARY')
                  + PROBE.replace('// INSERT ACTUAL FOREIGN STOP', G.block(G.FLOW_TESTS, 'UIE2E FOREIGN STOP'))
                  .replace('// INSERT ACTUAL INTERRUPTION STOP', G.block(G.FLOW_TESTS, 'UIE2E INTERRUPTION STOP')))
        main = cls.root / 'main.swift'
        main.write_text(source)
        platform = subprocess.run(['xcrun', '--sdk', 'macosx', '--show-sdk-platform-path'],
                                  capture_output=True, text=True, timeout=30, check=True).stdout.strip()
        frameworks = str(pathlib.Path(platform) / 'Developer/Library/Frameworks')
        private_frameworks = str(pathlib.Path(platform) / 'Developer/Library/PrivateFrameworks')
        # XCTest's Swift overlay (including XCTFail) and its autolinked support library
        # live outside XCTest.framework in the selected platform's Developer/usr/lib.
        swift_libraries = str(pathlib.Path(platform) / 'Developer/usr/lib')
        build = subprocess.run(['xcrun', 'swiftc', str(main), '-F', frameworks, '-framework', 'XCTest',
                                '-I', swift_libraries, '-L', swift_libraries,
                                '-module-cache-path', str(cls.root / 'module-cache.noindex'),
                                '-Xlinker', '-rpath', '-Xlinker', swift_libraries,
                                '-Xlinker', '-rpath', '-Xlinker', frameworks,
                                '-Xlinker', '-rpath', '-Xlinker', private_frameworks, '-o', str(cls.root / 'probe')],
                               capture_output=True, text=True, timeout=120)
        (cls.root / 'compile.log').write_text(build.stdout + build.stderr)
        if build.returncode:
            raise AssertionError('Swift compile failed: ' + str(cls.root / 'compile.log'))
        cls.runs = []
        for index in range(2):
            run = cls.root / ('run-' + str(index))
            run.mkdir()
            result = subprocess.run([str(cls.root / 'probe'), str(run)], capture_output=True,
                                    text=True, timeout=30, env=os.environ.copy())
            (run / 'xctest.log').write_text(result.stdout + result.stderr)
            if result.returncode:
                raise AssertionError('Swift probe failed: ' + str(run / 'xctest.log'))
            cls.runs.append(run)
        print('Swift privacy artifacts: ' + str(cls.root), flush=True)

    def token(self, value, text):
        self.assertRegex(value, '^' + TOKEN + '$')
        self.assertTrue(value.startswith('<redacted len=' + str(len(text)) + ' '))
        return value

    def broker_tokens(self, run):
        tokens = []
        for mode in ('modal', 'errors', 'empty'):
            root = run / mode
            record = json.loads((root / 'foreign-modal-stop.json').read_text())
            field = 'errors' if mode == 'errors' else 'modals'
            self.assertEqual(set(record), {'status', 'modals', 'errors'})
            inactive_field = 'modals' if field == 'errors' else 'errors'
            self.assertEqual(record[inactive_field], [])
            self.assertEqual(record['status'], 'not-proven' if mode == 'errors' else 'stop')
            self.assertEqual(len(record[field]), 1)
            entry = record[field][0]
            self.assertEqual(set(entry), {'kind', 'owner', 'reason'} if mode == 'errors'
                             else {'owner', 'title', 'pid', 'source'})
            tokens.append(self.token(entry['owner'], OWNER))
            if mode == 'errors':
                self.assertEqual(entry['kind'], 'ax-windows')
                tokens.append(self.token(entry['reason'], REASON))
            else:
                self.assertEqual((entry['pid'], entry['source']), (42, 'modal'))
                tokens.append(self.token(entry['title'], '' if mode == 'empty' else TITLE))
            for count, kind in enumerate(('command', 'action', 'still'), 1):
                ack = json.loads((root / (kind + '-ack.json')).read_text())
                self.assertEqual(set(ack), {'count', 'kind', 'status', 'latch', 'capture'} if kind == 'still'
                                 else {'count', 'kind', 'status', 'latch'})
                self.assertEqual((ack['count'], ack['kind']), (count, kind))
                self.assertEqual(ack['status'], record['status'] if count == 1 else 'stop')
                self.assertEqual(ack['latch'], record)
                if kind == 'still':
                    self.assertEqual(ack['capture'], {'status': 'NOT_PROVEN', 'reason': 'foreign-modal-stop'})
            self.assertEqual(json.loads((root / 'boundary/ack.json').read_text()), ack)
        self.assertEqual(tokens[0], tokens[2])
        self.assertEqual(tokens[0], tokens[4])
        return tokens

    def diagnostic_token(self, run):
        diagnostics = json.loads((run / 'xctest-diagnostics.json').read_text())
        self.assertEqual(len(diagnostics), 1)
        prefix = 'Foreign modal STOP latched (interruption unknown '
        suffix = '); no further action, command or capture'
        match = re.fullmatch(r'(?:failed - )?' + re.escape(prefix) + '(' + TOKEN + ')'
                             + re.escape(suffix), diagnostics[0])
        self.assertIsNotNone(match)
        self.assertIn(diagnostics[0], (run / 'xctest.log').read_text())
        return self.token(match.group(1), TITLE)

    def test_actual_broker_and_xctest_persistence_key_lifetimes(self):
        for run in self.runs:
            record = json.loads((run / 'runner-stop/foreign-modal-stop.json').read_text())
            self.assertEqual(record, dict(status='not-proven', modals=[], errors=[
                dict(kind='runner-stop', owner='unknown', reason='runner-observed')]))
            ack = json.loads((run / 'runner-stop/boundary/ack.json').read_text())
            self.assertEqual(ack, dict(count=1, kind='stop', status='not-proven', latch=record))
        broker = [self.broker_tokens(run) for run in self.runs]
        runner = [self.diagnostic_token(run) for run in self.runs]
        for left, right in zip(*broker):
            self.assertNotEqual(left, right, 'broker must rekey in each independent process')
        self.assertNotEqual(runner[0], runner[1], 'runner must rekey in each independent process')
        for tokens, diagnostic in zip(broker, runner):
            self.assertNotEqual(tokens[1], diagnostic, 'independent producers must not share a key')
        for run in self.runs:
            for path in run.rglob('*'):
                if not path.is_file():
                    continue
                text = path.read_text()
                for raw in (TITLE, OWNER, REASON):
                    self.assertNotIn(raw, text)
                for candidate in (TITLE, OWNER, REASON, ''):
                    self.assertNotIn(hashlib.sha256(candidate.encode()).hexdigest()[:8], text)
                self.assertNotRegex(text, r'(?<!hmac-)sha256=|[0-9a-f]{64}|(?i:key)["\s:=]')


if __name__ == '__main__':
    unittest.main()
