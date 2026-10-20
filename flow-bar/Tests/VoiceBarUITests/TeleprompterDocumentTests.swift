import SwiftUI
import XCTest
@testable import VoiceBarUI

/// TELE1: a long read is one continuous teleprompter document; chunk boundaries are audio-only.
@MainActor
final class TeleprompterDocumentTests: XCTestCase {
    private let chunks = ["Alpha one.", "Beta two.", "Gamma three."]
    private let document = "Alpha one. Beta two.\n\nGamma three."

    private func row(_ index: Int, _ text: String, _ offset: Int, _ duration: Int = 300) -> [String: Any] {
        ["word_index": index, "text": text, "offset_ms": offset, "duration_ms": duration]
    }

    private func prepare(_ state: VoiceState, read: String = "read-1") {
        state.handleEvent(["type": "state", "state": "speaking", "text": "Preparing speech…",
                           "long_read": ["id": read, "chunk_index": 0, "chunk_count": 3, "chunk_start_ms": 0,
                                         "preparing": true, "text": document, "chunk_word_starts": [0, 2, 4]]])
    }

    private func play(_ state: VoiceState, chunk index: Int, read: String = "read-1", readback: String? = "rb-1",
                      text: String? = nil) {
        let start = index * 1000
        var event: [String: Any] = ["type": "state", "state": "speaking", "text": text ?? chunks[index],
                                    "duration_ms": 3000, "playback_offset_ms": start,
                                    "long_read": ["id": read, "chunk_index": index, "chunk_count": 3,
                                                  "chunk_start_ms": start]]
        if let readback { event["readback_id"] = readback }
        state.handleEvent(event)
        guard text == nil else { return }
        let tokens = chunks[index].split(separator: " ").map(String.init)
        state.handleEvent(["type": "subtitle", "words": [], "duration_ms": 1000, "aligned_words": [
            row(0, tokens[0], 0), row(1, tokens[1], 500),
        ]])
    }

    private func words(_ state: VoiceState) -> [TeleprompterWord] {
        TeleprompterContentModel.words(text: state.teleprompterText ?? "",
                                       wordBoundaries: state.teleprompterWordBoundaries)
    }

    func testThreeChunkLongReadRendersOneDocumentAndTheHighlightCrossesChunkBoundaries() {
        let state = VoiceState(playbackAmplitudeClock: { 100 })
        prepare(state)
        XCTAssertEqual(state.teleprompterText, "Preparing speech…", "Preparing looks exactly as today")

        play(state, chunk: 0)
        XCTAssertEqual(state.teleprompterText, document, "the first chunk already shows the whole read")
        let identity = TeleprompterScrollPolicy.contentIdentity(for: state.teleprompterText ?? "")
        play(state, chunk: 1)
        play(state, chunk: 2)
        XCTAssertEqual(state.teleprompterText, document, "a chunk edge never swaps the page")
        XCTAssertEqual(TeleprompterScrollPolicy.contentIdentity(for: state.teleprompterText ?? ""), identity,
                       "the scroll view keeps its identity, so it never jumps")
        XCTAssertEqual(state.statusText, chunks[2], "the spoken chunk text is untouched")

        let mapped = words(state)
        XCTAssertEqual(mapped.map(\.text), ["Alpha", "one.", "Beta", "two.", "Gamma", "three."])
        XCTAssertEqual(mapped.map(\.offsetMs), [0, 500, 1000, 1500, 2000, 2500], "global offsets across chunks")
        XCTAssertEqual(TeleprompterPlaybackPolicy.currentWordIndex(in: mapped, elapsedMilliseconds: 900), 1)
        XCTAssertEqual(TeleprompterPlaybackPolicy.currentWordIndex(in: mapped, elapsedMilliseconds: 1100), 2,
                       "the highlight crosses from chunk 0 into chunk 1")
        XCTAssertEqual(TeleprompterPlaybackPolicy.currentWordIndex(in: mapped, elapsedMilliseconds: 2600), 5)
        var seeks: [Int] = []
        TeleprompterSeekPolicy.seek(mapped[1], isReadback: false, seek: { seeks.append($0) })
        TeleprompterSeekPolicy.seek(mapped[4], isReadback: false, seek: { seeks.append($0) })
        XCTAssertEqual(seeks, [500, 2000], "every word seeks on the global timeline")

        play(state, chunk: 0, text: "Alpha one.")
        XCTAssertEqual(words(state).map(\.offsetMs), [0, 500, 1000, 1500, 2000, 2500],
                       "seeking back keeps every chunk's timing on the page")

        state.handleEvent(["type": "state", "state": "idle", "source": "playback"])
        XCTAssertTrue(state.isTeleprompterReadback)
        XCTAssertEqual(state.teleprompterText, document, "readback retains the whole document")
        XCTAssertEqual(words(state).compactMap(\.offsetMs).count, 6)

        play(state, chunk: 1, read: "readback-1", text: "Beta two.")
        XCTAssertEqual(state.teleprompterText, document, "a readback replay of the same read keeps the document")
        XCTAssertEqual(words(state).map(\.offsetMs), [0, 500, 1000, 1500, 2000, 2500])
    }

    func testAChunkThatIsNotTheDocumentsFallsBackToTheChunkText() {
        let state = VoiceState(playbackAmplitudeClock: { 100 })
        prepare(state)
        play(state, chunk: 1, text: "Something else entirely.")
        XCTAssertEqual(state.teleprompterText, "Something else entirely.", "fail closed to today's page")
        play(state, chunk: 0, read: "read-2", readback: "rb-2")
        XCTAssertEqual(state.teleprompterText, chunks[0], "another read never borrows this document")
    }

    func testShortReadIsUnchanged() {
        let state = VoiceState(playbackAmplitudeClock: { 100 })
        state.handleEvent(["type": "state", "state": "speaking", "text": "Short read.", "duration_ms": 900])
        XCTAssertEqual(state.teleprompterText, "Short read.")
    }
}
