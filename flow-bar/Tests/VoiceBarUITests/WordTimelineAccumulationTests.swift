import XCTest
@testable import VoiceBarUI

/// WORDTIME1: a read keeps every chunk's timings, and sparse clone tokens become clickable estimates.
@MainActor
final class WordTimelineAccumulationTests: XCTestCase {
    private func row(_ index: Int, _ text: String, _ offset: Any = NSNull(), _ duration: Any = NSNull()) -> [String: Any] {
        ["word_index": index, "text": text, "offset_ms": offset, "duration_ms": duration]
    }

    private func speak(_ state: VoiceState, _ text: String, read: String? = "read-1", chunkStart: Int = 0, duration: Int = 5000) {
        var event: [String: Any] = ["type": "state", "state": "speaking", "text": text,
                                    "duration_ms": duration, "playback_offset_ms": chunkStart]
        if let read { event["long_read"] = ["id": read, "chunk_start_ms": chunkStart] }
        state.handleEvent(event)
    }

    private func words(_ state: VoiceState) -> [TeleprompterWord] {
        TeleprompterContentModel.words(text: state.statusText, wordBoundaries: state.wordBoundaries)
    }

    func testNullTokensInterpolateBetweenTimedNeighboursAndBecomeClickable() {
        let state = VoiceState(playbackAmplitudeClock: { 100 })
        speak(state, "BLOCKED-2: the attempt didn't work either.", read: nil, duration: 3000)
        state.handleEvent(["type": "subtitle", "words": [], "duration_ms": 3000, "aligned_words": [
            row(0, "BLOCKED-2:"), row(1, "the"), row(2, "attempt", 600, 400), row(3, "didn't"),
            row(4, "work", 1400, 300), row(5, "either."),
        ]])
        let mapped = words(state)
        XCTAssertTrue(mapped.allSatisfy { $0.offsetMs != nil }, "every displayed word is highlightable")
        XCTAssertEqual(mapped.map(\.hasInterpolatedTiming), [true, true, false, true, false, true])
        XCTAssertEqual(mapped.map(\.offsetMs), [0, 300, 600, 1000, 1400, 1700])
        let offsets = mapped.compactMap(\.offsetMs)
        XCTAssertEqual(offsets, offsets.sorted(), "interpolation never reorders")
        XCTAssertTrue(mapped.allSatisfy { ($0.offsetMs ?? 0) + ($0.durationMs ?? 0) <= 3000 }, "never past the audio")
        var seeks: [Int] = []
        for word in mapped { TeleprompterSeekPolicy.seek(word, isReadback: false, seek: { seeks.append($0) }) }
        XCTAssertEqual(seeks, offsets, "interpolated words are seek targets")
        XCTAssertEqual(TeleprompterPlaybackPolicy.currentWordIndex(in: mapped, elapsedMilliseconds: 1100), 3)
    }

    func testInterpolationStaysInsideTheChunkAndLeavesNoRoomUntimed() {
        let state = VoiceState(playbackAmplitudeClock: { 100 })
        speak(state, "lead timed tail", chunkStart: 10000)
        state.handleEvent(["type": "subtitle", "words": [], "duration_ms": 900,
                           "aligned_words": [row(0, "lead"), row(1, "timed", 400, 500), row(2, "tail")]])
        XCTAssertEqual(words(state).map(\.offsetMs), [10000, 10400, nil],
                       "a chunk whose audio ends with its last timed word invents nothing after it")
        speak(state, "unknown end", chunkStart: 20000)
        state.handleEvent(["type": "subtitle", "words": [], "aligned_words": [row(0, "unknown", 0, 100), row(1, "end")]])
        XCTAssertEqual(words(state).map(\.offsetMs), [20000, nil], "no chunk length, no trailing estimate")
    }

    func testLaterChunksAppendAndAnUntimedChunkNeverErasesEarlierOnes() {
        let state = VoiceState(playbackAmplitudeClock: { 100 })
        speak(state, "first chunk")
        state.handleEvent(["type": "subtitle", "words": [], "duration_ms": 1000,
                           "aligned_words": [row(0, "first", 0, 300), row(1, "chunk", 400, 300)]])
        speak(state, "second chunk", chunkStart: 1000)
        state.handleEvent(["type": "subtitle", "words": [["text": "second", "offset_ms": 0, "duration_ms": 200],
                                                          ["text": "chunk", "offset_ms": 300, "duration_ms": 200]]])
        speak(state, "third chunk", chunkStart: 2000)
        state.handleEvent(["type": "subtitle", "words": [], "aligned_words": [row(0, "third"), row(1, "chunk")]])
        speak(state, "fourth chunk", chunkStart: 3000)
        state.handleEvent(["type": "subtitle", "words": [], "aligned_words": [row(0, "wrong", 0, 100)]])
        XCTAssertEqual(state.playbackWordTimeline.map(\.text), ["first", "chunk", "second", "chunk"])
        XCTAssertEqual(state.playbackWordTimeline.map(\.offsetMs), [0, 400, 1000, 1300], "offsets shift per chunk")

        speak(state, "first chunk", chunkStart: 0)
        XCTAssertEqual(words(state).map(\.offsetMs), [0, 400], "seeking back restores the chunk without a fresh subtitle")
        speak(state, "other read", read: "read-2")
        XCTAssertTrue(state.playbackWordTimeline.isEmpty, "a new read starts its own timeline")
    }
}
