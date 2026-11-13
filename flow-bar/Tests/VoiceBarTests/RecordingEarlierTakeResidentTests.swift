import Foundation
@testable import VoiceBar
@testable import VoiceBarUI
import XCTest

/// N1 review D2 (#810): the earlier take's spinner slot (26 pt) must leave the RESIDENT presentation when that take
/// completes, is cancelled away or fails while the new take keeps recording. Those changes arrive as job snapshots
/// with no mode edge, so VoiceState posts its layout-change callback, which the app wires to
/// `AppDelegate.refreshNotchPresentationModel` exactly as here.
@MainActor
final class RecordingEarlierTakeResidentTests: XCTestCase {
    private func recording(_ jobs: [[String: Any]]) -> [String: Any] {
        ["type": "state", "state": "recording", "source": "recording", "mic_take_id": "B",
         "recording_jobs": jobs + [["take_id": "B", "kind": "live", "phase": "capturing"]]]
    }

    func testTheSpinnerSlotCollapsesInTheResidentModelAfterCompletionCancelOrFailure() {
        let fixed = VoiceBarNotchContract.fixedWingWidth
        let recordingWidth = VoiceBarNotchContract.recordingTrailingWingWidth
        let slot = VoiceBarNotchContract.material.compactControlSpacing + VoiceBarNotchContract.material.compactControlSize
        let terminal: [(String, [[String: Any]])] = [
            ("completion", []),
            ("cancellation", []),
            ("failure", [["take_id": "A", "kind": "live", "phase": "failed"]]),
        ]
        for (name, after) in terminal {
            let state = VoiceState(recentTranscriptionsLoader: { [] }, recentTranscriptionsSaver: { _ in },
                                   recentTranscriptionEntriesLoader: { [] }, recentTranscriptionEntriesSaver: { _ in },
                                   keepsExpandedInDevState: false)
            state.isConnected = true
            state.isCollapsed = false
            state.sendCommand = { _ in }
            let model = VoiceBarNotchPresentationModel()
            var callbacks = 0
            state.onPanelLayoutChange = { callbacks += 1; AppDelegate.refreshNotchPresentationModel(model, for: state) }

            state.handleEvent(recording([["take_id": "A", "kind": "live", "phase": "processing"]]))
            AppDelegate.refreshNotchPresentationModel(model, for: state) // the mode edge's own refresh
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            XCTAssertEqual(state.mode, .recording, name)
            // C7-W: the time/meter wing (102 pt) is wider than Stop + Cancel + spinner (99.5 pt), so it sets the band;
            // the spinner slot still fits and the hit rects make room for it.
            XCTAssertEqual(model.presentation.geometry.leadingWingWidth, max(fixed + slot, recordingWidth), accuracy: 0.001,
                           "\(name): A transcribing while B records has room for the spinner slot")
            XCTAssertTrue(VoiceBarPresentation.showsEarlierTakeProcessing(for: state), "\(name): the spinner shows")

            callbacks = 0
            if name == "cancellation" { state.handleEvent(recording([["take_id": "A", "kind": "live", "phase": "processing"]])) }
            state.handleEvent(recording(after))
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            XCTAssertEqual(state.mode, .recording, "\(name): B is still recording")
            XCTAssertGreaterThanOrEqual(callbacks, 1, "\(name): the layout change reaches the resident model")
            XCTAssertEqual(model.presentation.geometry.leadingWingWidth - recordingWidth, 0, accuracy: 0.001,
                           "\(name): no resident empty slot")
            XCTAssertFalse(VoiceBarPresentation.showsEarlierTakeProcessing(for: state), name)
        }
    }
}
