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
            wrong: " voice lair ",
            alsoPromptTerm: true
        )

        let payload = try XCTUnwrap(draft.addAliasPayload())

        XCTAssertEqual(payload["from"] as? String, "voice lair")
        XCTAssertEqual(payload["to"] as? String, "VoiceLayer")
        XCTAssertEqual(payload["also_prompt_term"] as? Bool, true)
    }

    func testDictionaryDraftRefusesEmptyMisheardVariant() {
        let draft = STTVocabularyDraft(correct: "VoiceLayer", wrong: " ", alsoPromptTerm: false)

        XCTAssertNil(draft.addAliasPayload())
    }
}
