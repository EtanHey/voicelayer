#!/usr/bin/env python3
"""MODALOWN2: run-04's qa-binding STOP and 0-byte movie were one path bug, not a launch race.

Foundation's resolvingSymlinksInPath strips a leading /private, so a QA app under /private/tmp
read back as /tmp/... and never equalled the supervisor's realpath'd executable. Synthetic only:
kernel reads are faked, no app is launched and nothing is captured.
"""
import importlib.util
import json
import pathlib
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parent.parent


def load(name):
    spec = importlib.util.spec_from_file_location(name, ROOT / 'scripts' / (name + '.py'))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


G = load('test-voicebar-gatecap1')
FAKE_KERNEL = r'''
var kernelPath = "/private/tmp"
func fake_sysctl(_ mib: inout [Int32], _ count: UInt32, _ info: inout kinfo_proc, _ size: inout Int,
                 _ newValue: UnsafeMutableRawPointer?, _ newSize: Int) -> Int32 {
    info.kp_proc.p_un.__p_starttime.tv_sec = 100
    info.kp_proc.p_un.__p_starttime.tv_usec = 1
    return 0
}
func fake_pidpath(_ pid: Int32, _ buffer: inout [CChar], _ size: UInt32) -> Int32 {
    let bytes = Array(kernelPath.utf8) + [0]
    for (i, b) in bytes.enumerated() { buffer[i] = CChar(bitPattern: b) }
    return Int32(bytes.count)
}
'''


class PrivatePrefix(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        # The supervisor's own derivation: pathlib resolve() == realpath(3), which keeps /private.
        self.apps = []
        for name in ('run', 'other'):
            exe = pathlib.Path(tmp.name) / name / 'VoiceBarQA.app/Contents/MacOS/VoiceBar'
            exe.parent.mkdir(parents=True)
            exe.touch()
            self.apps.append(str(exe.resolve()))
        self.assertTrue(self.apps[0].startswith('/private/'), self.apps[0])

    def substitute(self, probe):
        return (probe.replace('RUN_EXE', json.dumps(self.apps[0]))
                     .replace('OTHER_EXE', json.dumps(self.apps[1])))

    def test_qa_identity_read_reproduces_run04_and_binds_the_private_path(self):
        probe = G.FAKE_SOURCE + self.substitute(r'''
let executable = RUN_EXE
// run-04: the QA app is live and on screen (it was born ~3 s before the first command), no modal.
kernelPath = executable
precondition(qaIdentity(42)?.path == executable, "kernel path \(executable) read back as \(qaIdentity(42)?.path ?? "nil")")
let f = Fake(); f.rows = [row(1, 42, qaBundle, layer: 25)]
var binding = QARunBinding()
let first = runModalInventory(f, binding: &binding, executable: executable, launchBirth: [100, 0],
    registered: [], candidates: [], requireQA: true, read: qaIdentityRead)
precondition(first.modals.isEmpty && first.errors.isEmpty, "run-04 qa-binding: \(first.errors)")
precondition(binding.identity?.pid == 42)
// /private/tmp against its /tmp form: both sides resolve to the one canonical path.
kernelPath = "/private/tmp"; precondition(qaIdentity(42)?.path == "/private/tmp")
kernelPath = "/tmp"; precondition(qaIdentity(42)?.path == "/private/tmp")
// Never a suffix or name match: same bundle layout and executable name in another directory.
kernelPath = OTHER_EXE; binding = QARunBinding()
let foreign = runModalInventory(f, binding: &binding, executable: executable, launchBirth: [100, 0],
    registered: [], candidates: [], requireQA: true, read: qaIdentityRead)
precondition(foreign.errors.map { $0["kind"] as? String } == ["qa-binding"] && binding.identity == nil)
print("PASS")
''')
        source = G.MODALS_PRELUDE + G.block(G.PERMISSIONS, 'FOREIGN MODALS') + FAKE_KERNEL
        adapter = G.block(G.PERMISSIONS, 'QA IDENTITY READ')
        source += adapter.replace('sysctl(', 'fake_sysctl(').replace('proc_pidpath(', 'fake_pidpath(') + probe
        self.assertEqual(G.run_swift(self, source).strip(), 'PASS')

    def test_recorder_executable_path_keeps_the_private_prefix(self):
        probe = self.substitute(r'''
kernelPath = RUN_EXE; precondition(qaExecutablePath(7) == RUN_EXE, "recorder read \(qaExecutablePath(7) ?? "nil")")
kernelPath = "/private/tmp"; precondition(qaExecutablePath(7) == "/private/tmp", "/private/tmp lost its prefix")
kernelPath = "/tmp"; precondition(qaExecutablePath(7) == "/private/tmp")
kernelPath = OTHER_EXE; precondition(qaExecutablePath(7) != RUN_EXE)
print("PASS")
''')
        block = G.block(G.CAPTURE, 'QA EXECUTABLE PATH').replace('proc_pidpath(', 'fake_pidpath(')
        source = 'import Foundation\n' + FAKE_KERNEL + block + probe
        self.assertEqual(G.run_swift(self, source).strip(), 'PASS')

    def test_one_canonicalisation_on_both_sides_of_every_comparison(self):
        shared = G.block(G.PERMISSIONS, 'CANONICAL PATH')
        self.assertEqual(shared, G.block(G.CAPTURE, 'CANONICAL PATH'))
        probe = self.substitute(r'''
precondition(canonicalPath("/tmp") == "/private/tmp" && canonicalPath("/private/tmp") == "/private/tmp")
precondition(canonicalPath(RUN_EXE) == RUN_EXE)
precondition(canonicalPath("/no/such/VoiceBar") == "/no/such/VoiceBar", "unresolvable stays exact")
print("PASS")
''')
        self.assertEqual(G.run_swift(self, 'import Foundation\n' + shared + probe).strip(), 'PASS')
        permissions, capture = G.PERMISSIONS.read_text(), G.CAPTURE.read_text()
        for source in (permissions, capture):
            self.assertNotIn('resolvingSymlinksInPath', source)
        # The executable side goes through the same function as the kernel side.
        self.assertIn('self.executable = canonicalPath(executable)', capture)
        self.assertIn('self.executable = canonicalPath(executable)', permissions)
        self.assertIn('argument("--qa-executable").map(canonicalPath)', permissions)
        self.assertIn('path: canonicalPath(String(cString: buffer))', permissions)


if __name__ == '__main__':
    unittest.main()
