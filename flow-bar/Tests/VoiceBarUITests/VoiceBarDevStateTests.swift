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
        state.idleCollapseDelay = 0.05

        state.setHovering(false)
        XCTAssertFalse(state.isCollapsed)
        try await Task.sleep(for: .milliseconds(10))
        XCTAssertFalse(state.isCollapsed, "plain idle must receive the full grace interval")
        let didCollapse = try await waitUntil { state.isCollapsed }

        XCTAssertTrue(didCollapse)
        XCTAssertTrue(state.isCollapsed)
    }

    func testDebouncedPointerExitPerformsTheOnePlainIdleCollapseImmediately() {
        let state = VoiceState(keepsExpandedInDevState: false)
        state.mode = .idle
        state.setHoveringFromDebouncedPointer(true)

        state.setHoveringFromDebouncedPointer(false)

        XCTAssertFalse(state.isHovering)
        XCTAssertTrue(
            state.isCollapsed,
            "the hover coordinator already paid the 300-millisecond exit grace"
        )
    }

    func testDebouncedPointerExitDoesNotCollapseRetainedReadback() {
        let state = VoiceState(keepsExpandedInDevState: false)
        state.handleEvent([
            "type": "state",
            "state": "speaking",
            "text": "Keep this teleprompter until its own lifecycle resolves",
        ])
        state.handleEvent(["type": "state", "state": "idle", "source": "playback"])

        state.setHoveringFromDebouncedPointer(false)

        XCTAssertFalse(state.isCollapsed)
        XCTAssertTrue(state.isTeleprompterReadback)
    }

    func testCursorAbsentCaptureHoldCanStayExpandedWithoutAudioOrHover() {
        let state = VoiceState(keepsExpandedInDevState: true)
        state.mode = .idle

        state.setHoveringFromDebouncedPointer(false)

        XCTAssertFalse(state.isHovering)
        XCTAssertFalse(state.isCollapsed)
    }

    func testPlainVisibleIdleBeginsCollapseWithoutAHoverEvent() async throws {
        let state = VoiceState(keepsExpandedInDevState: false)
        state.idleCollapseDelay = 0.05

        state.beginIdleCollapseCountdown()

        XCTAssertFalse(state.isCollapsed)
        let didCollapse = try await waitUntil { state.isCollapsed }
        XCTAssertTrue(didCollapse)
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
        state.idleCollapseDelay = 0.05
        state.handleEvent(["type": "state", "state": "recording", "mode": "vad"])
        state.handleEvent(["type": "state", "state": "idle", "source": "recording"])

        XCTAssertFalse(state.isCollapsed)
        try await Task.sleep(for: .milliseconds(10))
        XCTAssertFalse(state.isCollapsed, "post-ask idle must receive a fresh full grace interval")
        let didCollapse = try await waitUntil { state.isCollapsed }

        XCTAssertEqual(state.mode, .idle)
        XCTAssertTrue(didCollapse)
    }

    func testDismissedPostSpeakReadbackStartsTheGeneralIdleCollapseDeadline() async throws {
        let state = VoiceState(keepsExpandedInDevState: false)
        state.idleCollapseDelay = 0.05
        state.handleEvent([
            "type": "state",
            "state": "speaking",
            "text": "Read this then collapse",
        ])
        state.handleEvent(["type": "state", "state": "idle", "source": "playback"])
        state.dismissRetainedTeleprompter()

        XCTAssertFalse(state.isCollapsed)
        try await Task.sleep(for: .milliseconds(10))
        XCTAssertFalse(state.isCollapsed, "post-speak idle must receive the full grace interval")
        let didCollapse = try await waitUntil { state.isCollapsed }

        XCTAssertTrue(didCollapse)
    }

    func testStopSpeakingClearsStaleSurfaceHoverBeforeIdleCollapseDeadline() async throws {
        let state = VoiceState(keepsExpandedInDevState: false)
        state.idleCollapseDelay = 0.05
        state.handleEvent([
            "type": "state",
            "state": "speaking",
            "text": "The square control is below the hardware core",
        ])
        state.setHovering(true)

        state.stop()

        XCTAssertEqual(state.mode, .idle)
        XCTAssertFalse(state.isHovering)
        XCTAssertFalse(state.isCollapsed)
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

        state.setHotkeyPhase(.idle)
        state.isCollapsed = true
        state.handleEvent([
            "type": "state",
            "state": "speaking",
            "text": "MCP activity",
        ])
        XCTAssertFalse(state.isCollapsed)
    }

    func testClosingAnIdleModalStartsAFreshCollapseDeadline() async throws {
        let state = VoiceState(keepsExpandedInDevState: false)
        state.idleCollapseDelay = 0.05
        state.beginModalInteraction()

        state.endModalInteraction()

        XCTAssertFalse(state.isCollapsed)
        try await Task.sleep(for: .milliseconds(10))
        XCTAssertFalse(state.isCollapsed)
        let didCollapse = try await waitUntil { state.isCollapsed }
        XCTAssertTrue(didCollapse)
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
