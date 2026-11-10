import AppKit
import OffscreenTestSupport
import SwiftUI
@testable import VoiceBarUI
import XCTest

/// X16 (Etan J4, 2026-11-10): the mute button showed a hover plate but never its tooltip, while Stop and Cancel beside
/// it did. Live bisection on the M4 (isolated UIE2E QA app, synthetic hover, 3 s) pinned it to the per-item insertion
/// transition `VoiceBarNotchWingContentEntry.transition` on the mute control alone: with it, no tooltip in 3 of 3
/// hovers; without it (everything else identical), "Mute microphone" in 3 of 3. AppKit tooltip display cannot be
/// observed offscreen (the drawn tooltip view is identical either way), so the source rule below is the regression
/// pin and the M4 screenshots are the proof.
@MainActor
final class MuteTooltipX16Tests: XCTestCase {
    private final class Router: BarCommandRouting {
        func handlePrimaryTap() {}
        func handleCancel() {}
        func handleStop() {}
        func handleReplay() {}
        func handleRetranscribeHistoryEntry(recordingPath: String) {}
    }

    private func barViewSource() throws -> String {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/VoiceBarUI/BarView.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// The body of the first `marker { ... }` block, braces matched.
    private func block(after marker: String, in source: String) throws -> String {
        let start = try XCTUnwrap(source.range(of: marker), "marker not found: \(marker)")
        var depth = 0
        var index = start.lowerBound
        var opened = false
        while index < source.endIndex {
            let character = source[index]
            if character == "{" { depth += 1; opened = true }
            if character == "}" {
                depth -= 1
                if opened && depth == 0 { return String(source[start.lowerBound ... index]) }
            }
            index = source.index(after: index)
        }
        throw XCTSkip("unbalanced block after \(marker)")
    }

    func testTheMuteControlCarriesNoInsertionTransition() throws {
        let mute = try block(after: "if let recordingPauseControl {", in: try barViewSource())
        XCTAssertTrue(mute.contains("tooltip: recordingPauseControl.tooltip"), "fixture: this is the mute control")
        XCTAssertFalse(mute.contains(".transition("),
                       "[X16 J4] an insertion transition on the mute control stops AppKit showing its tooltip (M4)")
    }

    /// The real F5 order: the optimistic press shows Stop and Cancel; the daemon's `ptt` event inserts mute later.
    /// The late mute registers its tooltip on a drawn view, in both states.
    func testTheLateInsertedMuteRegistersItsTooltip() throws {
        let state = VoiceState(recentTranscriptionsLoader: { [] }, recentTranscriptionsSaver: { _ in },
                               recentTranscriptionEntriesLoader: { [] }, recentTranscriptionEntriesSaver: { _ in },
                               playbackAmplitudeClock: { 100 }, keepsExpandedInDevState: false)
        state.sendCommand = { _ in }
        state.isConnected = true
        state.isCollapsed = false
        state.record(pressToTalk: true)
        XCTAssertNil(state.recordingMode, "fixture: the optimistic press has no mode yet")
        let host = NSHostingView(rootView: BarView(state: state, commandRouter: Router(), onOpenSettings: {},
                                                   onOpenHistory: {}))
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        let window = NSPanel(contentRect: host.frame, styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        VLOrderTestWindow(window)
        defer { window.contentView = nil; window.close() }
        func settle() { host.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.5)) }
        func tooltips() -> [String] {
            func all(_ view: NSView) -> [NSView] { view.subviews + view.subviews.flatMap(all) }
            return all(host).filter { !$0.visibleRect.isEmpty }.compactMap(\.toolTip)
        }
        settle()
        XCTAssertFalse(tooltips().contains("Mute microphone"), "no mute before the daemon confirms PTT")
        state.handleEvent(["type": "state", "state": "recording", "mode": "ptt"])
        settle()
        XCTAssertTrue(tooltips().contains("Mute microphone"), "[X16 J4] the late mute registers its tooltip")
        XCTAssertTrue(tooltips().contains("Stop recording"))
        state.setRecordingPaused(true)
        settle()
        XCTAssertTrue(tooltips().contains("Unmute microphone"), "[X16 J4] and its muted form")
    }
}
