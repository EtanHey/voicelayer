import SwiftUI
@testable import VoiceBarUI
import XCTest

/// U5 guards for the VoiceState side: one word table per utterance, playback-only word seeks.
@MainActor
final class TeleprompterAWiringTests: XCTestCase {
    private func words(_ utterance: String, offset: Int, _ rows: [(String, Int, Int)]) -> [String: Any] {
        ["type": "speech_words", "utteranceId": utterance, "wordOffset": offset, "approximate": false,
         "words": rows.map { ["text": $0.0, "startMs": $0.1, "endMs": $0.2] }]
    }

    private func speaking(_ state: VoiceState, utterance: String?, text: String, generation: Int = 1) {
        var event: [String: Any] = ["type": "state", "state": "speaking", "text": text, "duration_ms": 4000,
                                    "playback_id": "p-\(utterance ?? "legacy")", "generation": generation]
        if let utterance { event["utteranceId"] = utterance }
        state.handleEvent(event)
    }

    func testVoiceStateKeepsOneTablePerUtteranceAndReplacesItOnQueueAdvance() {
        let state = VoiceState()
        speaking(state, utterance: "u1", text: "Hello world")
        state.handleEvent(words("u1", offset: 0, [("Hello", 100, 300), ("world", 600, 850)]))
        speaking(state, utterance: "u1", text: "Hello world", generation: 2)
        XCTAssertEqual(state.speechWords?.words.count, 2, "a chunk or seek of the same utterance keeps its table")
        state.handleEvent(words("u9", offset: 0, [("Stale", 0, 10)]))
        XCTAssertEqual(state.speechWords?.words.count, 2)
        speaking(state, utterance: "u2", text: "Next read")
        XCTAssertEqual(state.speechWords, SpeechWordTable(utteranceID: "u2"))
        speaking(state, utterance: nil, text: "Legacy daemon")
        XCTAssertNil(state.speechWords)
    }

    func testWordClickSendsAPlaybackOnlySeekForItsOwnUtterance() {
        let state = VoiceState()
        state.isConnected = true
        var sent: [[String: Any]] = []
        state.sendCommand = { sent.append($0) }
        speaking(state, utterance: "u1", text: "Hello world")
        // C4 F3: a word not timed yet waits for its timing (the daemon refuses untimed words); once timed, it sends.
        state.handleEvent(words("u1", offset: 0, [("Hello", 100, 300), ("world", 600, 850)]))
        state.seekSpeechWord(utteranceID: "u1", wordIndex: 1)
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent.first?["cmd"] as? String, "speech_seek")
        XCTAssertEqual(sent.first?["utteranceId"] as? String, "u1")
        XCTAssertEqual(sent.first?["wordIndex"] as? Int, 1)
        XCTAssertNotNil(sent.first?["id"] as? String)
        XCTAssertEqual(Set(sent.first!.keys), ["cmd", "utteranceId", "wordIndex", "id"])
        state.seekSpeechWord(utteranceID: "u0", wordIndex: 1)
        state.seekSpeechWord(utteranceID: "u1", wordIndex: -1)
        XCTAssertEqual(sent.count, 1, "a stale utterance or a bad index sends nothing")
    }

    func testNoWordSeekWhilePaused() {
        let state = VoiceState()
        state.isConnected = true
        var sent: [[String: Any]] = []
        state.sendCommand = { sent.append($0) }
        speaking(state, utterance: "u1", text: "Hello world")
        state.handleEvent(["type": "playback_state", "state": "paused", "playback_id": "p-u1", "generation": 2,
                           "offset_ms": 300, "chunk_offset_ms": 300, "duration_ms": 4000])
        XCTAssertTrue(state.isPlaybackPaused)
        state.seekSpeechWord(utteranceID: "u1", wordIndex: 1)
        XCTAssertTrue(sent.isEmpty)
    }
}
