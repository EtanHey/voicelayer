import AppKit
import OffscreenTestSupport
import SwiftUI
@testable import VoiceBarUI
import XCTest

@MainActor final class RecordingReservationTests: XCTestCase {
    private final class Router: BarCommandRouting {
        func handlePrimaryTap() {}
        func handleCancel() {}
        func handleStop() {}
        func handleReplay() {}
        func handleRetranscribeHistoryEntry(recordingPath: String) {}
    }
    func testLateTakeTypeAndEarlierSpinnerKeepStopAndCancelFrames() throws {
        let state = VoiceState(recentTranscriptionsLoader: { [] }, recentTranscriptionsSaver: { _ in },
            recentTranscriptionEntriesLoader: { [] }, recentTranscriptionEntriesSaver: { _ in },
            transcriptionVocabularyLoader: { [] }, transcriptionVocabularyAliasLoader: { [] }, keepsExpandedInDevState: false)
        state.sendCommand = { _ in }; state.isConnected = true; state.isCollapsed = false
        state.mode = .recording
        let host = NSHostingView(rootView: BarView(state: state, commandRouter: Router(), onOpenSettings: {},
            onOpenHistory: {}, includesPanelOutsets: true).frame(width: 700, height: 500))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 700, height: 500), styleMask: .borderless,
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; VLOrderTestWindow(window)
        defer { window.contentView = nil; window.close() }
        func settle() { host.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.4)); host.layoutSubtreeIfNeeded() }
        func frame(_ tooltip: String, _ view: NSView) -> CGRect? {
            if view.toolTip == tooltip { return view.convert(view.bounds, to: host) }
            return view.subviews.lazy.compactMap { frame(tooltip, $0) }.first
        }
        settle()
        let stop = try XCTUnwrap(frame("Stop recording", host)); let cancel = try XCTUnwrap(frame("Cancel recording", host))
        state.recordingMode = "ptt"; settle()
        XCTAssertEqual(try XCTUnwrap(frame("Stop recording", host)), stop, "late PTT must not move Stop")
        XCTAssertEqual(try XCTUnwrap(frame("Cancel recording", host)), cancel, "late PTT must not move Cancel")
        state.setRecordingPaused(true); settle()
        XCTAssertEqual(try XCTUnwrap(frame("Stop recording", host)), stop)
        XCTAssertEqual(try XCTUnwrap(frame("Cancel recording", host)), cancel)
        // VAD type is supplied in the state event before recording is published. Lock selection and an earlier
        // take may arrive later; neither changes these controls' positions.
        state.mode = .idle; state.recordingMode = "vad"; state.mode = .recording; settle()
        let vadStop = try XCTUnwrap(frame("Stop recording", host)); let vadCancel = try XCTUnwrap(frame("Cancel recording", host))
        state.setRecordingHold(true); settle()
        XCTAssertEqual(try XCTUnwrap(frame("Stop recording", host)), vadStop)
        XCTAssertEqual(try XCTUnwrap(frame("Cancel recording", host)), vadCancel)
        state.handleEvent(["type": "state", "state": "recording", "mode": "vad", "mic_take_id": "B",
            "recording_jobs": [["take_id": "A", "kind": "live", "phase": "processing"],
                               ["take_id": "B", "kind": "live", "phase": "capturing"]]]); settle()
        XCTAssertEqual(state.processingTakeCount, 1, "the earlier spinner actually arrived")
        XCTAssertEqual(try XCTUnwrap(frame("Stop recording", host)), vadStop)
        XCTAssertEqual(try XCTUnwrap(frame("Cancel recording", host)), vadCancel)
    }
}
