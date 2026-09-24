@testable import VoiceBar
@testable import VoiceBarUI
import XCTest

/// The picker shows the daemon's configured effort, or the selection in flight. VoiceBar keeps no
/// copy of its own (E2: a second store can drift from the daemon's truth).
final class PerformanceEffortSelectionTests: XCTestCase {
    private static let staleMirrorKey = "voicebar.performanceEffort"

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: Self.staleMirrorKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: Self.staleMirrorKey)
        super.tearDown()
    }

    private static func health(configured: String, active: String? = nil,
                               residency: String = "loaded") -> [String: Any] {
        [
            "type": "health",
            "recording_state": "idle",
            "model_status": [
                "configured_model": ["name": "large-v3-turbo", "size_bytes": 10, "installed": true],
                "residency": residency,
                "active_model": residency == "loaded" ? "large-v3-turbo" : NSNull(),
                "configured_effort": configured,
                "active_effort": (residency == "loaded" ? active ?? configured : nil) as Any? ?? NSNull(),
            ] as [String: Any],
        ]
    }

    private func connectedApp(configured: String = "accurate") -> (AppDelegate, () -> [String: Any]?) {
        let app = AppDelegate()
        var sent: [String: Any]?
        app.voiceState.sendCommand = { command in
            if command["cmd"] as? String == "set_whisper_effort" { sent = command }
        }
        app.voiceState.setConnectionStatus(true)
        app.voiceState.handleEvent(Self.health(configured: configured))
        return (app, { sent })
    }

    func testPickerShowsTheDaemonEffortNotAStaleLocalCopy() {
        UserDefaults.standard.set("fast", forKey: Self.staleMirrorKey)
        let (app, _) = connectedApp(configured: "balanced")

        XCTAssertEqual(app.currentPerformanceEffort(), .balanced)
    }

    func testAcceptedEffortIsNotMirroredLocally() throws {
        let (app, sent) = connectedApp()

        app.selectPerformanceEffort(.fast)
        let id = try XCTUnwrap(sent()?["id"] as? String)
        XCTAssertEqual(sent()?["cmd"] as? String, "set_whisper_effort")
        XCTAssertEqual(app.currentPerformanceEffort(), .fast)

        try app.voiceState.handleEvent([
            "type": "ack", "command": "set_whisper_effort", "outcome": "accept", "id": id,
            "model_status": XCTUnwrap(Self.health(configured: "fast")["model_status"]),
        ])

        XCTAssertEqual(app.currentPerformanceEffort(), .fast)
        XCTAssertEqual(app.voiceState.modelsSettingsState.configuredEffort, .fast)
        XCTAssertNil(UserDefaults.standard.string(forKey: Self.staleMirrorKey))
        XCTAssertNil(app.currentPerformanceEffortNotice())
    }

    func testReloadKeepsTheSelectionAndModelsBusyUntilTheFinalAck() throws {
        let (app, sent) = connectedApp()

        app.selectPerformanceEffort(.fast)
        let id = try XCTUnwrap(sent()?["id"] as? String)
        app.voiceState.handleEvent([
            "type": "ack", "command": "set_whisper_effort", "outcome": "loading", "id": id,
        ])

        XCTAssertEqual(app.currentPerformanceEffort(), .fast)
        XCTAssertTrue(app.voiceState.modelsSettingsState.isBusy)
        XCTAssertEqual(app.voiceState.modelsSettingsState.busyReason, "Reloading model…")
        XCTAssertNil(app.currentPerformanceEffortNotice())

        try app.voiceState.handleEvent([
            "type": "ack", "command": "set_whisper_effort", "outcome": "accept", "id": id,
            "model_status": XCTUnwrap(Self.health(configured: "fast")["model_status"]),
        ])

        XCTAssertFalse(app.voiceState.modelsSettingsState.isBusy)
        XCTAssertEqual(app.voiceState.modelsSettingsState.activeEffort, .fast)
    }

    func testAcceptWithReasonShowsWhyTheEffortIsNotActiveYet() throws {
        let (app, sent) = connectedApp()

        app.selectPerformanceEffort(.fast)
        let id = try XCTUnwrap(sent()?["id"] as? String)
        let reason = "Saved. The running model server was not started by VoiceLayer, "
            + "so it keeps its current effort until it restarts."
        try app.voiceState.handleEvent([
            "type": "ack", "command": "set_whisper_effort", "outcome": "accept", "id": id, "reason": reason,
            "model_status": XCTUnwrap(Self.health(configured: "fast", active: "accurate")["model_status"]),
        ])

        XCTAssertEqual(app.currentPerformanceEffort(), .fast)
        XCTAssertEqual(app.currentPerformanceEffortNotice(), reason)
    }

    func testRejectedEffortFallsBackToTheDaemonValueAndShowsNotice() throws {
        let (app, sent) = connectedApp(configured: "accurate")

        app.selectPerformanceEffort(.balanced)
        let id = try XCTUnwrap(sent()?["id"] as? String)
        app.voiceState.handleEvent([
            "type": "ack", "command": "set_whisper_effort", "outcome": "reject", "id": id, "reason": "busy",
        ])

        XCTAssertEqual(app.currentPerformanceEffort(), .accurate)
        XCTAssertNil(UserDefaults.standard.string(forKey: Self.staleMirrorKey))
        XCTAssertEqual(app.currentPerformanceEffortNotice(), "Couldn't change effort - busy, try again")
    }

    func testSelectingTheCurrentEffortSendsNothing() {
        let (app, sent) = connectedApp(configured: "fast")

        app.selectPerformanceEffort(.fast)

        XCTAssertNil(sent())
    }

    func testDisconnectDropsTheInFlightSelectionSoTheDaemonValueShows() {
        var sentCount = 0
        let app = AppDelegate()
        app.voiceState.sendCommand = { command in
            if command["cmd"] as? String == "set_whisper_effort" { sentCount += 1 }
        }
        app.voiceState.setConnectionStatus(true)
        app.voiceState.handleEvent(Self.health(configured: "accurate"))

        app.selectPerformanceEffort(.fast)
        XCTAssertEqual(app.currentPerformanceEffort(), .fast)

        app.voiceState.setConnectionStatus(false)
        app.voiceState.setConnectionStatus(true)
        app.voiceState.handleEvent(Self.health(configured: "accurate"))

        XCTAssertEqual(app.currentPerformanceEffort(), .accurate)
        app.selectPerformanceEffort(.fast)
        XCTAssertEqual(sentCount, 2, "re-selecting after a lost change must retry")
    }

    @MainActor
    func testUnansweredChangeTimesOutToTheDaemonValue() async throws {
        let (app, _) = connectedApp(configured: "accurate")
        app.performanceEffortAckTimeout = .milliseconds(50)

        app.selectPerformanceEffort(.fast)
        XCTAssertEqual(app.currentPerformanceEffort(), .fast)
        try await Task.sleep(for: .milliseconds(300))

        XCTAssertEqual(app.currentPerformanceEffort(), .accurate)
        XCTAssertNotNil(app.currentPerformanceEffortNotice())
    }

    func testMissingCommandClientDoesNotChangeEffort() {
        let app = AppDelegate()

        app.selectPerformanceEffort(.fast)

        XCTAssertNotEqual(app.currentPerformanceEffort(), .fast)
        XCTAssertEqual(
            app.currentPerformanceEffortNotice(),
            "Couldn't change effort - VoiceLayer is starting, try again"
        )
    }
}
