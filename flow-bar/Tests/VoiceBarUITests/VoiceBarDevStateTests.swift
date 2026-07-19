@testable import VoiceBarUI
import XCTest

final class VoiceBarDevStateTests: XCTestCase {
    func testKeepExpandedDefaultsOff() {
        XCTAssertFalse(
            VoiceBarDevState.shouldKeepExpanded(
                environment: [:],
                fileExists: { _ in false }
            )
        )
    }

    func testKeepExpandedAcceptsExplicitEnvironmentOptIn() {
        XCTAssertTrue(
            VoiceBarDevState.shouldKeepExpanded(
                environment: [VoiceBarDevState.keepExpandedEnvironmentVariable: " 1 "],
                fileExists: { _ in false }
            )
        )
    }

    func testKeepExpandedAcceptsTmpFlagOptIn() {
        XCTAssertTrue(
            VoiceBarDevState.shouldKeepExpanded(
                environment: [:],
                fileExists: { $0 == VoiceBarDevState.keepExpandedFlagPath }
            )
        )
    }

    func testEnabledDevStateStaysExpandedPastIdleCollapseDelay() async throws {
        let state = VoiceState(keepsExpandedInDevState: true)
        state.idleCollapseDelay = 0.01

        state.setHovering(false)
        let didCollapse = try await waitUntil { state.isCollapsed }

        XCTAssertFalse(didCollapse)
        XCTAssertFalse(state.isCollapsed)
    }

    func testDisabledDevStatePreservesIdleCollapse() async throws {
        let state = VoiceState(keepsExpandedInDevState: false)
        state.idleCollapseDelay = 0.01

        state.setHovering(false)
        let didCollapse = try await waitUntil { state.isCollapsed }

        XCTAssertTrue(didCollapse)
        XCTAssertTrue(state.isCollapsed)
    }

    func testRetainedTeleprompterStaysExpandedPastIdleCollapseDelay() async throws {
        let state = VoiceState(keepsExpandedInDevState: false)
        state.idleCollapseDelay = 0.01
        state.handleEvent([
            "type": "state",
            "state": "speaking",
            "text": "Read this after playback",
        ])
        state.handleEvent([
            "type": "state",
            "state": "idle",
            "source": "playback",
        ])

        state.setHovering(false)
        let didCollapse = try await waitUntil { state.isCollapsed }

        XCTAssertFalse(didCollapse)
        XCTAssertFalse(state.isCollapsed)
        XCTAssertTrue(state.isTeleprompterReadback)
    }

    func testPostAskRecordingIdleCollapsesAfterAFreshFullDeadline() async throws {
        let state = VoiceState(keepsExpandedInDevState: false)
        state.idleCollapseDelay = 0.01
        state.handleEvent(["type": "state", "state": "recording", "mode": "vad"])
        state.handleEvent(["type": "state", "state": "idle", "source": "recording"])

        let didCollapse = try await waitUntil { state.isCollapsed }

        XCTAssertEqual(state.mode, .idle)
        XCTAssertTrue(didCollapse)
    }

    func testDismissedPostSpeakReadbackStartsTheGeneralIdleCollapseDeadline() async throws {
        let state = VoiceState(keepsExpandedInDevState: false)
        state.idleCollapseDelay = 0.01
        state.handleEvent([
            "type": "state",
            "state": "speaking",
            "text": "Read this then collapse",
        ])
        state.handleEvent(["type": "state", "state": "idle", "source": "playback"])
        state.dismissRetainedTeleprompter()

        let didCollapse = try await waitUntil { state.isCollapsed }

        XCTAssertTrue(didCollapse)
    }

    func testF5AndMCPActivityImmediatelyExpandCollapsedIdle() async throws {
        let state = VoiceState(keepsExpandedInDevState: false)
        state.idleCollapseDelay = 0.01
        state.setHovering(false)
        _ = try await waitUntil { state.isCollapsed }

        state.setHotkeyEnabled(true)
        state.setHotkeyPhase(.pressing)
        XCTAssertFalse(state.isCollapsed)

        state.isCollapsed = true
        state.handleEvent([
            "type": "state",
            "state": "speaking",
            "text": "MCP activity",
        ])
        XCTAssertFalse(state.isCollapsed)
    }

    private func waitUntil(_ condition: () -> Bool) async throws -> Bool {
        for _ in 0 ..< 100 {
            if condition() {
                return true
            }
            try await Task.sleep(for: .milliseconds(2))
        }
        return condition()
    }
}
