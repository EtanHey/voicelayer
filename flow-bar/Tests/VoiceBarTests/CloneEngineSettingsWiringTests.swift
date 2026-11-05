import Foundation
@testable import VoiceBar
@testable import VoiceBarUI
import XCTest

/// U3b: the Speech engine row only works if the app hands Settings one long-lived view model, feeds it V10
/// snapshots, and chains `clone_engine` acknowledgements into the single `onAckEvent` closure (PR #690 gap 4).
final class CloneEngineSettingsWiringTests: XCTestCase {
    private func appSource() throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("Sources/VoiceBar/VoiceBarApp.swift"), encoding: .utf8)
    }

    func testAppPassesOneViewModelAndChainsAcksAndSnapshots() throws {
        let source = try appSource()
        XCTAssertTrue(source.contains("private lazy var cloneEngineControl = CloneEngineControlViewModel("),
                      "created once, outside makeSettingsView (which runs on every rebuild)")
        XCTAssertTrue(source.contains("cloneEngineControl: cloneEngineControl,"))
        let ack = try XCTUnwrap(source.components(separatedBy: "voiceState.onAckEvent = { [weak self] ack in")
            .dropFirst().first?.components(separatedBy: "\n        }").first)
        XCTAssertTrue(ack.contains("self?.handlePerformanceEffortAck(ack)"), "the effort ack keeps its handler")
        XCTAssertTrue(ack.contains("self?.cloneEngineControl.receive(ack: ack)"))
        XCTAssertEqual(source.components(separatedBy: "voiceState.onAckEvent =").count - 1, 1, "never reassigned")
        XCTAssertTrue(source.contains("self?.cloneEngineControl.receive(snapshot: self?.voiceState.cloneEngine)"))
        XCTAssertTrue(source.contains("cloneEngineControl.receive(snapshot: voiceState.cloneEngine)"))
    }

    /// The same path at the VoiceState boundary: an in-app `clone_engine` ack (the reply `sendCommand` feeds back
    /// through `handleEvent`) reaches the view model through `onAckEvent`, before `send` returns.
    func testInAppAckReachesTheViewModelThroughOnAckEvent() {
        let state = VoiceState(recentTranscriptionsLoader: { [] }, recentTranscriptionsSaver: { _ in },
                               recentTranscriptionEntriesLoader: { [] }, recentTranscriptionEntriesSaver: { _ in })
        state.handleEvent(CloneEngineSnapshot(state: .stopped, since: "2026-11-05T09:14:00Z", reason: "user_stop",
                                              pid: nil, startWithVoiceBar: true).payload)
        var viewModel: CloneEngineControlViewModel?
        viewModel = CloneEngineControlViewModel(snapshot: state.cloneEngine, send: { command in
            state.handleEvent(["type": "ack", "command": "clone_engine", "outcome": "reject",
                               "reason": "isolated_app", "id": command.id])
            return true
        })
        state.onAckEvent = { viewModel?.receive(ack: $0) }
        viewModel?.press(.start)
        XCTAssertEqual(viewModel?.presentation().note,
                       "Only the installed VoiceBar can control the voice engine. This copy can't.")
        XCTAssertEqual(viewModel?.presentation().pill, "Stopped")
    }
}
