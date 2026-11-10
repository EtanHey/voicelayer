import CryptoKit
import XCTest
@testable import VoiceBar
import VoiceBarUI

@MainActor final class NativeDrainParticipantTests: XCTestCase {
    func testApplicationQuitWiringAndStrictDrain() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("gate").path, app = AppDelegate()
        app.terminationGateForTesting = NativeUpdateGate(path: path)
        app.terminationOwnsServerForTesting = true
        app.terminationCleanupForTesting = {}
        let open = Data(#"{"version":1,"kind":"OPEN","generation":0,"released":null}"#.utf8)
        try open.write(to: URL(fileURLWithPath: path))
        try FileManager.default.createDirectory(atPath: path + ".admissions", withIntermediateDirectories: false)
        try Data("orphan".utf8).write(to: URL(fileURLWithPath: path + ".admissions/orphan"))
        for mode: VoiceMode in [.disconnected, .error] {
            app.voiceState.mode = mode
            XCTAssertFalse(app.voiceState.isUpdateDrainIdle)
            XCTAssertEqual(app.applicationShouldTerminate(.shared), .terminateNow)
            app.voiceState.pendingIntent = PendingIntent(id: UUID().uuidString, command: .record)
            XCTAssertEqual(app.applicationShouldTerminate(.shared), .terminateLater)
            app.voiceState.pendingIntent = nil
        }
        app.voiceState.mode = .idle
        try Data().write(to: URL(fileURLWithPath: path + ".voice-diag.json"))
        XCTAssertEqual(app.applicationShouldTerminate(.shared), .terminateNow)
        app.voiceState.mode = .recording
        XCTAssertEqual(app.applicationShouldTerminate(.shared), .terminateLater)
        app.voiceState.handleEvent(["type": "state", "state": "idle", "source": "recording"])
        try FileManager.default.removeItem(atPath: path)
        XCTAssertEqual(app.applicationShouldTerminate(.shared), .terminateNow)
    }

    func testUserQuitWithDeadControllerAndCommittedGateKeepsRecoveryEvidence() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("gate").path
        let lease: [String: Any] = ["generation": 1, "operationId": UUID().uuidString,
            "ownerId": UUID().uuidString, "targetSha": String(repeating: "a", count: 40)]
        let ack: [String: Any] = ["lease": lease, "activeOperations": 0, "openArchives": 0]
        let bytes = try JSONSerialization.data(withJSONObject: ["version": 1, "kind": "COMMITTED",
            "lease": lease, "native": ack, "daemon": ack])
        try bytes.write(to: URL(fileURLWithPath: path))
        try FileManager.default.createDirectory(atPath: path + ".admissions", withIntermediateDirectories: false)
        // A reaped child gives a real dead PID without signalling any resident process.
        let child = Process(); child.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try child.run(); child.waitUntilExit()
        let controller = try JSONSerialization.data(withJSONObject: ["version": 1, "lease": ["generation": 1, "operationId": lease["operationId"]!],
            "pid": child.processIdentifier, "identity": "retired"])
        try controller.write(to: URL(fileURLWithPath: path + ".controller"))
        let app = AppDelegate()
        app.terminationGateForTesting = NativeUpdateGate(path: path)
        app.terminationOwnsServerForTesting = true
        var cleanups = 0
        app.terminationCleanupForTesting = { cleanups += 1 }
        app.voiceState.mode = .idle
        // Exercise the same AppKit delegate used by the menu, without terminating the test host.
        XCTAssertEqual(app.applicationShouldTerminate(.shared), .terminateNow)
        XCTAssertEqual(cleanups, 1)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), bytes)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path + ".controller")), controller)
    }

    func testUserQuitWaitsForArchiveReceiptOrBoundAndNeverDeletesKeptAudio() async throws {
        for archiveCompletes in [true, false] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/clean_speech.wav")
            let raw = root.appendingPathComponent("retained.wav"), archive = root.appendingPathComponent("audio.wav")
            let bytes = try Data(contentsOf: fixture)
            try bytes.write(to: raw)
            let app = AppDelegate()
            app.terminationOwnsServerForTesting = true
            app.terminationGateForTesting = NativeUpdateGate(path: root.appendingPathComponent("gate").path)
            app.voiceState.mode = .recording
            app.voiceState.handleEvent(["type": "audio_level", "rms": 0.2])
            var stops = 0, ticks = 0, exited = false
            app.voiceState.sendCommand = { if $0["cmd"] as? String == "stop" { stops += 1 } }
            var instant = ContinuousClock().now
            app.terminationSaveNowForTesting = { instant }
            app.terminationSaveSleepForTesting = { duration in
                instant = instant.advanced(by: duration)
                ticks += 1
                XCTAssertFalse(exited)
                if archiveCompletes, ticks == 3 {
                    // The daemon's archive boundary, stepped without audio or wall-clock sleeps.
                    do { try FileManager.default.copyItem(at: raw, to: archive) }
                    catch { XCTFail("Synthetic archive publication failed: \(error)") }
                    app.voiceState.handleEvent(["type": "state", "state": "transcribing", "stt_audio_ms": 1000])
                }
            }
            defer { app.terminationSaveSleepForTesting = nil; app.terminationSaveNowForTesting = nil }
            app.terminationCleanupForTesting = {
                XCTAssertEqual(try? Data(contentsOf: raw), bytes)
                XCTAssertEqual(FileManager.default.fileExists(atPath: archive.path), archiveCompletes)
                exited = true
            }
            XCTAssertEqual(app.applicationShouldTerminate(.shared), .terminateLater)
            XCTAssertEqual(stops, 1)
            XCTAssertEqual(app.voiceState.quitRefusalMessage, "Saving dictation before quitting…")
            XCTAssertTrue(app.voiceState.isSavingDictationForQuit, "optimistic Stop is not archive proof")
            for _ in 0..<200 where !exited { await Task.yield() }
            XCTAssertTrue(exited)
            XCTAssertEqual(ticks, archiveCompletes ? 3 : 60)
        }
    }

    func testLegacySaveWaitRetiresOnCancellationFailureDisconnectAndNewCapture() {
        for terminal in ["cancel", "error", "disconnect", "restart", "new-capture"] {
            let state = VoiceState()
            state.mode = .recording
            state.stop()
            XCTAssertTrue(state.isSavingDictationForQuit)
            switch terminal {
            case "cancel": state.handleEvent(["type": "state", "state": "idle"])
            case "error": state.handleEvent(["type": "error", "message": "capture failed"])
            case "disconnect": state.setConnectionStatus(false)
            case "restart": state.setConnectionStatus(true)
            default: state.handleEvent(["type": "state", "state": "recording"])
            }
            state.mode = .idle
            state.pendingIntent = nil
            XCTAssertFalse(state.isSavingDictationForQuit, terminal)
            var policy = VoiceBarTerminationPolicy()
            policy.authorize(.controlledUpdate)
            XCTAssertEqual(policy.reply(enforcesSingleton: true, voiceBusy: state.isSavingDictationForQuit,
                                        gatePermitsQuit: false), .terminateNow, terminal)
        }
    }

    func testAcknowledgedControlledQuitCannotBeCancelledByLaterIngress() {
        var policy = VoiceBarTerminationPolicy()
        policy.authorize(.controlledUpdate)
        policy.authorize(.menuBar)
        XCTAssertEqual(policy.reply(enforcesSingleton: true, voiceBusy: true, gatePermitsQuit: false), .terminateNow)
    }

    func testReplacementSurvivesIncumbentsFullSaveWindowAndCleanup() async {
        var incumbent = VoiceBarTerminationPolicy()
        XCTAssertEqual(incumbent.reply(enforcesSingleton: true, voiceBusy: true), .terminateLater)
        let start = ContinuousClock().now
        var instant = start
        await VoiceBarQuitDeferral.waitWhileSaving({ true }, now: { instant }, sleep: { _ in
            instant = instant.advanced(by: .milliseconds(150))
        })
        let elapsed = start.duration(to: instant).components
        let saveElapsed = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
        let incumbentExit = saveElapsed + VoiceBarDaemonController.acceptedQuitWait - 0.1
        var time: TimeInterval = 0
        let newcomerContinues = AppDelegate.waitForIncumbents([123], isAlive: { _ in time < incumbentExit },
            now: { time }, wait: { time += $0 })
        XCTAssertTrue(newcomerContinues, "the newcomer must outlive the incumbent's deferred quit")
        time = max(time, incumbentExit)
        let runningCopies = (time < incumbentExit ? 1 : 0) + (newcomerContinues ? 1 : 0)
        XCTAssertEqual(runningCopies, 1, "the incumbent's later exit must not leave zero copies")
        incumbent.authorize(.internalFailure)
        XCTAssertEqual(incumbent.reply(enforcesSingleton: true, voiceBusy: true), .terminateCancel)
    }

    func testSlowAcceptingIncumbentLeavesReplacementRunning() {
        var time: TimeInterval = 0
        let acceptedQuitCleanup: TimeInterval = 2.1
        XCTAssertTrue(AppDelegate.waitForIncumbents([123], isAlive: { _ in time < acceptedQuitCleanup },
            now: { time }, wait: { time += $0 }))
        XCTAssertGreaterThanOrEqual(time, acceptedQuitCleanup)
        time = 0
        XCTAssertFalse(AppDelegate.waitForIncumbents([123], isAlive: { _ in true }, now: { time }, wait: { time += $0 }))
        XCTAssertGreaterThanOrEqual(time, 2.5, "never conclude refusal before both daemon stop waits plus margin")
    }

    func testLevelMeterRegistersDuringDrainAndRefusesPreparedBeforeInput() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("gate").path
        try FileManager.default.createDirectory(atPath: path + ".admissions", withIntermediateDirectories: false)
        let gate = NativeUpdateGate(path: path), app = AppDelegate(), engine = UIE2ENoDeviceLevelEngine()
        app.configureAudioLevelMonitoringForTesting(engine: engine)
        try Data(#"{"version":1,"kind":"OPEN","generation":0,"released":null}"#.utf8).write(to: URL(fileURLWithPath: path))
        app.startAudioLevelMonitoring(gate: gate)
        XCTAssertEqual(engine.starts, 1)
        XCTAssertTrue(gate.permitsTermination())
        app.stopAudioLevelMonitoring()
        XCTAssertTrue(gate.permitsTermination())
        try Data(#"{"version":1,"kind":"DRAINING","lease":{"generation":1,"operationId":"00000000-0000-0000-0000-000000000000","ownerId":"ffffffff-ffff-ffff-ffff-ffffffffffff","targetSha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}}"#.utf8).write(to: URL(fileURLWithPath: path))
        app.startAudioLevelMonitoring(gate: gate)
        XCTAssertEqual(engine.starts, 2, "DRAINING must admit the device-free level fixture")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: path + ".admissions").count, 1)
        app.stopAudioLevelMonitoring()
        let lease: [String: Any] = ["generation": 1, "operationId": UUID().uuidString,
            "ownerId": UUID().uuidString, "targetSha": String(repeating: "a", count: 40)]
        let ack: [String: Any] = ["lease": lease, "activeOperations": 0, "openArchives": 0]
        try JSONSerialization.data(withJSONObject: ["version": 1, "kind": "PREPARED", "lease": lease,
            "native": ack, "daemon": ack]).write(to: URL(fileURLWithPath: path))
        app.startAudioLevelMonitoring(gate: gate)
        XCTAssertEqual(engine.starts, 2, "PREPARED must refuse before opening the level input")
    }

    func testSignedDrainAndControlledQuitRequireLiveIdleAndExactCommittedLease() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("gate").path
        try FileManager.default.createDirectory(atPath: path + ".admissions", withIntermediateDirectories: false)
        let gate = NativeUpdateGate(path: path)
        let lease: [String: Any] = ["generation": 1, "operationId": "00000000-0000-0000-0000-000000000000",
            "ownerId": "ffffffff-ffff-ffff-ffff-ffffffffffff", "targetSha": String(repeating: "a", count: 40)]
        func state(_ kind: String) throws {
            var value: [String: Any] = ["version": 1, "kind": kind, "lease": lease]
            if kind == "COMMITTED" {
                let ack: [String: Any] = ["lease": lease, "activeOperations": 0, "openArchives": 0]
                value["native"] = ack; value["daemon"] = ack
            }
            try JSONSerialization.data(withJSONObject: value).write(to: URL(fileURLWithPath: path))
        }
        func request(_ action: String) -> [String: Any] {
            let id = "11111111-1111-4111-8111-111111111111", incarnation = "22222222-2222-4222-8222-222222222222"
            let message = "\(action)|\(id)|123|\(incarnation)|1|\(lease["operationId"]!)|\(lease["ownerId"]!)|\(lease["targetSha"]!)"
            let mac = HMAC<SHA256>.authenticationCode(for: Data(message.utf8),
                using: SymmetricKey(data: Data(NativeDrainParticipant.secret.utf8))).map { String(format: "%02x", $0) }.joined()
            return ["id": id, "pid": 123, "incarnation": incarnation, "action": action, "lease": lease, "mac": mac]
        }
        try state("DRAINING")
        XCTAssertNotNil(NativeDrainParticipant.reply(request("drain"), ownedDaemonPID: 123, idle: true, gate: gate))
        XCTAssertNil(NativeDrainParticipant.reply(request("drain"), ownedDaemonPID: 456, idle: true, gate: gate))
        XCTAssertNil(NativeDrainParticipant.reply(request("drain"), ownedDaemonPID: 123, idle: false, gate: gate))
        var spoof = request("drain"); spoof["mac"] = String(repeating: "0", count: 64)
        XCTAssertNil(NativeDrainParticipant.reply(spoof, ownedDaemonPID: 123, idle: true, gate: gate))
        spoof["mac"] = String(repeating: "é", count: 32)
        XCTAssertNil(NativeDrainParticipant.reply(spoof, ownedDaemonPID: 123, idle: true, gate: gate))
        XCTAssertNil(NativeDrainParticipant.reply(request("quit"), ownedDaemonPID: 123, idle: true, gate: gate))
        try state("COMMITTED")
        XCTAssertFalse(gate.permitsTermination())
        var wrongLease = lease; wrongLease["generation"] = 2
        XCTAssertFalse(gate.permitsTermination(controlledLease: wrongLease))
        XCTAssertTrue(gate.permitsTermination(controlledLease: lease))
        XCTAssertNotNil(NativeDrainParticipant.reply(request("quit"), ownedDaemonPID: 123, idle: true, gate: gate))
        try Data().write(to: URL(fileURLWithPath: path + ".voice-diag.json"))
        XCTAssertNil(NativeDrainParticipant.reply(request("quit"), ownedDaemonPID: 123, idle: true, gate: gate))
    }
}
