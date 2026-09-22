@testable import VoiceBarUI
import XCTest

final class STTVocabularyPreviewSearchTests: XCTestCase {
    func testFilteredAliasesMatchesWrongOrRightSideCaseInsensitively() {
        let preview = STTVocabularyPreview(
            updatedAt: nil,
            promptTerms: ["VoiceLayer", "Wispr Flow"],
            aliases: [
                STTVocabularyAliasPreview(from: "work claude", to: "orcClaude"),
                STTVocabularyAliasPreview(from: "voice lair", to: "VoiceLayer"),
            ]
        )

        XCTAssertEqual(
            preview.filteredAliases(matching: "VOICE").map(\.from),
            ["voice lair"]
        )
        XCTAssertEqual(
            preview.filteredAliases(matching: "orc").map(\.to),
            ["orcClaude"]
        )
    }

    func testDictionaryDraftTrimsFieldsBeforeBuildingCommand() throws {
        let draft = STTVocabularyDraft(
            correct: "  VoiceLayer ",
            wrong: " voice lair "
        )

        let payload = try XCTUnwrap(draft.addAliasPayload())

        XCTAssertEqual(payload["from"] as? String, "voice lair")
        XCTAssertEqual(payload["to"] as? String, "VoiceLayer")
        XCTAssertNil(payload["also_prompt_term"])
    }

    func testDictionaryDraftRefusesEmptyMisheardVariant() {
        let draft = STTVocabularyDraft(correct: "VoiceLayer", wrong: " ")

        XCTAssertNil(draft.addAliasPayload())
    }

    func testLargeDictionaryPageIsBoundedWithoutDroppingSearchableEntries() {
        let count = 4096
        let preview = STTVocabularyPreview(
            updatedAt: nil,
            promptTerms: (0 ..< count).map { "Term \($0)" },
            aliases: (0 ..< count).map {
                STTVocabularyAliasPreview(from: "Variant \($0)", to: "Term \($0)")
            }
        )

        let index = STTDictionaryIndex(entries: preview.entries)
        let firstPage = index.page(matching: "", limit: 100)
        XCTAssertEqual(firstPage.entries.count, 100)
        XCTAssertEqual(firstPage.totalMatchCount, count)
        XCTAssertTrue(firstPage.hasMore)

        let completePage = index.page(matching: "", limit: count)
        XCTAssertEqual(completePage.entries.count, count)
        XCTAssertFalse(completePage.hasMore)
        XCTAssertEqual(Set(completePage.entries.map(\.canonical)).count, count)

        let tailSearch = index.page(matching: "Variant 4095", limit: 100)
        XCTAssertEqual(tailSearch.entries.map(\.canonical), ["Term 4095"])
    }

    func testIndexedMergePreservesFirstCanonicalAndVariantSemantics() {
        let preview = STTVocabularyPreview(
            updatedAt: nil,
            promptTerms: [" VoiceLayer ", "voicelayer", "La La"],
            aliases: [
                STTVocabularyAliasPreview(from: "voice lair", to: "VOICELAYER"),
                STTVocabularyAliasPreview(from: "Voice-Lair", to: "VoiceLayer"),
                STTVocabularyAliasPreview(from: "la-la", to: "La La"),
            ]
        )

        XCTAssertEqual(
            preview.entries,
            [
                STTDictionaryEntry(canonical: "VoiceLayer", variants: ["voice lair"]),
                STTDictionaryEntry(canonical: "La La", variants: []),
            ]
        )
    }

    func testIndexedMergePreservesLegacyWidthInsensitiveCanonicalCollision() {
        let preview = STTVocabularyPreview(
            updatedAt: nil,
            promptTerms: ["Ａlpha", "Alpha"],
            aliases: [
                STTVocabularyAliasPreview(from: "wide alpha", to: "Ａlpha"),
                STTVocabularyAliasPreview(from: "plain alpha", to: "Alpha"),
            ]
        )

        XCTAssertEqual(
            preview.entries,
            [
                STTDictionaryEntry(
                    canonical: "Ａlpha",
                    variants: ["wide alpha", "plain alpha"]
                ),
            ]
        )
    }
}
