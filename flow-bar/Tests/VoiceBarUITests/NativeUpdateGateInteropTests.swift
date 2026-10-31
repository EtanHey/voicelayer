import XCTest
@testable import VoiceBarUI

@MainActor final class NativeUpdateGateInteropTests: XCTestCase {
    func testBunAndSwiftShareMkdirAndLedger() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("gate").path
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        func peer(_ code: String) -> Process {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["bun", "-e", code]
            process.currentDirectoryURL = repo
            process.environment = ProcessInfo.processInfo.environment.merging([
                "NODE_ENV": "test", "VOICELAYER_TEST_RUN_ROOT": root.path,
                "VOICELAYER_TEST_ISOLATED": "1", "VOICELAYER_UPDATE_GATE_PATH": path,
                "VOICELAYER_TMP_ROOT": root.path, "VOICELAYER_STATE_DIR": root.path, "QA_VOICE_RECORDINGS_DIR": root.path + "/recordings"
            ]) { _, new in new }
            return process
        }
        func bun(_ code: String) throws -> String {
            let process = peer(code), output = Pipe()
            process.standardOutput = output; process.standardError = output
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0, String(decoding: data, as: UTF8.self))
            return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        _ = try bun("import {initializeVoiceGate} from './src/update-gate-admission'; await initializeVoiceGate();")
        let gate = NativeUpdateGate(path: path)
        let release = try gate.acquire()
        XCTAssertEqual(try bun("import {readdirSync} from 'node:fs'; console.log(readdirSync(process.env.VOICELAYER_UPDATE_GATE_PATH+'.admissions').length)"), "1")
        release()
        XCTAssertEqual(try bun("import {withUpdateGateLock} from './src/update-gate-storage'; console.log(withUpdateGateLock(() => 'owned'))"), "owned")
        let holder = peer("""
            import {withUpdateGateLock} from './src/update-gate-storage';
            import {existsSync,writeSync} from 'node:fs';
            withUpdateGateLock(() => {
              writeSync(1, 'LOCKED\\n');
              const stop = Date.now()+3000;
              while(!existsSync(process.env.VOICELAYER_UPDATE_GATE_PATH+'.release') && Date.now()<stop)
                Atomics.wait(new Int32Array(new SharedArrayBuffer(4)),0,0,10);
            });
            """)
        let ready = Pipe(); holder.standardOutput = ready
        try holder.run()
        XCTAssertEqual(ready.fileHandleForReading.readData(ofLength: 7), Data("LOCKED\n".utf8))
        XCTAssertEqual(try bun("import {readUpdateGateFile} from './src/update-gate-storage'; console.log(readUpdateGateFile().kind)"), "UNKNOWN")
        XCTAssertNoThrow(try gate.acquire()())
        XCTAssertTrue(FileManager.default.fileExists(atPath: path + ".lock"))
        try Data().write(to: URL(fileURLWithPath: path + ".release"))
        holder.waitUntilExit()
        XCTAssertEqual(holder.terminationStatus, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path + ".lock"))

        let lease: [String: Any] = ["generation": 1, "operationId": UUID().uuidString,
            "ownerId": UUID().uuidString, "targetSha": String(repeating: "a", count: 40)]
        var cases: [[String: Any]] = [["version": 1, "kind": "OPEN", "generation": 0, "released": NSNull()],
            ["version": true, "kind": "OPEN", "generation": 0, "released": NSNull()]]
        for generation: NSNumber in [0, 1, true, 1.5, 9_007_199_254_740_991, 9_007_199_254_740_992] {
            var value = lease; value["generation"] = generation
            cases.append(["version": 1, "kind": "DRAINING", "lease": value])
        }
        for owner in ["00000000-0000-0000-0000-000000000000", "ffffffff-ffff-ffff-ffff-ffffffffffff",
                      "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF", "11111111-1111-1111-1111-111111111111"] {
            var value = lease; value["ownerId"] = owner
            cases.append(["version": 1, "kind": "DRAINING", "lease": value])
        }
        let json = String(decoding: try JSONSerialization.data(withJSONObject: cases), as: UTF8.self)
        let result = try bun("import {readUpdateGate} from './src/update-gate'; console.log(JSON.stringify((" + json + ").map(v=>readUpdateGate(v).kind!=='UNKNOWN'))) ")
        let ts = try JSONSerialization.jsonObject(with: Data(result.utf8)) as? [Bool]
        XCTAssertEqual(ts, cases.map { NativeUpdateGate.validState($0) != nil })
    }

}
