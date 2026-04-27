@testable import VoiceBar
import XCTest

final class AudioIngestionTests: XCTestCase {
    func testZeroRMSHangPrevention() async throws {
        let vad = SileroVAD(threshold: 0.5, minSpeechDuration: 0.1)
        let virtualMic = VirtualAudioEngine(mockFile: "zero_rms.wav")
        let pipeline = DictationPipeline(audioSource: virtualMic, vad: vad)

        do {
            try await pipeline.startListening(timeout: 2.0)
            XCTFail("Pipeline should have thrown silenceTimeout")
        } catch DictationError.silenceTimeout {
            XCTAssertTrue(true)
        }
    }

    func testListeningModeRejectsHighNoise() async throws {
        let virtualMic = VirtualAudioEngine(mockFile: "high_noise.wav")
        let gate = ListeningNoiseGate()

        let result = try await gate.waitForSpeechCandidate(from: virtualMic, timeout: 0.5)

        XCTAssertFalse(result.didTriggerRecording)
    }

    func testListeningModeAcceptsCleanSpeech() async throws {
        let virtualMic = VirtualAudioEngine(mockFile: "clean_speech.wav")
        let gate = ListeningNoiseGate(expectedTranscript: "Run the tests and commit the changes")

        let result = try await gate.waitForSpeechCandidate(from: virtualMic, timeout: 0.5)

        XCTAssertTrue(result.didTriggerRecording)
        XCTAssertLessThanOrEqual(result.timeToFirstSpeech, 0.5)
        XCTAssertEqual(result.transcription, "Run the tests and commit the changes")
    }
}

private struct ListeningGateResult {
    let didTriggerRecording: Bool
    let timeToFirstSpeech: TimeInterval
    let transcription: String?
}

private struct ListeningNoiseGate {
    private let floor = Float(WaveformMetrics.listeningSilenceFloor)
    private let expectedTranscript: String?

    init(expectedTranscript: String? = nil) {
        self.expectedTranscript = expectedTranscript
    }

    func waitForSpeechCandidate(
        from audioSource: AudioStreamable,
        timeout: TimeInterval
    ) async throws -> ListeningGateResult {
        var elapsed: TimeInterval = 0

        for try await buffer in audioSource.audioStream() {
            try Task.checkCancellation()
            if buffer.peakAmplitude >= floor {
                return ListeningGateResult(
                    didTriggerRecording: true,
                    timeToFirstSpeech: elapsed,
                    transcription: expectedTranscript
                )
            }

            elapsed += buffer.duration
            if elapsed >= timeout {
                break
            }
        }

        return ListeningGateResult(
            didTriggerRecording: false,
            timeToFirstSpeech: elapsed,
            transcription: nil
        )
    }
}
