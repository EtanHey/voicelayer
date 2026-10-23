#!/usr/bin/env python3
"""GATECAP1.1: synthetic capture-policy and lifetime-proof regressions; no native UI."""
import importlib.util
import json
import pathlib
import plistlib
import tempfile
import unittest
import xml.etree.ElementTree as ET
from unittest.mock import patch

ROOT = pathlib.Path(__file__).resolve().parent.parent


def load(name):
    spec = importlib.util.spec_from_file_location(name, ROOT / 'scripts' / (name + '.py'))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class CapturePolicy(unittest.TestCase):
    def setUp(self):
        self.results = load('voicebar-ui-e2e-results')
        self.tmp = tempfile.TemporaryDirectory(suffix='.noindex')
        self.addCleanup(self.tmp.cleanup)
        self.root = pathlib.Path(self.tmp.name)

    def test_inherited_capture_is_disabled_in_both_run_formats(self):
        products = self.root / 'DerivedData/Build/Products'
        products.mkdir(parents=True)
        unsafe = dict(PreferredScreenCaptureFormat='screenRecording', SystemAttachmentLifetime='deleteOnSuccess',
                      UserAttachmentLifetime='keepNever')
        for modern in (False, True):
            with self.subTest(modern=modern):
                target = dict(unsafe)
                data = {'TestConfigurations': [dict(unsafe, TestTargets=[target])]} if modern else {'Tests': target}
                (products / 'test.xctestrun').write_bytes(plistlib.dumps(data))
                self.results.configure(self.root, self.root / 'QA.app', self.root / 'sandbox')
                configured = plistlib.loads((self.root / 'UIE2E.xctestrun').read_bytes())
                levels = [configured['TestConfigurations'][0], configured['TestConfigurations'][0]['TestTargets'][0]] if modern else [configured['Tests']]
                for level in levels:
                    self.assertEqual(level['SystemAttachmentLifetime'], 'keepNever')
                    self.assertEqual(level['PreferredScreenCaptureFormat'], 'screenshots')
                self.assertEqual(levels[-1]['UserAttachmentLifetime'], 'keepAlways', 'explicit window stills survive failure')

    def test_scheme_disables_system_capture_before_configuration(self):
        scheme = ROOT / 'flow-bar/UIE2E/VoiceBarUIE2E.xcodeproj/xcshareddata/xcschemes/VoiceBarUIE2E.xcscheme'
        action = ET.parse(scheme).getroot().find('TestAction')
        self.assertEqual(action.get('systemAttachmentLifetime'), 'keepNever')
        self.assertEqual(action.get('preferredScreenCaptureFormat'), 'screenshots')

    def test_unexpected_system_media_rejects_success_and_failed_runs_before_export(self):
        for failed in (False, True):
            for uti, name in [('public.mpeg-4', 'Screen Recording.mp4'), ('public.png', 'Screenshot.png')]:
                with self.subTest(failed=failed, name=name):
                    attachment = dict(_type={'_name': 'ActionTestAttachment'},
                                      uniformTypeIdentifier={'_value': uti}, name={'_value': name},
                                      filename={'_value': name}, lifetime={'_value': 'keepAlways'})
                    metadata = dict(actions={'_values': [dict(actionResult=dict(
                        status={'_value': 'failed' if failed else 'succeeded'},
                        testsRef=dict(id={'_value': 'tests'})))]})
                    objects = [metadata, dict(summaryRef=dict(id={'_value': 'summary'})),
                               dict(attachments={'_values': [attachment]})]
                    with patch.object(self.results.subprocess, 'check_output', side_effect=[json.dumps(v) for v in objects]), \
                            patch.object(self.results.subprocess, 'run') as export:
                        with self.assertRaisesRegex(ValueError, 'unexpected-system-capture'):
                            self.results.export(self.root, self.root / 'sandbox')
                        export.assert_not_called()
                    self.assertFalse((self.root / 'screenshots').exists())
                    qa = json.loads((self.root / 'qa-report.json').read_text())
                    self.assertEqual(qa['verdict'], 'FAIL')
                    self.assertFalse(qa['scenarioPassed'])
                    self.assertEqual(qa['resultBundle'], str((self.root / 'VoiceBar.xcresult').resolve()))

    def test_metadata_failure_never_falls_back_to_unfiltered_export(self):
        with patch.object(self.results.subprocess, 'check_output', return_value='not JSON'), \
                patch.object(self.results.subprocess, 'run') as export:
            with self.assertRaisesRegex(ValueError, 'attachment-inventory-not-proven'):
                self.results.export(self.root, self.root / 'sandbox')
            export.assert_not_called()

    def test_explicit_window_stills_and_separate_qa_movie_still_export(self):
        fixtures = load('test-voicebar-ui-e2e-results').ReportTests()
        fixtures.root = self.root
        fixtures.attachment_run()
        objects = [dict(testsRef=dict(id={'_value': 'tests'})), dict(attachments={'_values': [dict(
            _type={'_name': 'ActionTestAttachment'}, uniformTypeIdentifier={'_value': 'public.png'},
            name={'_value': 'UIE2E-0001'})]})]
        with patch.object(self.results.subprocess, 'check_output', side_effect=[json.dumps(v) for v in objects]), \
                patch.object(self.results.subprocess, 'run') as export:
            self.assertTrue(self.results.export(self.root, self.root / 'sandbox'))
            self.assertEqual(export.call_args.args[0][-2:], ['--filter', 'UIE2E-*'])
        self.assertTrue((self.root / 'screenshots/a.png').is_file())
        self.assertTrue((self.root / 'run.mov').is_file())

    def test_absence_consumers_reject_missing_lifetime_and_no_process(self):
        self.assertFalse(self.results.absence_proven(dict(cgInventory='ok', qaProcess='none', onScreenQAWindows=0)))
        self.assertFalse(self.results.absence_proven(dict(cgInventory='ok', qaPid=42, onScreenQAWindows=0)))
        proof = dict(cgInventory='ok', qaPid=42, qaBirth=[100, 20], pidLifetime='alive', onScreenQAWindows=0)
        self.assertTrue(self.results.absence_proven(proof))

    def test_termination_and_hidden_contracts_are_distinct_and_must_be_declared(self):
        proof = dict(cgInventory='ok', qaPid=42, qaBirth=[100, 20], onScreenQAWindows=0,
                     pidLifetime='ended', visibleOwnerPaths='non-qa')
        capture = dict(source='qa-window-id', status='NOT_PROVEN', terminationProof=proof)
        step = dict(number=1, name='after exit', attachment='UIE2E-0001', passed=True, capture=capture)
        manifest = [dict(attachments=[])]
        self.assertTrue(self.results.report(self.root, [dict(step, evidenceContract='terminated')], manifest))
        for declaration in (None, 'hidden-alive', 'visible', 'unknown'):
            with self.subTest(contract=declaration):
                self.assertFalse(self.results.report(self.root, [dict(step, evidenceContract=declaration)], manifest))
        for field in ('qaBirth', 'pidLifetime', 'visibleOwnerPaths'):
            broken = dict(proof); broken.pop(field)
            frame = dict(capture, terminationProof=broken)
            self.assertFalse(self.results.report(self.root, [dict(step, capture=frame, evidenceContract='terminated')], manifest))


class LifetimeProof(unittest.TestCase):
    def test_live_adapter_resolves_every_current_onscreen_owner_readonly(self):
        old = load('test-voicebar-gatecap1')
        probe = r'''
guard let rows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
    preconditionFailure("CG inventory unreadable")
}
var pids = Set<Int32>()
for row in rows {
    guard let pid = row[kCGWindowOwnerPID as String] as? Int32, pid > 0 else { preconditionFailure("CG owner missing") }
    pids.insert(pid)
}
precondition(!pids.isEmpty, "no current on-screen owners to verify")
var windowServer = false
for pid in pids {
    guard let identity = qaIdentity(pid) else { preconditionFailure("real identity read failed for on-screen owner PID \(pid)") }
    windowServer = windowServer || URL(fileURLWithPath: identity.path).lastPathComponent == "WindowServer"
}
precondition(windowServer, "cross-user Window Server row was not exercised")
print("PASS read-only live owners=\(pids.count); WindowServer resolved; no capture or UI action")
'''
        source = old.MODALS_PRELUDE + 'import Darwin\n' + old.block(old.PERMISSIONS, 'FOREIGN MODALS')
        source += old.block(old.PERMISSIONS, 'QA IDENTITY READ') + probe
        output = old.run_swift(self, source)
        self.assertIn('PASS read-only live owners=', output)
        print(output.strip())

    def test_dead_and_live_candidate_preserves_qa_modal_exclusion(self):
        old = load('test-voicebar-gatecap1')
        probe = old.FAKE_SOURCE + r'''
let exe = "/qa/VoiceBar"
let qa = QAIdentity(pid: 42, path: exe, birth: [100, 20])
// Kernel-proven gone is distinct from a failed read; only a stale candidate may be dropped.
let read: (Int32) -> QAIdentityRead = { $0 == 41 ? .gone : .live(qa) }
let pid = provenQAPid(executable: exe, candidates: [(42, read(42)), (41, read(41))])
precondition(pid == 42, "dead candidate erased live QA proof")
let source = Fake(); source.rows = [row(1, 42, qaBundle, layer: modalPanelLayer)]
source.windowsByPid[42] = .value(["own-alert"]); source.modal["own-alert"] = .value(true)
precondition(modalInventory(source, qaPids: pid.map { [$0] } ?? []).modals.isEmpty, "own alert counted as foreign")
var binding = QARunBinding()
precondition(binding.prove(executable: exe, candidates: [41, 42], rows: source.rows, read: read) == qa)
precondition(binding.prove(executable: exe, candidates: [41, 42], rows: [], read: read) == qa, "live-hidden proof survives gone candidate")
precondition(provenQAPid(executable: exe, candidates: [(42, .live(qa)), (41, .failed)]) == nil)
precondition(binding.prove(executable: exe, candidates: [41, 42], rows: [], read: { $0 == 41 ? .failed : .live(qa) }) == nil)
precondition(binding.prove(executable: exe, candidates: [41, 42], rows: [row(2, 41, "stale-owner")], read: read) == nil, "CG owner disappearance is unproven")
print("PASS")
'''
        self.assertEqual(old.run_swift(self, old.MODALS_PRELUDE + old.block(old.PERMISSIONS, 'FOREIGN MODALS') + probe).strip(), 'PASS')

    def test_runner_requires_declared_matching_contracts(self):
        old = load('test-voicebar-gatecap1')
        probe = r'''
let alive: [String: Any] = ["cgInventory": "ok", "qaPid": 42, "qaBirth": [100, 20], "onScreenQAWindows": 0, "pidLifetime": "alive"]
let ended = alive.merging(["pidLifetime": "ended", "visibleOwnerPaths": "non-qa"]) { _, new in new }
let hidden: [String: Any] = ["status": "NOT_PROVEN", "absenceProof": alive]
let terminated: [String: Any] = ["status": "NOT_PROVEN", "terminationProof": ended]
precondition(uie2eFrameFailure(hidden, contract: "hidden-alive") == nil)
precondition(uie2eFrameFailure(terminated, contract: "terminated") == nil)
precondition(uie2eFrameFailure(terminated, contract: "hidden-alive") != nil)
precondition(uie2eFrameFailure(hidden, contract: "terminated") != nil)
precondition(uie2eFrameFailure(hidden, contract: nil) != nil)
precondition(uie2eFrameFailure(["status": "PROVEN"], contract: nil) != nil)
precondition(uie2eFrameFailure(["status": "PROVEN", "terminationProof": ended], contract: "terminated") != nil)
print("PASS")
'''
        source = 'import Foundation\nimport CryptoKit\n' + old.block(old.FLOW_TESTS, 'UIE2E BOUNDARY') + probe
        self.assertEqual(old.run_swift(self, source).strip(), 'PASS')

    def test_termination_requires_ended_birth_and_complete_window_path_inventory(self):
        old = load('test-voicebar-gatecap1')
        probe = old.FAKE_SOURCE + r'''
let qa = QAIdentity(pid: 42, path: "/qa", birth: [100, 20])
func proof(_ rows: [CGRow]?, _ birth: BirthRead, _ path: String? = "/foreign") -> [String: Any]? {
    terminationProof(rows, identity: qa, birth: birth, readPath: { _ in path })
}
let foreign = [row(2, 7, "foreign")]
precondition(proof(foreign, .absent) != nil)
precondition(proof(foreign, .live([101, 20])) != nil, "different birth ends original lifetime")
precondition(proof(foreign, .live([100, 20])) == nil, "original lifetime is alive")
precondition(proof(foreign, .failed) == nil, "kernel read failure")
precondition(proof(nil, .absent) == nil, "CG read failure")
precondition(proof([row(2, 42, qaBundle)], .absent) == nil, "proven PID still has a window")
precondition(proof(foreign, .absent, "/qa") == nil, "QA executable still visible under another PID")
precondition(proof(foreign, .absent, nil) == nil, "owner path read failure")
precondition(proof([row(2, 7, "foreign", nil)], .absent) == nil, "visibility unreadable")
precondition(terminationProof([], identity: nil, birth: .absent, readPath: { _ in "/foreign" }) == nil)
print("PASS")
'''
        self.assertEqual(old.run_swift(self, old.MODALS_PRELUDE + old.block(old.PERMISSIONS, 'FOREIGN MODALS') + probe).strip(), 'PASS')

    def test_kernel_lifetime_brackets_the_actual_path_adapter(self):
        old = load('test-voicebar-gatecap1')
        fake = r'''
var births: [[UInt64]] = [], pathOK = true, failedErrno: Int32 = 0
var forcedSize: Int?
func fake_sysctl(_ mib: inout [Int32], _ count: UInt32, _ info: inout kinfo_proc, _ size: inout Int,
                 _ newValue: UnsafeMutableRawPointer?, _ newSize: Int) -> Int32 {
    precondition(mib == [CTL_KERN, KERN_PROC, KERN_PROC_PID, 42] && count == 4)
    let next = births.removeFirst()
    if next.isEmpty { size = 0; errno = failedErrno; return failedErrno == 0 ? 0 : -1 }
    info.kp_proc.p_un.__p_starttime.tv_sec = Int(next[0])
    info.kp_proc.p_un.__p_starttime.tv_usec = Int32(next[1]); size = forcedSize ?? size
    return 0
}
func fake_pidpath(_ pid: Int32, _ buffer: inout [CChar], _ size: UInt32) -> Int32 {
    if !pathOK { return 0 }
    for (i, b) in Array("/qa\0".utf8).enumerated() { buffer[i] = CChar(bitPattern: b) }; return 4
}
'''
        probe = r'''
births = [[100, 1], [100, 1]]; precondition(qaIdentity(42)?.birth == [100, 1])
births = [[100, 1], [100, 2]]; precondition(qaIdentity(42) == nil, "path read raced PID reuse")
births = [[]]; precondition(qaIdentity(42) == nil, "kernel identity read failed")
births = [[]]; failedErrno = ESRCH
if case .absent = qaBirth(42) {} else { preconditionFailure("ESRCH proves absence") }
births = [[]]; failedErrno = EACCES
if case .failed = qaBirth(42) {} else { preconditionFailure("permission error is NOT_PROVEN") }
births = [[]]; failedErrno = EPERM
if case .failed = qaBirth(42) {} else { preconditionFailure("EPERM is NOT_PROVEN even with zero output length") }
births = [[]]; failedErrno = 0
if case .gone = qaIdentityRead(42) {} else { preconditionFailure("successful zero-length result is gone") }
births = [[100, 1], []]
if case .gone = qaIdentityRead(42) {} else { preconditionFailure("gone during path bracket") }
births = [[100, 1]]; forcedSize = 1
if case .failed = qaBirth(42) {} else { preconditionFailure("short sysctl record is NOT_PROVEN") }
forcedSize = nil
births = [[100, 1], [100, 1]]; pathOK = false; precondition(qaIdentity(42) == nil, "proc_pidpath failed")
print("PASS")
'''
        source = old.MODALS_PRELUDE + old.block(old.PERMISSIONS, 'FOREIGN MODALS') + fake
        adapter = old.block(old.PERMISSIONS, 'QA IDENTITY READ')
        source += adapter.replace('sysctl(', 'fake_sysctl(').replace('proc_pidpath(', 'fake_pidpath(') + probe
        self.assertEqual(old.run_swift(self, source).strip(), 'PASS')

    def test_visible_pid_path_failure_cannot_disappear_from_candidates(self):
        old = load('test-voicebar-gatecap1')
        source = old.block(old.PERMISSIONS, 'FOREIGN MODALS')
        # Desired API keeps failed observations, binds once, and revalidates PID plus kernel birth.
        probe = old.FAKE_SOURCE + r'''
let exe = "/private/tmp/vl-ui-run/VoiceBarQA.app/Contents/MacOS/VoiceBar"
let qa = QAIdentity(pid: 42, path: exe, birth: [100, 20])
var binding = QARunBinding()
let visible = [row(1, 42, qaBundle)]
let read: (Int32) -> QAIdentityRead = { .live($0 == 42 ? qa : QAIdentity(pid: $0, path: "/foreign", birth: [90, 1])) }
precondition(binding.prove(executable: exe, candidates: [42], rows: visible, read: read) == qa)
precondition(binding.prove(executable: exe, candidates: [42], rows: visible, read: { _ in .failed }) == nil, "visible QA path read failed")
precondition(binding.prove(executable: exe, candidates: [42], rows: [], read: read) == qa, "live hidden process")
precondition(expectedAbsentProof([], identity: qa)?["qaPid"] as? Int == 42)
precondition(expectedAbsentProof(visible, identity: nil) == nil)
precondition(expectedAbsentProof([], identity: nil) == nil, "termination is not a hidden proof")
precondition(binding.prove(executable: exe, candidates: [42], rows: [row(2, 7, "foreign")], read: { $0 == 42 ? .live(qa) : .failed }) == nil, "ANY CG identity read failure")
precondition(binding.prove(executable: exe, candidates: [42, 43], rows: [], read: { .live(QAIdentity(pid: $0, path: exe, birth: [100, 20])) }) == nil, "ambiguity")
precondition(binding.prove(executable: exe, candidates: [42], rows: [], read: { .live(QAIdentity(pid: $0, path: exe, birth: [101, 20])) }) == nil, "PID reused")
precondition(binding.prove(executable: exe, candidates: [43], rows: [], read: { .live(QAIdentity(pid: $0, path: exe, birth: [102, 20])) }) == nil, "never rebind to another lifetime")
precondition(binding.proveTermination([], birth: .failed, readPath: { _ in nil }) == nil)
precondition(binding.proveTermination([], birth: .absent, readPath: { _ in nil }) != nil)
precondition(binding.prove(executable: exe, candidates: [43], rows: [], read: { .live(QAIdentity(pid: $0, path: exe, birth: [102, 20])) })?.pid == 43, "new launch only after positive termination proof")
print("PASS")
'''
        self.assertEqual(old.run_swift(self, old.MODALS_PRELUDE + source + probe).strip(), 'PASS')


if __name__ == '__main__':
    unittest.main()
