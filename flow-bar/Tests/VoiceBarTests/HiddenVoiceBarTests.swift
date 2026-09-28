@testable import VoiceBar
@testable import VoiceBarUI
import XCTest

/// QA 2.2.25 C20: "Hide for 1 hour" reused `mode = .disconnected`, so the popover read "● Disconnected" while the
/// sockets were up. Etan's D1 (2026-09-25): while hidden, F5 must NOT dictate. Hidden gets its own copy; every
/// F5 / tap route stays closed until the bar is shown again.
@MainActor
final class HiddenVoiceBarTests: XCTestCase {
    private let until = Date(timeIntervalSince1970: 1_790_000_000)

    private func connectedState() -> VoiceState {
        let state = VoiceState(
            recentTranscriptionsLoader: { [] },
            recentTranscriptionsSaver: { _ in },
            recentTranscriptionEntriesLoader: { [] },
            recentTranscriptionEntriesSaver: { _ in }
        )
        state.setConnectionStatus(true)
        return state
    }

    private func recordCommands(_ commands: [[String: Any]]) -> Int {
        commands.filter { $0["cmd"] as? String == "record" }.count
    }

    // MARK: - Copy

    func testHiddenAndConnectedReadsHiddenUntilNeverDisconnected() {
        let state = connectedState()

        state.snooze(until: until)

        let footer = VoiceBarFooterPresentation.resolve(state: state)
        XCTAssertEqual(footer.status, SettingsVisibility.hiddenStatus(until: until))
        XCTAssertTrue(footer.status.hasPrefix("Hidden until "), footer.status)
        XCTAssertFalse(footer.status.contains("Disconnected"))
        XCTAssertTrue(footer.isHidden)
        XCTAssertFalse(footer.isReady)
    }

    func testARealDisconnectWhileHiddenStillReadsDisconnectedAfterShowing() {
        let state = connectedState()
        state.snooze(until: until)

        state.setConnectionStatus(false)
        XCTAssertEqual(VoiceBarFooterPresentation.resolve(state: state).status, "Disconnected")

        state.unsnooze()

        XCTAssertEqual(state.mode, .disconnected)
        XCTAssertEqual(VoiceBarFooterPresentation.resolve(state: state).status, "Disconnected")
    }

    func testShowingAgainRestoresIdleAndDropsTheHiddenCopy() {
        let state = connectedState()
        state.snooze(until: until)

        state.unsnooze()

        XCTAssertEqual(state.mode, .idle)
        XCTAssertNil(state.hiddenUntil)
        let footer = VoiceBarFooterPresentation.resolve(state: state)
        XCTAssertFalse(footer.isHidden)
        XCTAssertFalse(footer.status.hasPrefix("Hidden"))
    }

    func testShowingAfterAnAgentSpokeWhileHiddenStillEndsTheHide() {
        let state = connectedState()
        state.snooze(until: until)
        state.handleEvent(["type": "state", "state": "speaking", "text": "agent update"])
        state.handleEvent(["type": "state", "state": "idle"])

        state.unsnooze()

        XCTAssertFalse(state.isHidden)
        XCTAssertFalse(state.keepsPasteFlowEnvelope)
        XCTAssertEqual(state.mode, .idle)
    }

    // MARK: - F5 stays off while hidden

    func testF5WhileHiddenStartsNoRecording() {
        let state = connectedState()
        var commands: [[String: Any]] = []
        state.sendCommand = { commands.append($0) }
        let router = VoiceBarCommandRouter(voiceState: state)
        state.snooze(until: until)

        router.handleHotkeyHoldStart()
        router.handle(controlCommand: .toggle)
        router.handle(controlCommand: .startRecording)
        state.record(pressToTalk: true)

        XCTAssertEqual(recordCommands(commands), 0)
        XCTAssertNotEqual(state.mode, .recording)
    }

    func testF5WhileHiddenStaysOffAfterTheDaemonReconnects() {
        let state = connectedState()
        var commands: [[String: Any]] = []
        state.sendCommand = { commands.append($0) }
        let router = VoiceBarCommandRouter(voiceState: state)
        state.snooze(until: until)

        state.setConnectionStatus(false)
        state.setConnectionStatus(true)
        router.handleHotkeyHoldStart()

        XCTAssertEqual(recordCommands(commands), 0, "a reconnect must not reopen F5 while hidden")
        XCTAssertEqual(
            VoiceBarFooterPresentation.resolve(state: state).status,
            SettingsVisibility.hiddenStatus(until: until)
        )
    }

    func testF5WhileHiddenStaysOffAfterAnAgentFinishesSpeaking() {
        let state = connectedState()
        var commands: [[String: Any]] = []
        state.sendCommand = { commands.append($0) }
        let router = VoiceBarCommandRouter(voiceState: state)
        state.snooze(until: until)

        state.handleEvent(["type": "state", "state": "speaking", "text": "agent update"])
        state.handleEvent(["type": "state", "state": "idle"])
        router.handleHotkeyHoldStart()

        XCTAssertEqual(recordCommands(commands), 0, "an agent's speak ending must not reopen F5 while hidden")
    }

    func testF5DictatesAgainOnceShown() {
        let state = connectedState()
        var commands: [[String: Any]] = []
        state.sendCommand = { commands.append($0) }
        let router = VoiceBarCommandRouter(voiceState: state)
        state.snooze(until: until)

        state.unsnooze()
        router.handleHotkeyHoldStart()

        XCTAssertEqual(recordCommands(commands), 1)
    }

    // MARK: - App wiring

    func testHideForOneHourHandsItsEndTimeToVoiceState() {
        let app = AppDelegate()
        app.voiceState.setConnectionStatus(true)

        let hide = app.quickMenuActions().first { $0.title == "Hide for 1 hour" }
        XCTAssertNotNil(hide)
        hide?.perform()
        defer { app.unsnoozeNow() }

        XCTAssertNotNil(app.snoozedUntil)
        XCTAssertEqual(app.voiceState.hiddenUntil, app.snoozedUntil)
    }
}
