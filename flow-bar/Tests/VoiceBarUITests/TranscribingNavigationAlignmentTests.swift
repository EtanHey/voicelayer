import AppKit
import OffscreenTestSupport
import SwiftUI
import Vision

@testable import VoiceBarUI
import XCTest

@MainActor final class TranscribingNavigationAlignmentTests: XCTestCase {
    private final class Router: BarCommandRouting {
        func handlePrimaryTap() {}; func handleCancel() {}; func handleStop() {}; func handleReplay() {}
        func handleRetranscribeHistoryEntry(recordingPath: String) {}
    }
    func testIdleAndTranscribingNavigationFramesAreIdentical() throws {
        let state = VoiceState(recentTranscriptionsLoader: { [] }, recentTranscriptionsSaver: { _ in },
            recentTranscriptionEntriesLoader: { [] }, recentTranscriptionEntriesSaver: { _ in },
            transcriptionVocabularyLoader: { [] }, transcriptionVocabularyAliasLoader: { [] }, keepsExpandedInDevState: false)
        state.isConnected = true; state.isHovering = true
        let host = NSHostingView(rootView: BarView(state: state, commandRouter: Router(), onOpenSettings: {},
            onOpenHistory: {}, includesPanelOutsets: true).frame(width: 700, height: 500))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 700, height: 500), styleMask: .borderless,
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; VLOrderTestWindow(window)
        defer { window.contentView = nil; window.close() }
        func settle() { host.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.5)); host.layoutSubtreeIfNeeded() }
        func frames(_ view: NSView) -> [String: CGRect] {
            var found: [String: CGRect] = [:]
            if let tooltip = view.toolTip { found[tooltip] = view.convert(view.bounds, to: host) }
            for child in view.subviews { found.merge(frames(child)) { first, _ in first } }
            return found
        }
        settle(); let idle = frames(host)
        state.mode = .transcribing; settle(); let transcribing = frames(host)
        for tooltip in ["History", "Settings", "Choose microphone"] {
            let before = try XCTUnwrap(idle[tooltip], "idle tooltips: \(idle.keys)")
            let after = try XCTUnwrap(transcribing[tooltip], "transcribing tooltips: \(transcribing.keys)")
            XCTAssertEqual(after, before, "\(tooltip) must stay in the launcher's exact slot")
        }
    }
}
