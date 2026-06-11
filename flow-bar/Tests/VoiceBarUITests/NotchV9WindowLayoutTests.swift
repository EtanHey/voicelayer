import AppKit
import SwiftUI
@testable import VoiceBarUI
import XCTest

/// Live-window layout regression for v9. The ImageRenderer snapshot tests render at a
/// fixed proposed size and never exercise the NSWindow `setContentSize` →
/// `_postWindowNeedsUpdateConstraints` cycle that ABORTED v9.0 (SIGABRT, NSException in
/// AppKit) when the flanking recording band used ambiguous `maxWidth:.infinity` wings.
/// This test hosts BarView in a real NSWindow/NSHostingView and drives the resize path
/// across every mode + the collapse transition. If the layout is ambiguous the AppKit
/// exception aborts the test process; a clean pass means the window can size to the
/// content without throwing.
@MainActor
final class NotchV9WindowLayoutTests: XCTestCase {
    final class Router: BarCommandRouting {
        func handlePrimaryTap() {}
        func handleCancel() {}
        func handleStop() {}
        func handleReplay() {}
    }

    private func state(for mode: VoiceMode) -> VoiceState {
        let s = VoiceState()
        s.mode = mode
        s.isConnected = true
        s.hotkeyEnabled = true
        s.isCollapsed = false
        switch mode {
        case .recording: s.audioLevel = 0.45
        case .transcribing: s.transcript = "Draft transcript"
        case .speaking:
            s.statusText = "Speaking this sample line"
            s.wordBoundaries = [(0, 400, "Speaking"), (450, 300, "this")]
        case .error: s.errorMessage = "Try again"
        default: break
        }
        return s
    }

    func testFlankingBandSizesToWindowAcrossEveryModeWithoutAborting() {
        _ = NSApplication.shared

        let driver = VoiceState()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: Theme.panelWidth, height: Theme.panelHeight),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let host = NSHostingView(rootView: BarView(state: driver, commandRouter: Router()))
        window.contentView = host

        // Cycle through every mode (recording revisited, since its flanking band is the
        // widest resize and the one that aborted), forcing the window/host layout each time.
        let sequence: [VoiceMode] = [
            .idle,
            .recording,
            .transcribing,
            .speaking,
            .idle,
            .recording,
            .error,
            .recording,
            .idle,
        ]
        for mode in sequence {
            let s = state(for: mode)
            driver.mode = s.mode
            driver.audioLevel = s.audioLevel
            driver.statusText = s.statusText
            driver.transcript = s.transcript
            driver.errorMessage = s.errorMessage
            driver.wordBoundaries = s.wordBoundaries

            let layout = VoiceBarPanelLayout.make(
                mode: mode,
                isCollapsed: false,
                previewText: nil,
                statusText: s.statusText,
                padding: Theme.panelPadding
            )
            window.setContentSize(layout.panelSize)
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
        }

        // Collapse + re-expand — the largest resize deltas (wide recording <-> 30pt dot).
        driver.mode = .recording
        window.setContentSize(VoiceBarPanelLayout.make(
            mode: .recording,
            isCollapsed: false,
            previewText: nil,
            statusText: "",
            padding: Theme.panelPadding
        ).panelSize)
        host.layoutSubtreeIfNeeded()
        driver.isCollapsed = true
        window.setContentSize(CGSize(width: 38, height: 38))
        host.layoutSubtreeIfNeeded()
        driver.isCollapsed = false
        driver.mode = .recording
        window.setContentSize(VoiceBarPanelLayout.make(
            mode: .recording,
            isCollapsed: false,
            previewText: nil,
            statusText: "",
            padding: Theme.panelPadding
        ).panelSize)
        host.layoutSubtreeIfNeeded()

        XCTAssertNotNil(window.contentView)
        XCTAssertGreaterThan(host.fittingSize.width, 0)
        XCTAssertFalse(host.fittingSize.width.isNaN, "Flanking band must not report a NaN width to the window")
    }
}
