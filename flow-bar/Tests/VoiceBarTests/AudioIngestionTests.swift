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
}
