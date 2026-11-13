import XCTest
@testable import VoiceBarUI
final class FallbackTruthTests: XCTestCase {
    func testHistoryFallbackIsAnErrorWithRawUnknownReason() {
        let facts = SettingsHistoryDiagnosticsCopy.engineFacts("parakeet-resident+fallback-future-code->whisper.cpp")
        XCTAssertEqual(facts.last?.title, "Transcription error")
        XCTAssertTrue(facts.last?.value.contains("future-code") == true)
    }
    @MainActor func testDeliveredWarningSurvivesLoadingAndDownload() throws {
        var payload = RecognizerBindingTests.event(1, desired: "parakeet", effective: "parakeet", parakeet: "loading")["recognizer_status"] as! [String: Any]
        payload["last_transcription_backend"] = "parakeet-resident+fallback-provider-error->whisper.cpp"
        let state = RecognizerPickerState(snapshot: try XCTUnwrap(RecognizerStatusSnapshot(payload: payload)))
        XCTAssertTrue(state.explanation?.contains("Whisper transcribed your last recording") == true)
        XCTAssertTrue(state.explanationIsWarning)
        var engines = payload["engines"] as! [String: Any]
        var parakeet = engines["parakeet"] as! [String: Any]
        parakeet["download"] = ["state": "downloading", "received_bytes": 1, "total_bytes": 100, "error": NSNull()] as [String: Any]
        engines["parakeet"] = parakeet; payload["engines"] = engines
        let downloading = RecognizerPickerState(snapshot: try XCTUnwrap(RecognizerStatusSnapshot(payload: payload)))
        XCTAssertEqual(downloading.explanation, state.explanation)
        // Lead review: the result of the user's own click is never hidden behind the standing warning.
        let clicked = RecognizerPickerState(snapshot: try XCTUnwrap(RecognizerStatusSnapshot(payload: payload)), notice: "Couldn't load Parakeet.")
        XCTAssertEqual(clicked.explanation, "Couldn't load Parakeet.")
        payload["last_transcription_backend"] = "parakeet-resident"
        let recovered = RecognizerPickerState(snapshot: try XCTUnwrap(RecognizerStatusSnapshot(payload: payload)))
        XCTAssertFalse(recovered.explanation?.contains("last recording") == true)
    }
}
