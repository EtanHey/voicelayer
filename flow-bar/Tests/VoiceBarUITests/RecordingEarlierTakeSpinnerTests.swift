@testable import VoiceBarUI
import XCTest

/// Queued-recording QA F1: make an earlier take's pending transcription visible beside the current capture.
/// Show its spinner left of Stop, beside the
/// recording controls, never instead of them. Presentation only: it reads the daemon's job snapshot.
@MainActor
final class RecordingEarlierTakeSpinnerTests: XCTestCase {
    private func resolve(earlier: Bool, hold: Bool = false, mode: VoiceMode = .recording) -> VoiceBarNotchPresentation {
        VoiceBarPresentation.notchPresentation(from: .init(mode: mode, showsRecordingHold: hold, statusText: "Recording",
                                                           showsEarlierTakeProcessing: earlier))
    }

    func testTheLeftWingGainsOneOuterSlotForTheSpinner() {
        let slot = VoiceBarNotchContract.material.compactControlSpacing + VoiceBarNotchContract.material.compactControlSize
        XCTAssertEqual(resolve(earlier: false).geometry.leadingWingWidth, VoiceBarNotchContract.recordingTrailingWingWidth, accuracy: 0.001)
        // C7-W: Stop + Cancel + spinner (99.5 pt) is narrower than the time/meter wing (102 pt), which then sets both.
        XCTAssertEqual(resolve(earlier: true).geometry.leadingWingWidth,
                       max(VoiceBarNotchContract.fixedWingWidth + slot, VoiceBarNotchContract.recordingTrailingWingWidth), accuracy: 0.001)
        let both = resolve(earlier: true, hold: true).geometry
        XCTAssertEqual(both.leadingWingWidth, VoiceBarNotchContract.recordingLeadingWingWidthWithHoldControl + slot, accuracy: 0.001)
        XCTAssertLessThanOrEqual(both.leadingWingWidth, 132)
        XCTAssertLessThanOrEqual(both.leadingWingWidth, VoiceBarNotchContract.morphCanvasWingCapacity)
        // The paired recording wings grow together; other states are untouched.
        XCTAssertEqual(resolve(earlier: true).geometry.trailingWingWidth, resolve(earlier: true).geometry.leadingWingWidth)
        XCTAssertEqual(resolve(earlier: true, mode: .transcribing).geometry, resolve(earlier: false, mode: .transcribing).geometry)
    }

    func testTheSpinnerFollowsTheDaemonJobSnapshotWhileRecording() {
        let state = VoiceState(recentTranscriptionsLoader: { [] }, recentTranscriptionsSaver: { _ in },
                               recentTranscriptionEntriesLoader: { [] }, recentTranscriptionEntriesSaver: { _ in },
                               keepsExpandedInDevState: false)
        state.isConnected = true
        state.sendCommand = { _ in }
        XCTAssertFalse(VoiceBarPresentation.showsEarlierTakeProcessing(for: state))
        // Take A transcribes while take B records (the clip's 7.9-15.5 s window).
        state.handleEvent(["type": "state", "state": "recording", "source": "recording", "mic_take_id": "B",
                           "recording_jobs": [["take_id": "A", "kind": "live", "phase": "processing"],
                                              ["take_id": "B", "kind": "live", "phase": "capturing"]]])
        XCTAssertEqual(state.mode, .recording)
        XCTAssertTrue(VoiceBarPresentation.showsEarlierTakeProcessing(for: state))
        // A delivers: still pending until its text lands.
        state.handleEvent(["type": "state", "state": "recording", "source": "recording", "mic_take_id": "B",
                           "recording_jobs": [["take_id": "A", "kind": "live", "phase": "delivering"],
                                              ["take_id": "B", "kind": "live", "phase": "capturing"]]])
        XCTAssertTrue(VoiceBarPresentation.showsEarlierTakeProcessing(for: state))
        // A is done; B alone records: the recording controls only.
        state.handleEvent(["type": "state", "state": "recording", "source": "recording", "mic_take_id": "B",
                           "recording_jobs": [["take_id": "B", "kind": "live", "phase": "capturing"]]])
        XCTAssertEqual(state.mode, .recording)
        XCTAssertFalse(VoiceBarPresentation.showsEarlierTakeProcessing(for: state))
    }

    func testBarViewDrawsTheSpinnerBeforeStopInTheRecordingWing() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/VoiceBarUI/BarView.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        let leading = try XCTUnwrap(source.components(separatedBy: "private var notchLeadingContent").dropFirst().first)
            .components(separatedBy: "case .compactStatus, .teleprompter:")[0]
        let recording = try XCTUnwrap(leading.components(separatedBy: "case .recording:").dropFirst().first)
        let spinner = try XCTUnwrap(recording.range(of: "ProcessingSpinner()")).lowerBound
        let stop = try XCTUnwrap(recording.range(of: "icon: \"stop.fill\"")).lowerBound
        XCTAssertLessThan(spinner, stop, "the spinner sits left of the red Stop")
        XCTAssertTrue(recording.contains("showsEarlierTakeProcessing"))
    }
}
