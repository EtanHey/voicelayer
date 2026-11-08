import AppKit
@testable import VoiceBarUI
import XCTest

/// 2.3 N1 (Etan, QA round 1, S2-F3): while recording, the wings show which microphone is capturing and a live
/// elapsed time. Presentation only: the name is the CoreAudio default input that sox opens, read once as the
/// recording starts; the clock is the panel's own uptime clock. Nothing here starts, stops or routes capture.
@MainActor
final class RecordingWingLabelTests: XCTestCase {
    private var now: TimeInterval = 100
    private func state() -> VoiceState {
        VoiceState(recentTranscriptionsLoader: { [] }, recentTranscriptionsSaver: { _ in },
                   recentTranscriptionEntriesLoader: { [] }, recentTranscriptionEntriesSaver: { _ in },
                   playbackAmplitudeClock: { [unowned self] in now }, keepsExpandedInDevState: false)
    }
    private func resolve(_ mode: VoiceMode, hold: Bool = false) -> VoiceBarNotchPresentation {
        VoiceBarPresentation.notchPresentation(from: .init(mode: mode, showsRecordingHold: hold, statusText: "Recording"))
    }

    func testARecordingStampsItsStartAndMicrophoneOnceAndClearsThemAfter() {
        let state = state()
        var names = ["MacBook Pro Microphone", "AirPods Pro"]
        var reads = 0
        state.recordingMicrophoneNameProvider = { reads += 1; return names.removeFirst() }
        XCTAssertNil(state.recordingMicrophoneName)
        XCTAssertEqual(state.recordingElapsedMilliseconds(), 0)

        state.mode = .recording
        XCTAssertEqual(state.recordingMicrophoneName, "MacBook Pro Microphone")
        XCTAssertEqual(state.recordingElapsedMilliseconds(), 0)
        now = 107.4
        XCTAssertEqual(state.recordingElapsedMilliseconds(), 7_400)
        // The daemon's authoritative `recording` event for the same take neither restarts the clock nor rereads.
        state.handleEvent(["type": "state", "state": "recording"])
        now = 112
        XCTAssertEqual(state.recordingElapsedMilliseconds(), 12_000)
        XCTAssertEqual(reads, 1)

        state.mode = .transcribing
        XCTAssertNil(state.recordingMicrophoneName)
        XCTAssertEqual(state.recordingElapsedMilliseconds(), 0)

        // The next take reads the microphone again (the default input may have changed) and restarts at 0:00.
        now = 200
        state.mode = .recording
        XCTAssertEqual(state.recordingMicrophoneName, "AirPods Pro")
        now = 203.2
        XCTAssertEqual(state.recordingElapsedMilliseconds(), 3_200)
        XCTAssertEqual(VoiceBarReadingTimeLabel.text(elapsedMilliseconds: state.recordingElapsedMilliseconds()), "0:03")
    }

    func testAnUnreadableMicrophoneLeavesTheTimeAlone() {
        let state = state()
        state.recordingMicrophoneNameProvider = { "   " }
        state.mode = .recording
        XCTAssertNil(state.recordingMicrophoneName, "a blank name is no name")
    }

    /// The right wing hugs the time-over-microphone column and the 46 pt meter; the left wing keeps its controls at
    /// the fixed width. Both stay inside the 132 pt wing bound and the morph canvas.
    func testTheRecordingRightWingHugsTheLabelAndTheMeter() {
        let material = VoiceBarNotchContract.material
        let expected = 2 * VoiceBarNotchContract.fixedWingContentInset + VoiceBarRecordingWingLabel.width +
            material.compactControlSpacing + WaveformLayout.viewportWidth
        for hold in [false, true] {
            let p = resolve(.recording, hold: hold)
            XCTAssertEqual(p.visualState, .recording)
            XCTAssertEqual(p.geometry.trailingWingWidth, expected, accuracy: 0.001)
            XCTAssertLessThanOrEqual(p.geometry.trailingWingWidth, 132)
            XCTAssertLessThanOrEqual(p.geometry.trailingWingWidth, VoiceBarNotchContract.morphCanvasWingCapacity)
            XCTAssertEqual(p.geometry.leadingWingWidth, hold
                ? VoiceBarNotchContract.recordingLeadingWingWidthWithHoldControl
                : VoiceBarNotchContract.fixedWingWidth, accuracy: 0.001)
        }
        XCTAssertGreaterThanOrEqual(VoiceBarRecordingWingLabel.width,
            ceil(("0:00" as NSString).size(withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)]).width))
        // Other states keep the fixed right wing.
        XCTAssertEqual(resolve(.transcribing).geometry.trailingWingWidth, VoiceBarNotchContract.fixedWingWidth, accuracy: 0.001)
    }

    func testBarViewDrawsTheLabelBesideTheMeterInTheRecordingWing() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/VoiceBarUI/BarView.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        let trailing = try XCTUnwrap(source.components(separatedBy: "private var notchTrailingContent").dropFirst().first)
            .components(separatedBy: "private var notchCompactStatusContent")[0]
        let recording = try XCTUnwrap(trailing.components(separatedBy: "case .recording:").dropFirst().first)
            .components(separatedBy: "case .compactStatus")[0]
        let label = try XCTUnwrap(recording.range(of: "VoiceBarRecordingWingLabel(")).lowerBound
        let meter = try XCTUnwrap(recording.range(of: "notchWaveform")).lowerBound
        XCTAssertLessThan(label, meter, "time and microphone sit on the notch side, the meter at the outer edge")
        XCTAssertTrue(recording.contains("state.recordingElapsedMilliseconds()"))
        XCTAssertTrue(recording.contains("state.recordingMicrophoneName"))
    }
}
