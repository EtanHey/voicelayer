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

    /// Review D3: the time and the microphone sit in equal regions either side of the meter, so the meter's centre is
    /// the wing's centre (within 2 pt) whether or not they show; the wing never changes width when they appear.
    func testTheMeterStaysCentredInTheRecordingWingWithAndWithoutTheLabels() {
        let material = VoiceBarNotchContract.material
        let inset = VoiceBarNotchContract.fixedWingContentInset
        let region = VoiceBarRecordingWingLabel.width
        let spacing = material.compactControlSpacing
        for hold in [false, true] {
            let wing = resolve(.recording, hold: hold).geometry.trailingWingWidth
            XCTAssertEqual(wing, 2 * inset + 2 * (region + spacing) + WaveformLayout.viewportWidth, accuracy: 0.001)
            XCTAssertEqual(wing, VoiceBarNotchContract.recordingTrailingWingWidth, accuracy: 0.001)
            XCTAssertLessThanOrEqual(wing, 132)
            XCTAssertLessThanOrEqual(wing, VoiceBarNotchContract.morphCanvasWingCapacity)
            // The production HStack order: time region, meter, microphone region, from the wing's inner edge.
            let meterMinX = inset + region + spacing
            let meterCentre = meterMinX + WaveformLayout.viewportWidth / 2
            XCTAssertEqual(meterCentre, wing / 2, accuracy: 2, "the meter is centred whatever the regions show")
            XCTAssertEqual(resolve(.recording, hold: hold).geometry.leadingWingWidth, hold
                ? VoiceBarNotchContract.recordingLeadingWingWidthWithHoldControl
                : VoiceBarNotchContract.fixedWingWidth, accuracy: 0.001)
        }
        for time in ["0:00", "9:59", "10m", "99h"] {
            XCTAssertLessThanOrEqual(ceil((time as NSString).size(withAttributes: [.font: VoiceBarRecordingWingLabel.timeFont]).width),
                                     region, "\(time) fits its region")
        }
        XCTAssertEqual(resolve(.transcribing).geometry.trailingWingWidth, VoiceBarNotchContract.fixedWingWidth, accuracy: 0.001)
    }

    func testBarViewLaysTheRegionsOutSymmetricallyAroundTheMeter() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/VoiceBarUI/BarView.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        let trailing = try XCTUnwrap(source.components(separatedBy: "private var notchTrailingContent").dropFirst().first)
            .components(separatedBy: "private var notchCompactStatusContent")[0]
        let recording = try XCTUnwrap(trailing.components(separatedBy: "case .recording:").dropFirst().first)
            .components(separatedBy: "case .compactStatus")[0]
        let time = try XCTUnwrap(recording.range(of: "VoiceBarRecordingTimeRegion(")).lowerBound
        let meter = try XCTUnwrap(recording.range(of: "notchWaveform")).lowerBound
        let microphone = try XCTUnwrap(recording.range(of: "VoiceBarRecordingMicrophoneRegion(")).lowerBound
        XCTAssertLessThan(time, meter)
        XCTAssertLessThan(meter, microphone)
        XCTAssertTrue(recording.contains("isCaptureOpen: state.isRecordingCaptureOpen"))
        XCTAssertTrue(recording.contains("state.recordingMicrophoneName"))
    }
}
