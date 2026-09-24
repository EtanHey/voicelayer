@testable import VoiceBarUI
import XCTest

/// D1-c / fold-3 review S1: the Dictionary's detached load read VoiceState through `DispatchQueue.main.sync`,
/// which deadlocks as soon as main waits synchronously on that load. The off-main read must never need main.
final class VocabularyPreviewOffMainTests: XCTestCase {
    func testOffMainReadCompletesWhileTheMainThreadIsBlocked() {
        let state = VoiceState()
        state.transcriptionVocabularyTerms = ["VoiceLayer"]
        state.transcriptionVocabularyAliases = [STTVocabularyAliasPreview(from: "voice later", to: "VoiceLayer")]

        let done = DispatchSemaphore(value: 0)
        var preview: STTVocabularyPreview?
        DispatchQueue.global(qos: .userInitiated).async {
            preview = state.vocabularyPreviewOffMain()
            done.signal()
        }
        // Main waits synchronously, exactly the case a main.sync hop deadlocks on.
        let finished = done.wait(timeout: .now() + 1) == .success

        XCTAssertTrue(finished, "the off-main vocabulary read must not wait for the main thread")
        guard finished else {
            // Let the stuck main.sync block run so the test process can end.
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            return
        }
        XCTAssertEqual(preview?.entries, [STTDictionaryEntry(canonical: "VoiceLayer", variants: ["voice later"])])
    }

    func testOffMainReadSeesTheLatestValuesSetOnMain() {
        let state = VoiceState()
        state.transcriptionVocabularyTerms = ["A"]
        state.transcriptionVocabularyTerms = ["A", "B"]

        let read = expectation(description: "background read")
        var terms: [String] = []
        DispatchQueue.global().async {
            terms = state.vocabularyPreviewOffMain().entries.map(\.canonical)
            read.fulfill()
        }
        wait(for: [read], timeout: 2)
        XCTAssertEqual(terms, ["A", "B"])
    }
}
