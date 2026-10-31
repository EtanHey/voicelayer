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
            XCTAssertEqual(app.applicationShouldTerminate(.shared), .terminateCancel)
            app.voiceState.pendingIntent = nil
        }
        app.voiceState.mode = .idle
        try Data().write(to: URL(fileURLWithPath: path + ".voice-diag.json"))
        XCTAssertEqual(app.applicationShouldTerminate(.shared), .terminateNow)
        app.voiceState.mode = .recording
        XCTAssertEqual(app.applicationShouldTerminate(.shared), .terminateCancel)
        app.voiceState.mode = .idle
        try FileManager.default.removeItem(atPath: path)
        XCTAssertEqual(app.applicationShouldTerminate(.shared), .terminateNow)
    }

    func testAcknowledgedControlledQuitCannotBeCancelledByLaterIngress() {
        var policy = VoiceBarTerminationPolicy()
        policy.authorize(.controlledUpdate)
        policy.authorize(.menuBar)
        XCTAssertEqual(policy.reply(enforcesSingleton: true, voiceBusy: true, gatePermitsQuit: false), .terminateNow)
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

    func testLevelMeterCannotOpenInputDuringDrainAndReleasesAfterStop() throws {
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
        XCTAssertEqual(engine.starts, 1, "closed gate must refuse before opening the level input")
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
