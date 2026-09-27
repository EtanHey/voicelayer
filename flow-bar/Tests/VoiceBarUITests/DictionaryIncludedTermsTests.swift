@testable import VoiceBarUI
import XCTest

/// QA 2.2.25 C11: Settings showed "Your terms (296) · Included terms (0)" though the daemon applies its bundled
/// dictionary on every decode. The bundled rows only ever reach VoiceBar in the daemon's `vocab_list` reply, and
/// VoiceBar asked for one only after a Dictionary edit; every file reload (each final transcription) then wiped
/// them again. The rows here are synthetic: the real list lives in TS (`BUILTIN_STT_DICTIONARY_ENTRIES`) and is
/// never copied into Swift.
@MainActor
final class DictionaryIncludedTermsTests: XCTestCase {
    private let bundledRows: [[String: Any]] = [
        ["row_id": "bundled:Alpha", "source": "bundled", "canonical": "Alpha", "variants": ["alfa"]],
        ["row_id": "bundled:Beta", "source": "bundled", "canonical": "Beta", "variants": []],
        ["row_id": "bundled:Gamma", "source": "bundled", "canonical": "Gamma", "variants": ["gama"]],
    ]

    private func makeState(terms: [String]) -> VoiceState {
        VoiceState(
            recentTranscriptionsLoader: { [] },
            recentTranscriptionsSaver: { _ in },
            recentTranscriptionEntriesLoader: { [] },
            recentTranscriptionEntriesSaver: { _ in },
            transcriptionVocabularyLoader: { terms },
            transcriptionVocabularyAliasLoader: { [] }
        )
    }

    /// The Dictionary tab's own load: the off-main provider, then the display index Settings builds from it.
    private func settingsIndex(_ state: VoiceState) -> STTDictionaryDisplayIndex {
        STTDictionaryDisplayIndex(preview: state.vocabularyPreviewOffMain())
    }

    func testTheSnapshotRequestAsksTheDaemonOnlyWhileConnected() {
        let state = makeState(terms: [])
        var sent: [[String: Any]] = []
        state.sendCommand = { sent.append($0) }

        state.requestVocabularySnapshot()
        XCTAssertTrue(sent.isEmpty, "no request while there is no daemon to answer it")

        state.setConnectionStatus(true)
        state.requestVocabularySnapshot()
        XCTAssertEqual(sent.map { $0["cmd"] as? String }, ["vocab_list"])
    }

    func testTheDaemonsReplyFillsIncludedTermsAndKeepsPersonalCount() {
        let state = makeState(terms: ["Mine"])
        state.handleEvent([
            "type": "vocab_list",
            "entries": [["canonical": "Mine", "variants": []]],
            "display_entries": bundledRows + [
                ["row_id": "personal:Mine", "source": "personal", "canonical": "Mine", "variants": []],
            ],
        ])

        let index = settingsIndex(state)
        XCTAssertEqual(index.includedCount, bundledRows.count)
        XCTAssertEqual(index.personalCount, 1)
    }

    func testAFileReloadKeepsTheBundledRowsAndRebuildsPersonalFromTheFile() {
        var fileTerms = ["Mine"]
        let state = VoiceState(
            recentTranscriptionsLoader: { [] },
            recentTranscriptionsSaver: { _ in },
            recentTranscriptionEntriesLoader: { [] },
            recentTranscriptionEntriesSaver: { _ in },
            transcriptionVocabularyLoader: { fileTerms },
            transcriptionVocabularyAliasLoader: { [STTVocabularyAliasPreview(from: "yours truly", to: "Yours")] }
        )
        state.handleEvent([
            "type": "vocab_list",
            "entries": [["canonical": "Mine", "variants": []]],
            "display_entries": bundledRows + [
                ["row_id": "personal:Mine", "source": "personal", "canonical": "Mine", "variants": []],
            ],
        ])

        // A snapshot-less vocabulary event reloads from the file, the same path every final transcription takes.
        fileTerms = ["Mine", "Yours"]
        state.handleEvent(["type": "vocabulary"])

        let index = settingsIndex(state)
        XCTAssertEqual(index.includedCount, bundledRows.count, "a file reload must not drop the bundled rows")
        XCTAssertEqual(index.personalCount, 2)
        XCTAssertEqual(
            index.entries(source: "personal", matching: "").map(\.entry),
            [
                STTDictionaryEntry(canonical: "Mine", variants: []),
                STTDictionaryEntry(canonical: "Yours", variants: ["yours truly"]),
            ]
        )
        XCTAssertEqual(index.entries(source: "bundled", matching: "").map(\.rowID),
                       ["bundled:Alpha", "bundled:Beta", "bundled:Gamma"])
    }

    func testBeforeTheDaemonAnswersEveryFileEntryIsPersonal() {
        let state = makeState(terms: ["Mine", "Yours"])

        let index = settingsIndex(state)
        XCTAssertEqual(index.personalCount, 2)
        XCTAssertEqual(index.includedCount, 0)
    }
}
