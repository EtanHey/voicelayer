import AppKit
@testable import VoiceBarUI
import XCTest

/// R0856-12 (walkthrough 2026-11-02 08:56, 74.1-75.5 s; VoiceBar log 08:58:05.582 -> 08:58:07.124): the idle
/// wings collapsed to the bare notch while VoiceBar's own Settings window was key, because the pointer's
/// debounced exit collapses idle at once, then re-expanded when the pointer returned. Order-of-events proof:
/// formal/idle-wings (Old FAIL, Fixed PASS).
@MainActor
final class IdleWingsFocusTests: XCTestCase {
    private func idleExpandedState() -> VoiceState {
        let state = VoiceState(recentTranscriptionsLoader: { [] }, recentTranscriptionsSaver: { _ in },
                               recentTranscriptionEntriesLoader: { [] }, recentTranscriptionEntriesSaver: { _ in },
                               keepsExpandedInDevState: false)
        state.isConnected = true
        state.mode = .idle
        state.setHoveringFromDebouncedPointer(true)
        XCTAssertFalse(state.isCollapsed)
        return state
    }

    private func shell(_ state: VoiceState) -> VoiceBarNotchVisualState {
        VoiceBarPresentation.notchPresentation(from: .init(
            mode: state.mode, isHovered: state.isHovering, isCollapsed: state.isCollapsed)).visualState
    }

    func testThePointerLeavingForSettingsKeepsTheIdleWings() {
        let state = idleExpandedState()
        state.setVoiceBarWindowFocused(true)
        state.setHoveringFromDebouncedPointer(false) // the 2.5 s exit grace has elapsed
        XCTAssertFalse(state.isCollapsed, "the wings must not vanish while Settings has focus")
        XCTAssertEqual(shell(state), .hoverLauncher)
    }

    func testWithoutAFocusedVoiceBarWindowThePointerExitStillCollapses() {
        let state = idleExpandedState()
        state.setHoveringFromDebouncedPointer(false)
        XCTAssertTrue(state.isCollapsed, "the ordinary exit collapse is unchanged")
        XCTAssertEqual(shell(state), .idle)
    }

    func testTheIdleCountdownResumesWhenSettingsResigns() async {
        let state = idleExpandedState()
        state.idleCollapseDelay = 0.05
        state.setVoiceBarWindowFocused(true)
        state.setHoveringFromDebouncedPointer(false)
        try? await Task.sleep(for: .milliseconds(150))
        XCTAssertFalse(state.isCollapsed, "no countdown runs while Settings has focus")
        state.setVoiceBarWindowFocused(false)
        var collapsed = false
        for _ in 0 ..< 100 where !collapsed {
            try? await Task.sleep(for: .milliseconds(10))
            collapsed = state.isCollapsed
        }
        XCTAssertTrue(collapsed, "the wings collapse on the ordinary countdown after Settings resigns")
    }

    func testFocusNeverExpandsACollapsedNotch() {
        let state = idleExpandedState()
        state.setHoveringFromDebouncedPointer(false)
        XCTAssertTrue(state.isCollapsed)
        state.setVoiceBarWindowFocused(true)
        XCTAssertTrue(state.isCollapsed, "opening Settings from a collapsed notch does not pop the wings out")
    }

    func testOnlyVoiceBarsOtherWindowsHoldTheWings() {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10), styleMask: .borderless,
                            backing: .buffered, defer: true)
        let settings = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10), styleMask: .titled,
                                backing: .buffered, defer: true)
        XCTAssertFalse(VoiceBarWindowFocus.holdsIdleWings(keyWindow: nil, notchPanel: panel))
        XCTAssertFalse(VoiceBarWindowFocus.holdsIdleWings(keyWindow: panel, notchPanel: panel))
        XCTAssertFalse(VoiceBarWindowFocus.holdsIdleWings(keyWindow: settings, notchPanel: panel), "not visible")
    }
}
