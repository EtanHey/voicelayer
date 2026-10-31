import XCTest
@testable import VoiceBarUI

@MainActor final class NativeUpdateGateTests: XCTestCase {
    func testPendingDaemonIntentsAndHistoryOwnersAreNotIdle() {
        let state = VoiceState()
        state.mode = .idle
        XCTAssertTrue(state.isUpdateDrainIdle)
        state.pendingIntent = PendingIntent(id: UUID().uuidString, command: .record)
        XCTAssertFalse(state.isUpdateDrainIdle, "record ingress precedes the daemon recording event")
        state.pendingIntent = nil
        state.historyPlayback.setVoiceOwner("synthetic", busy: true)
        XCTAssertFalse(state.isUpdateDrainIdle, "remote Ask can own audio before its state arrives")
        state.historyPlayback.setVoiceOwner("synthetic", busy: false)
        XCTAssertTrue(state.isUpdateDrainIdle)
    }

    func testAdmissionFaultsAndClosedLedgerParity() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("gate").path
        let lease: [String: Any] = ["generation": 1, "operationId": UUID().uuidString,
            "ownerId": UUID().uuidString, "targetSha": String(repeating: "a", count: 40)]
        func write(_ value: [String: Any]) throws { try JSONSerialization.data(withJSONObject: value).write(to: URL(fileURLWithPath: path)) }
        try write(["version": 1, "kind": "OPEN", "generation": 0, "released": NSNull()])
        try FileManager.default.createDirectory(atPath: path + ".admissions", withIntermediateDirectories: false)
        let gate = NativeUpdateGate(path: path)
        let release = try gate.acquire()
        let files = try FileManager.default.contentsOfDirectory(atPath: path + ".admissions")
        XCTAssertEqual(files.count, 1)
        let record = try String(contentsOfFile: path + ".admissions/" + XCTUnwrap(files.first))
        XCTAssertTrue(record.hasPrefix("{\"token\":"))
        XCTAssertNotNil(record.range(of: #"^\{"token":"[^"]+","pid":\d+,"incarnation":"[^"]+","generation":0\}\n$"#, options: .regularExpression))
        XCTAssertTrue(gate.permitsTermination(), "OPEN ignores orphan or active ledger; live activity is checked by the app")
        release()
        XCTAssertTrue(gate.permitsTermination())
        try write(["version": 1, "kind": "DRAINING", "lease": lease])
        XCTAssertThrowsError(try gate.acquire())
        XCTAssertNil(gate.acknowledge(lease: lease, idle: false))
        XCTAssertNotNil(gate.acknowledge(lease: lease, idle: true))
        XCTAssertFalse(gate.permitsTermination())
        try FileManager.default.removeItem(atPath: path + ".admissions")
        _ = try gate.acquire() // Missing closed ledger is a fault, never UPDATE_BUSY.
        XCTAssertTrue(FileManager.default.fileExists(atPath: path + ".voice-diag.json"))
        XCTAssertNil(gate.acknowledge(lease: lease, idle: true))
        XCTAssertFalse(FileManager.default.fileExists(atPath: path + ".lock"))
    }

    func testMalformedAndLockedGateNeverRefuseVoiceOrReapLock() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for fault in ["missing", "malformed", "locked"] {
            let path = root.appendingPathComponent(fault).path
            if fault == "malformed" { try Data("{}".utf8).write(to: URL(fileURLWithPath: path)) }
            if fault == "locked" {
                try Data("{}".utf8).write(to: URL(fileURLWithPath: path))
                try FileManager.default.createDirectory(atPath: path + ".lock", withIntermediateDirectories: false)
            }
            let gate = NativeUpdateGate(path: path)
            XCTAssertNoThrow(try gate.acquire()())
            XCTAssertTrue(gate.permitsTermination(), "faults do not strand quit")
            XCTAssertEqual(FileManager.default.fileExists(atPath: path + ".voice-diag.json"), fault != "missing")
            XCTAssertEqual(FileManager.default.fileExists(atPath: path + ".lock"), fault == "locked")
        }
    }

    func testBriefContentionDoesNotDiagnose() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("gate").path
        try Data(#"{"version":1,"kind":"OPEN","generation":0,"released":null}"#.utf8).write(to: URL(fileURLWithPath: path))
        try FileManager.default.createDirectory(atPath: path + ".admissions", withIntermediateDirectories: false)
        var collisions = 0
        for _ in 0..<100 {
            var attempts = 0, time: UInt64 = 0
            let gate = NativeUpdateGate(path: path, tryLock: { name in
                attempts += 1
                if attempts == 1 { errno = EEXIST; return false }
                return mkdir(name, 0o700) == 0
            }, monotonicNow: { defer { time += 250_000 }; return time })
            let release = try gate.acquire()
            XCTAssertEqual(attempts, 2, "retry a brief 0.25ms collision rather than diagnosing it")
            if FileManager.default.fileExists(atPath: path + ".voice-diag.json") { collisions += 1 }
            release()
        }
        print("G3 contention: \(collisions)/100 diagnostic markers (injected 0.25ms lock collisions)")
        XCTAssertEqual(collisions, 0)
        var attempts = 0, time: UInt64 = 0
        let stuck = NativeUpdateGate(path: path, tryLock: { _ in attempts += 1; errno = EEXIST; return false },
            monotonicNow: { defer { time += 1_000_000 }; return time })
        XCTAssertNoThrow(try stuck.acquire()())
        XCTAssertEqual(attempts, 2, "exhausted contention stops at the 2ms deadline")
        XCTAssertTrue(FileManager.default.fileExists(atPath: path + ".voice-diag.json"))
    }

    func testPlaybackHoldsAdmissionThroughQueueAndStopsBeforeRelease() {
        var events: [String] = []
        let playback = SettingsAudioPlayback(start: { _ in events.append("start"); return true },
            stop: { events.append("stop") }, admit: { events.append("admit"); return { events.append("release") } })
        let a = URL(fileURLWithPath: "/synthetic/a"), b = URL(fileURLWithPath: "/synthetic/b")
        playback.toggle([a, b])
        playback.playbackDidFinish(a)
        XCTAssertEqual(events, ["admit", "start", "start"])
        playback.stop()
        XCTAssertEqual(events, ["admit", "start", "start", "stop", "release"])
        let closed = SettingsAudioPlayback(start: { _ in XCTFail("opened audio"); return true }, stop: {},
            admit: { throw NativeUpdateGate.Fault.busy })
        closed.toggle(a)
        XCTAssertEqual(closed.failureMessage, NativeUpdateGate.busyMessage)
    }

    func testQuitNoticeDoesNotChangeRecordingOrStopControl() {
        let state = VoiceState()
        state.mode = .recording
        state.isCollapsed = true
        state.reportQuitRefusal()
        XCTAssertEqual(state.mode, .recording)
        XCTAssertNotNil(state.quitRefusalMessage)
        XCTAssertEqual(state.selectionFeedbackNote, state.quitRefusalMessage)
        XCTAssertFalse(state.isCollapsed, "a refused quit needs a visible explanation")
        var sent: [String] = []
        state.sendCommand = { sent.append($0["cmd"] as? String ?? "") }
        state.stop()
        XCTAssertEqual(sent.first, "stop")
    }

    func testStrictStateRejectsUnknownFieldsBooleansAndMismatchedAcks() {
        let lease: [String: Any] = ["generation": 1, "operationId": UUID().uuidString,
            "ownerId": UUID().uuidString, "targetSha": String(repeating: "b", count: 40)]
        let ack: [String: Any] = ["lease": lease, "activeOperations": 0, "openArchives": 0]
        var state: [String: Any] = ["version": 1, "kind": "PREPARED", "lease": lease, "native": ack, "daemon": ack]
        XCTAssertNotNil(NativeUpdateGate.validState(state))
        state["extra"] = 1
        XCTAssertNil(NativeUpdateGate.validState(state))
        state.removeValue(forKey: "extra")
        state["version"] = true
        XCTAssertNil(NativeUpdateGate.validState(state))
        state["version"] = 1
        state["daemon"] = ["lease": lease, "activeOperations": 1, "openArchives": 0]
        XCTAssertNil(NativeUpdateGate.validState(state))
    }
}
