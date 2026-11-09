import AppKit
@testable import VoiceBarUI
import XCTest

/// 2.3 N1 (Etan, QA round 1, S2-F3): while recording, the wings show which microphone is capturing and a live
/// elapsed time. Presentation only: the name is the CoreAudio default input that sox opens, read once when capture
/// actually opens (review D1: the daemon's first audio frame, `captureLive`), never at the optimistic press; the
/// clock starts at 0:00 on that edge. Nothing here starts, stops or routes capture.
@MainActor
final class RecordingWingLabelTests: XCTestCase {
    private var now: TimeInterval = 100
    private func state() -> VoiceState {
        let state = VoiceState(recentTranscriptionsLoader: { [] }, recentTranscriptionsSaver: { _ in },
                               recentTranscriptionEntriesLoader: { [] }, recentTranscriptionEntriesSaver: { _ in },
                               playbackAmplitudeClock: { [unowned self] in now }, keepsExpandedInDevState: false)
        state.isConnected = true
        state.sendCommand = { _ in }
        return state
    }
    private func resolve(_ mode: VoiceMode, hold: Bool = false) -> VoiceBarNotchPresentation {
        VoiceBarPresentation.notchPresentation(from: .init(mode: mode, showsRecordingHold: hold, statusText: "Recording"))
    }
    /// The daemon's real order: its `recording` state event as the recorder starts, then the first audio frame.
    private func daemonRecording(_ state: VoiceState) { state.handleEvent(["type": "state", "state": "recording", "mode": "ptt"]) }
    private func openCapture(_ state: VoiceState) { state.handleEvent(["type": "audio_level", "rms": 0.2]) }

    /// Review D1: an F5 press flips `.recording` optimistically, up to ~1.3 s before the recorder's first frame.
    /// Until capture opens there is no time and no microphone; the default input may change before it opens.
    func testNothingShowsBeforeCaptureOpensAndTheClockStartsAtZeroOnOpen() {
        let state = state()
        var defaultInput = "Mic A"
        var reads = 0
        state.recordingMicrophoneNameProvider = { reads += 1; return defaultInput }

        state.record(pressToTalk: true)
        XCTAssertEqual(state.mode, .recording, "the optimistic press")
        XCTAssertFalse(state.captureLive)
        now = 102 // a slow recorder start
        XCTAssertFalse(state.isRecordingCaptureOpen)
        XCTAssertEqual(state.recordingElapsedMilliseconds(), 0, "no elapsed time before capture opens")
        XCTAssertNil(state.recordingMicrophoneName, "no microphone before capture opens")
        XCTAssertEqual(reads, 0)

        defaultInput = "Mic B" // the default changes before the recorder opens
        daemonRecording(state)
        XCTAssertFalse(state.isRecordingCaptureOpen, "the recording event alone is not the first frame")
        XCTAssertNil(state.recordingMicrophoneName)
        openCapture(state)
        XCTAssertTrue(state.captureLive)
        XCTAssertTrue(state.isRecordingCaptureOpen)
        XCTAssertEqual(state.recordingElapsedMilliseconds(), 0, "0:00 on open")
        XCTAssertEqual(state.recordingMicrophoneName, "Mic B", "the device that opened")
        now = 105.4
        XCTAssertEqual(state.recordingElapsedMilliseconds(), 3_400)
        XCTAssertEqual(VoiceBarReadingTimeLabel.text(elapsedMilliseconds: state.recordingElapsedMilliseconds()), "0:03")

        // Later frames and the daemon's repeated recording event neither restart the clock nor reread the name.
        defaultInput = "Mic C"
        openCapture(state)
        state.handleEvent(["type": "state", "state": "recording", "mode": "ptt"])
        now = 110
        XCTAssertEqual(state.recordingElapsedMilliseconds(), 8_000, "still counted from the open at 102")
        XCTAssertEqual(state.recordingMicrophoneName, "Mic B")
        XCTAssertEqual(reads, 1)

        state.mode = .transcribing
        XCTAssertFalse(state.isRecordingCaptureOpen)
        XCTAssertNil(state.recordingMicrophoneName)
        XCTAssertEqual(state.recordingElapsedMilliseconds(), 0)
    }

    func testTheNextTakeRereadsTheMicrophoneOnItsOwnOpen() {
        let state = state()
        var names = ["MacBook Pro Microphone", "AirPods Pro"]
        state.recordingMicrophoneNameProvider = { names.removeFirst() }
        state.record(pressToTalk: true)
        daemonRecording(state)
        openCapture(state)
        XCTAssertEqual(state.recordingMicrophoneName, "MacBook Pro Microphone")
        state.handleEvent(["type": "state", "state": "idle", "source": "recording"])
        XCTAssertNil(state.recordingMicrophoneName)
        now = 200
        state.record(pressToTalk: true)
        XCTAssertEqual(state.mode, .recording)
        XCTAssertNil(state.recordingMicrophoneName, "the next take shows nothing until it opens")
        now = 201
        XCTAssertEqual(state.recordingElapsedMilliseconds(), 0)
        daemonRecording(state)
        openCapture(state)
        XCTAssertEqual(state.recordingMicrophoneName, "AirPods Pro")
        now = 203.2
        XCTAssertEqual(state.recordingElapsedMilliseconds(), 2_200)
    }

    func testAnUnreadableMicrophoneLeavesTheTimeAlone() {
        let state = state()
        state.recordingMicrophoneNameProvider = { "   " }
        state.record(pressToTalk: true)
        daemonRecording(state)
        openCapture(state)
        XCTAssertNil(state.recordingMicrophoneName, "a blank name is no name")
        XCTAssertTrue(state.isRecordingCaptureOpen)
    }

    /// Review D3 on a flat display (no glass-hidden inset): the time on the notch side and an empty region outside
    /// the meter keep the meter's centre within 2 pt of the wing's whether or not the time shows; the wing never
    /// changes width when it appears. RecordingWingNotchClearanceTests covers the M4's hidden inset.
    func testTheMeterStaysCentredInTheRecordingWingWithAndWithoutTheLabels() {
        let inset = VoiceBarNotchContract.fixedWingContentInset
        let timeGap = VoiceBarRecordingWingLabel.timeGap, gap = VoiceBarRecordingWingLabel.meterGap
        for hold in [false, true] {
            let wing = resolve(.recording, hold: hold).geometry.trailingWingWidth
            XCTAssertEqual(wing, 2 * inset + VoiceBarRecordingWingLabel.width + timeGap + gap + WaveformLayout.viewportWidth +
                           VoiceBarRecordingWingLabel.outerRegionWidth, accuracy: 0.001)
            XCTAssertEqual(wing, VoiceBarNotchContract.recordingTrailingWingWidth, accuracy: 0.001)
            XCTAssertEqual(wing, 120, accuracy: 0.001)
            XCTAssertLessThanOrEqual(wing, VoiceBarNotchContract.morphCanvasWingCapacity)
            // The production HStack order: time region, meter, empty outer region, from the wing's inner edge.
            let meterCentre = inset + VoiceBarRecordingWingLabel.width + timeGap + WaveformLayout.viewportWidth / 2
            XCTAssertEqual(meterCentre, wing / 2, accuracy: 2, "the meter is centred whatever the time shows")
            XCTAssertEqual(resolve(.recording, hold: hold).geometry.leadingWingWidth, hold
                ? VoiceBarNotchContract.recordingLeadingWingWidthWithHoldControl
                : VoiceBarNotchContract.fixedWingWidth, accuracy: 0.001)
        }
        XCTAssertEqual(resolve(.transcribing).geometry.trailingWingWidth, VoiceBarNotchContract.fixedWingWidth, accuracy: 0.001)
    }

    func testBarViewLaysTheTimeBeforeTheMeterAndAnEmptyRegionAfterIt() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/VoiceBarUI/BarView.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        let trailing = try XCTUnwrap(source.components(separatedBy: "private var notchTrailingContent").dropFirst().first)
            .components(separatedBy: "private var notchCompactStatusContent")[0]
        let recording = try XCTUnwrap(trailing.components(separatedBy: "case .recording:").dropFirst().first)
            .components(separatedBy: "case .compactStatus")[0]
        XCTAssertTrue(recording.contains("VoiceBarRecordingTrailingRow {"), "0510 N10: one row lays out time, meter, outer")
        let time = try XCTUnwrap(recording.range(of: "VoiceBarRecordingTimeRegion(")).lowerBound
        let meter = try XCTUnwrap(recording.range(of: "notchWaveform")).lowerBound
        XCTAssertLessThan(time, meter)
        let controls = try String(contentsOf: url.deletingLastPathComponent().appendingPathComponent("VoiceBarWingControls.swift"),
                                  encoding: .utf8)
        let row = try XCTUnwrap(controls.components(separatedBy: "struct VoiceBarRecordingTrailingRow").dropFirst().first)
            .components(separatedBy: "public struct VoiceBarRecordingTimeRegion")[0]
        let rowMeter = try XCTUnwrap(row.range(of: "            meter\n")).lowerBound
        let outer = try XCTUnwrap(row.range(of: "VoiceBarRecordingWingLabel.outerRegionWidth")).lowerBound
        XCTAssertLessThan(try XCTUnwrap(row.range(of: "            time\n")).lowerBound, rowMeter)
        XCTAssertLessThan(rowMeter, outer)
        XCTAssertTrue(recording.contains("isCaptureOpen: state.isRecordingCaptureOpen"))
        XCTAssertTrue(recording.contains("state.recordingMicrophoneName"))
    }
}
