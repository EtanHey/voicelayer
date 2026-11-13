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
        for lines in [3, 8] {
            let (state, host, window) = mount(lines: lines)
            defer { window.contentView = nil; window.close() }
            state.handleEvent(["type": "state", "state": "idle", "source": "playback"])
            settle(host)
            XCTAssertTrue(state.isTeleprompterReadback)

            let viewport = try XCTUnwrap(scrollViews(in: host).max { $0.frame.height < $1.frame.height },
                                         "the stopped read keeps its scrolling text view")
            // The 2.4 text fills the shell above its scrubber and controls, just as main's stopped read does.
            let expected = TeleprompterA.stoppedBodyHeight(lines: lines)
            XCTAssertEqual(viewport.frame.height, expected, accuracy: 0.5,
                           "the stopped text uses the body the reader had, not a 78 pt strip")
            if lines == 8 { XCTAssertGreaterThan(viewport.frame.height, 78) }
            let eye = try XCTUnwrap(tooltipViews(in: host).first { $0.toolTip == "Hide teleprompter" })
            let textFrame = viewport.convert(viewport.bounds, to: host)
            let eyeFrame = eye.convert(eye.bounds, to: host)
            let gap = host.isFlipped ? eyeFrame.minY - textFrame.maxY : textFrame.minY - eyeFrame.maxY
            print("STOPPED_READ lines=\(lines) viewport=\(viewport.frame.height) textToControls=\(gap)")
            if let path = ProcessInfo.processInfo.environment["VOICEBAR_STOPPED_SHOTS_DIR"], !path.isEmpty {
                let directory = URL(fileURLWithPath: path, isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                    .write(to: directory.appendingPathComponent("stopped-\(lines)-lines.png"))
            }
            XCTAssertEqual(gap, TeleprompterA.scrubberGap + TeleprompterA.scrubberHeight + TeleprompterA.controlsGap,
                           accuracy: 1, "only the scrubber and its designed gaps separate text from controls; no blank band")
        }
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

    private func tooltipViews(in view: NSView) -> [PillControlTooltip.TooltipView] {
        ((view as? PillControlTooltip.TooltipView).map { [$0] } ?? []) + view.subviews.flatMap(tooltipViews)
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
