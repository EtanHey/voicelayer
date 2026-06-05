@testable import VoiceBarUI
import XCTest

final class STTVocabularyCommandPayloadTests: XCTestCase {
    func testVocabAddUsesWrongAsFromAndCorrectAsTo() {
        let payload = STTVocabularyCommandPayload.addAlias(
            correct: "VoiceLayer",
            wrong: "voice lair",
            alsoPromptTerm: true
        )

        XCTAssertEqual(payload["cmd"] as? String, "vocab_add")
        XCTAssertEqual(payload["from"] as? String, "voice lair")
        XCTAssertEqual(payload["to"] as? String, "VoiceLayer")
        XCTAssertEqual(payload["also_prompt_term"] as? Bool, true)
    }

    func testVocabRemoveUsesSamePairShapeAsAdd() {
        let payload = STTVocabularyCommandPayload.removeAlias(
            STTVocabularyAliasPreview(from: "work claude", to: "orcClaude")
        )

        XCTAssertEqual(payload["cmd"] as? String, "vocab_remove")
        XCTAssertEqual(payload["from"] as? String, "work claude")
        XCTAssertEqual(payload["to"] as? String, "orcClaude")
    }

    func testPromptTermAdditionUsesPromptTermCommandKind() {
        let payload = STTVocabularyCommandPayload.addPromptTerm("SongScript")

        XCTAssertEqual(payload["cmd"] as? String, "vocab_add")
        XCTAssertEqual(payload["term"] as? String, "SongScript")
        XCTAssertEqual(payload["kind"] as? String, "prompt_term")
    }

    func testListPayloadRequestsFreshVocabularySnapshot() {
        XCTAssertEqual(STTVocabularyCommandPayload.list()["cmd"] as? String, "vocab_list")
    }

    func testVoiceStateSendsVocabularyAddThenRefreshList() {
        let state = VoiceState()
        var commands: [[String: Any]] = []
        state.sendCommand = { command in
            commands.append(command)
        }

        state.addVocabularyAlias(
            correct: "VoiceLayer",
            wrong: "voice lair",
            alsoPromptTerm: true
        )

        XCTAssertEqual(commands.count, 2)
        XCTAssertEqual(commands[0]["cmd"] as? String, "vocab_add")
        XCTAssertEqual(commands[0]["from"] as? String, "voice lair")
        XCTAssertEqual(commands[0]["to"] as? String, "VoiceLayer")
        XCTAssertEqual(commands[1]["cmd"] as? String, "vocab_list")
    }
}
