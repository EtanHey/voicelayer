@testable import VoiceBarUI
import XCTest

final class STTVocabularyCommandPayloadTests: XCTestCase {
    private let pr245VocabAddFixture = #"{"cmd":"vocab_add","id":"vocab-1","from":"domekin","to":"Domica"}"#
    private let pr245VocabListFixture = #"{"cmd":"vocab_list","id":"vocab-list"}"#
    private let pr245VocabRemoveFixture = #"{"cmd":"vocab_remove","id":"vocab-remove","from":"domekin"}"#

    func testVocabAddPayloadMatchesPR245ParserFixture() throws {
        let payload = STTVocabularyCommandPayload.addAlias(
            correct: "Domica",
            wrong: "domekin",
            id: "vocab-1"
        )

        try XCTAssertPayload(payload, matchesFixture: pr245VocabAddFixture)
    }

    func testVocabRemovePayloadMatchesPR245ParserFixture() throws {
        let payload = STTVocabularyCommandPayload.removeAlias(
            STTVocabularyAliasPreview(from: "domekin", to: "Domica"),
            id: "vocab-remove"
        )

        try XCTAssertPayload(payload, matchesFixture: pr245VocabRemoveFixture)
    }

    func testListPayloadMatchesPR245ParserFixture() throws {
        let payload = STTVocabularyCommandPayload.list(id: "vocab-list")

        try XCTAssertPayload(payload, matchesFixture: pr245VocabListFixture)
    }

    private let termAddFixture = #"{"cmd":"vocab_add_term","id":"term-1","term":"VoiceLayer"}"#
    private let termRemoveFixture = #"{"cmd":"vocab_remove_term","id":"term-2","term":"VoiceLayer"}"#

    func testVocabAddTermPayloadMatchesParserFixture() throws {
        let payload = STTVocabularyCommandPayload.addTerm("VoiceLayer", id: "term-1")

        try XCTAssertPayload(payload, matchesFixture: termAddFixture)
    }

    func testVocabRemoveTermPayloadMatchesParserFixture() throws {
        let payload = STTVocabularyCommandPayload.removeTerm(" VoiceLayer ", id: "term-2")

        try XCTAssertPayload(payload, matchesFixture: termRemoveFixture)
    }

    func testVoiceStateSendsTermAddThenRefreshList() {
        let state = VoiceState()
        var commands: [[String: Any]] = []
        state.sendCommand = { command in
            commands.append(command)
        }

        state.addVocabularyPromptTerm("SongScript")

        XCTAssertEqual(commands.count, 2)
        XCTAssertEqual(commands[0]["cmd"] as? String, "vocab_add_term")
        XCTAssertEqual(commands[0]["term"] as? String, "SongScript")
        XCTAssertEqual(commands[1]["cmd"] as? String, "vocab_list")
    }

    func testVoiceStateIgnoresEmptyTermAdd() {
        let state = VoiceState()
        var commands: [[String: Any]] = []
        state.sendCommand = { command in
            commands.append(command)
        }

        state.addVocabularyPromptTerm("   ")

        XCTAssertTrue(commands.isEmpty)
    }

    func testVoiceStateSendsTermRemoveThenRefreshList() {
        let state = VoiceState()
        var commands: [[String: Any]] = []
        state.sendCommand = { command in
            commands.append(command)
        }

        state.removeVocabularyPromptTerm("SongScript")

        XCTAssertEqual(commands.count, 2)
        XCTAssertEqual(commands[0]["cmd"] as? String, "vocab_remove_term")
        XCTAssertEqual(commands[0]["term"] as? String, "SongScript")
        XCTAssertEqual(commands[1]["cmd"] as? String, "vocab_list")
    }

    func testVoiceStateSendsVocabularyAddThenRefreshList() {
        let state = VoiceState()
        var commands: [[String: Any]] = []
        state.sendCommand = { command in
            commands.append(command)
        }

        state.addVocabularyAlias(
            correct: "VoiceLayer",
            wrong: "voice lair"
        )

        XCTAssertEqual(commands.count, 2)
        XCTAssertEqual(commands[0]["cmd"] as? String, "vocab_add")
        XCTAssertEqual(commands[0]["from"] as? String, "voice lair")
        XCTAssertEqual(commands[0]["to"] as? String, "VoiceLayer")
        XCTAssertNil(commands[0]["also_prompt_term"])
        XCTAssertEqual(commands[1]["cmd"] as? String, "vocab_list")
    }

    private func XCTAssertPayload(
        _ payload: [String: Any],
        matchesFixture fixture: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let fixtureObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(fixture.utf8)) as? [String: Any],
            file: file,
            line: line
        )
        XCTAssertEqual(
            try canonicalJSONString(payload),
            try canonicalJSONString(fixtureObject),
            file: file,
            line: line
        )
    }

    private func canonicalJSONString(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return try XCTUnwrap(String(data: data, encoding: .utf8))
    }
}
