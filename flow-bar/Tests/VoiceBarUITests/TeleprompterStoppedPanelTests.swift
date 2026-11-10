import AppKit
import OffscreenTestSupport
import SwiftUI
@testable import VoiceBarUI
import XCTest

/// T2 (QA 2026-11-08, VoiceBar 2.3.0 @ 870b1617): the stopped teleprompter cut its text through a line while most
/// of the tall panel below the timeline sat empty, with Replay/X at its bottom (S4-F2, S4-F3).
@MainActor
final class TeleprompterStoppedPanelTests: XCTestCase {
    private final class Router: BarCommandRouting {
        func handlePrimaryTap() {}
        func handleCancel() {}
        func handleStop() {}
        func handleReplay() {}
        func handleRetranscribeHistoryEntry(recordingPath _: String) {}
    }

    private let longText = Array(repeating: "Not released yet, and the final update-gate bug that blocked your dictation is still open.",
                                 count: 6).joined(separator: " ")

    private func mount(lines: Int) -> (VoiceState, NSHostingView<AnyView>, NSPanel) {
        let state = VoiceState(
            recentTranscriptionsLoader: { [] }, recentTranscriptionsSaver: { _ in },
            recentTranscriptionEntriesLoader: { [] }, recentTranscriptionEntriesSaver: { _ in },
            playbackAmplitudeClock: { 100 }, keepsExpandedInDevState: false
        )
        state.sendCommand = { _ in }
        state.isConnected = true
        state.isCollapsed = false
        state.handleEvent(["type": "state", "state": "speaking", "text": longText, "duration_ms": 40000,
                           "request_id": "t2-read", "playback_id": "t2-player", "generation": 1])
        state.teleprompterVisibleLines = lines
        let presentation = VoiceBarNotchPresentationModel()
        presentation.updateOperationalEnvelope(hasTeleprompter: true, isRecording: false, hasCompactStatus: false,
                                               teleprompterLeadingWingWidth: VoiceBarPresentation.readingTransportWingWidth)
        presentation.setTeleprompterLines(lines)
        let host = NSHostingView(rootView: AnyView(
            BarView(state: state, commandRouter: Router(), onOpenSettings: {}, onOpenHistory: {},
                    presentationModel: presentation, includesPanelOutsets: true)
                .environment(\.colorScheme, .dark)
                .environment(\.visualRenderTime, 0)))
        host.frame = CGRect(origin: .zero, size: host.fittingSize)
        host.appearance = NSAppearance(named: .darkAqua) // matches the dark colour scheme, so frames are legible
        let window = NSPanel(contentRect: host.frame, styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        VLOrderCompositorTestWindow(window)
        settle(host)
        return (state, host, window)
    }

    func testTheStoppedReadFillsTheReadingBodyInsteadOfClippingAboveABlankBand() throws {
        let (state, host, window) = mount(lines: 8)
        defer { window.contentView = nil; window.close() }
        state.handleEvent(["type": "state", "state": "idle", "source": "playback"])
        settle(host)
        XCTAssertTrue(state.isTeleprompterReadback)

        let viewport = try XCTUnwrap(scrollViews(in: host).max { $0.frame.height < $1.frame.height },
                                     "the stopped read keeps its scrolling text view")
        // T3: the stopped text takes the whole reading stack above its scrubber.
        let expected = Theme.teleprompterViewportHeight
        XCTAssertEqual(viewport.frame.height, expected, accuracy: 0.5,
                       "the stopped text uses the body the reader had, not a 78 pt strip")
        XCTAssertEqual(expected, 78, "2.4 retains its fixed readback viewport below the transport wing")
    }

    /// T2 (S2-F8): every teleprompter control carries the notch's native tooltip, the scrubber included.
    func testTheScrubberRegistersTheNativeNotchTooltip() throws {
        let (_, host, window) = mount(lines: 3)
        defer { window.contentView = nil; window.close() }
        let tips = tooltips(in: host)
        XCTAssertTrue(tips.contains { $0.hasPrefix("Drag to seek") }, "found \(tips)")
        for label in ["Replay", "Hide teleprompter", "Stop speaking"] {
            XCTAssertTrue(tips.contains(label), "\(label): found \(tips)")
        }
    }

    private func tooltips(in view: NSView) -> [String] {
        ((view as? PillControlTooltip.TooltipView)?.toolTip.map { [$0] } ?? []) + view.subviews.flatMap(tooltips)
    }

    private func scrollViews(in view: NSView) -> [NSScrollView] {
        ((view as? NSScrollView).map { [$0] } ?? []) + view.subviews.flatMap(scrollViews)
    }

    private func settle(_ host: NSView) {
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.7))
        host.layoutSubtreeIfNeeded()
    }
}
