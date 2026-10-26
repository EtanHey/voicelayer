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

    func testMidReadJoinDoesNotInterpolateOpeningWordIntoDecodedLeadingSilence() {
        for opening in ["At", "This", "The"] {
            let joinedDocument = "Alpha one. \(opening) two.\n\nGamma three."
            var now = 100.0
            let state = VoiceState(playbackAmplitudeClock: { now })
            state.handleEvent(["type": "state", "state": "speaking", "text": "Preparing speech…",
                               "long_read": ["id": "read-1", "chunk_index": 0, "chunk_count": 3, "chunk_start_ms": 0,
                                             "preparing": true, "text": joinedDocument, "chunk_word_starts": [0, 2, 4]]])
            play(state, chunk: 0)
            now += 1
            state.handleEvent(["type": "state", "state": "speaking", "text": "\(opening) two.",
                               "duration_ms": 3000, "playback_offset_ms": 1000,
                               "long_read": ["id": "read-1", "chunk_index": 1, "chunk_count": 3,
                                             "chunk_start_ms": 1000]],
                              playbackAmplitude: PlaybackAmplitudeEnvelope(source: .decodedRMS,
                                  sampleIntervalMilliseconds: 50,
                                  samples: Array(repeating: 0.0, count: 22) + [0.4, 0.5, 0.3]))
            // Clone alignment cannot match the opening token, but measures its neighbour.
            state.handleEvent(["type": "subtitle", "words": [], "duration_ms": 2000, "aligned_words": [
                ["word_index": 0, "text": opening, "offset_ms": NSNull(), "duration_ms": NSNull()],
                row(1, "two.", 1400),
            ]])
            XCTAssertEqual(state.teleprompterText, joinedDocument)
            XCTAssertEqual(words(state)[2].offsetMs, 2100, "opening estimate starts at decoded onset, not chunk admission")
            func highlighted() -> Int {
                TeleprompterPlaybackPolicy.currentWordIndex(in: words(state),
                                                            elapsedMilliseconds: state.playbackElapsedMilliseconds())
            }
            XCTAssertEqual(highlighted(), 1)
            now += 1.099
            XCTAssertEqual(highlighted(), 1, "the previous chunk's last word remains highlighted throughout the gap")
            now += 0.001
            XCTAssertEqual(highlighted(), 2, "the next chunk's opening word starts at its audio onset")
            now += 0.3
            XCTAssertEqual(highlighted(), 3, "measured word timing is unchanged")
            // A later seek uses a sliced envelope; it must not relocate the known opening.
            state.handleEvent(["type": "state", "state": "speaking", "text": "\(opening) two.",
                               "duration_ms": 3000, "playback_offset_ms": 2300,
                               "long_read": ["id": "read-1", "chunk_index": 1, "chunk_count": 3,
                                             "chunk_start_ms": 1000]],
                              playbackAmplitude: PlaybackAmplitudeEnvelope(source: .decodedRMS,
                                  sampleIntervalMilliseconds: 50, samples: [0.4]))
            state.handleEvent(["type": "subtitle", "words": [], "duration_ms": 2000, "aligned_words": [
                ["word_index": 0, "text": opening, "offset_ms": NSNull(), "duration_ms": NSNull()],
                row(1, "two.", 1400),
            ]])
            XCTAssertEqual(words(state)[2].offsetMs, 2100, "a sliced envelope never replaces a known onset")
        }
    }

    func testMidReadJoinWithoutDecodedOnsetDoesNotInventALeadingWordTime() {
        let state = VoiceState(playbackAmplitudeClock: { 100 })
        prepare(state)
        play(state, chunk: 0)
        play(state, chunk: 1, text: chunks[1])
        state.handleEvent(["type": "subtitle", "words": [], "duration_ms": 2000, "aligned_words": [
            ["word_index": 0, "text": "Beta", "offset_ms": NSNull(), "duration_ms": NSNull()],
            row(1, "two.", 1400),
        ]])
        XCTAssertNil(words(state)[2].offsetMs, "an unavailable onset cannot justify a leading estimate")
        XCTAssertEqual(TeleprompterPlaybackPolicy.currentWordIndex(in: words(state),
                                                                  elapsedMilliseconds: 2100), 1)
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

    // MARK: - Round 2

    private func speaking(_ state: VoiceState, _ text: String, read: String, index: Int, count: Int, start: Int,
                          offset: Int? = nil, readback: String? = "rb-1") {
        var event: [String: Any] = ["type": "state", "state": "speaking", "text": text, "duration_ms": 900_000,
                                    "playback_offset_ms": offset ?? start,
                                    "long_read": ["id": read, "chunk_index": index, "chunk_count": count,
                                                  "chunk_start_ms": start]]
        if let readback { event["readback_id"] = readback }
        state.handleEvent(event)
    }

    func testAReadOverThreeThousandWordsIsStillOneDocument() {
        let tokens = (0 ..< 4500).map { "w\($0)." }
        let text = tokens.joined(separator: " ")
        let starts = [0, 1500, 3000]
        let state = VoiceState(playbackAmplitudeClock: { 100 })
        state.handleEvent(["type": "state", "state": "speaking", "text": "Preparing speech…",
                           "long_read": ["id": "big", "chunk_index": 0, "chunk_count": 3, "chunk_start_ms": 0,
                                         "preparing": true, "text": text, "chunk_word_starts": starts]])
        let chunk = tokens[1500 ..< 3000].joined(separator: " ")
        speaking(state, chunk, read: "big", index: 1, count: 3, start: 600_000)
        state.handleEvent(["type": "subtitle", "words": [], "duration_ms": 600_000, "aligned_words": [
            row(0, "w1500.", 0), row(1, "w1501.", 400),
        ]])
        XCTAssertEqual(state.teleprompterText, text, "4,500 words never fall back to a chunk page")
        let mapped = words(state)
        guard mapped.count == 4500 else { return XCTFail("one 4,500-word document, got \(mapped.count) words") }
        XCTAssertEqual(mapped[1500].offsetMs, 600_000)
        XCTAssertEqual(TeleprompterPlaybackPolicy.currentWordIndex(in: mapped, elapsedMilliseconds: 600_450), 1501)
        var seeks: [Int] = []
        TeleprompterSeekPolicy.seek(mapped[1501], isReadback: false, seek: { seeks.append($0) })
        XCTAssertEqual(seeks, [600_400])
    }

    func testReplayOfAStoppedPrefixKeepsTheWholeDocument() {
        for stopAfter in 1 ... 2 {
            let state = VoiceState(playbackAmplitudeClock: { 100 })
            prepare(state)
            for index in 0 ..< stopAfter { play(state, chunk: index) }
            state.handleEvent(["type": "state", "state": "idle", "source": "playback"])
            XCTAssertEqual(state.teleprompterText, document)
            // The daemon replays only the retained prefix: chunk_count is the prefix length.
            speaking(state, chunks[stopAfter - 1], read: "readback-\(stopAfter)", index: stopAfter - 1,
                     count: stopAfter, start: (stopAfter - 1) * 1000)
            XCTAssertEqual(state.teleprompterText, document, "stop after \(stopAfter): the replay keeps the document")
            let offsets = words(state).map(\.offsetMs)
            XCTAssertEqual(Array(offsets.prefix(stopAfter * 2)), Array([0, 500, 1000, 1500].prefix(stopAfter * 2)))
            XCTAssertTrue(offsets.dropFirst(stopAfter * 2).allSatisfy { $0 == nil }, "unplayed words stay unseekable")
        }
    }

    func testAnEdgeChunkWithALongTokenKeepsItsMeasuredTimings() {
        let state = VoiceState(playbackAmplitudeClock: { 100 })
        let first = "Read https://example.com/some/long/path please."
        let text = first + "\n\nNext chunk."
        state.handleEvent(["type": "state", "state": "speaking", "text": "Preparing speech…",
                           "long_read": ["id": "edge", "chunk_index": 0, "chunk_count": 2, "chunk_start_ms": 0,
                                         "preparing": true, "text": text, "chunk_word_starts": [0, 3]]])
        speaking(state, first, read: "edge", index: 0, count: 2, start: 0)
        state.handleEvent(["type": "subtitle", "words": [
            ["text": "Read", "offset_ms": 0, "duration_ms": 200],
            ["text": "https://example.com/some/long/path", "offset_ms": 300, "duration_ms": 900],
            ["text": "please.", "offset_ms": 1300, "duration_ms": 300],
        ]])
        speaking(state, "Next chunk.", read: "edge", index: 1, count: 2, start: 2000)
        let mapped = words(state)
        XCTAssertEqual(mapped.map(\.text), ["Read", "https://example.com/some", "/long/path", "please.", "Next", "chunk."])
        XCTAssertEqual(mapped.map(\.offsetMs), [0, 300, 300, 1300, nil, nil], "measured, per whitespace token")
        XCTAssertFalse(mapped.contains(where: \.hasEstimatedTiming))
        var seeks: [Int] = []
        TeleprompterSeekPolicy.seek(mapped[3], isReadback: false, seek: { seeks.append($0) })
        XCTAssertEqual(seeks, [1300])
    }

    func testSequentialChunksOfOneDocumentKeepThePlaybackEpoch() {
        let state = VoiceState(playbackAmplitudeClock: { 100 })
        prepare(state)
        play(state, chunk: 0)
        let epoch = state.playbackEpoch
        play(state, chunk: 1)
        play(state, chunk: 2)
        XCTAssertEqual(state.playbackEpoch, epoch, "a chunk edge of the same document is not a restart")
        speaking(state, chunks[1], read: "read-1", index: 1, count: 3, start: 1000, offset: 1400)
        XCTAssertEqual(state.playbackEpoch, epoch + 1, "a seek still restarts on the receipt clock")
        speaking(state, chunks[0], read: "read-1", index: 0, count: 3, start: 0)
        XCTAssertEqual(state.playbackEpoch, epoch + 2, "seeking back to a chunk start restarts")
    }

    func testAParkedReadSnapshotCarriesTheDocumentAndGlobalTimeline() {
        let state = VoiceState(playbackAmplitudeClock: { 100 })
        prepare(state)
        play(state, chunk: 0)
        play(state, chunk: 1)
        let snapshot = state.longReadDocumentSnapshot()
        state.handleEvent(["type": "state", "state": "speaking", "text": "Interrupting short read.", "duration_ms": 900])
        XCTAssertEqual(state.teleprompterText, "Interrupting short read.")
        state.restoreLongReadDocument(snapshot)
        XCTAssertEqual(state.teleprompterText, document, "pause/play resumes the continuous document")
        XCTAssertEqual(words(state).map(\.offsetMs), [0, 500, 1000, 1500, nil, nil])
    }
    /// P16b × TELE1: pause a long read, dictate, and Play comes back on the whole continuous document, not on
    /// the paused chunk's text alone, with the paused word still the one on screen.
    func testPauseCaptureThenPlayRestoresTheWholeDocument() {
        let state = VoiceState(playbackAmplitudeClock: { 100 })
        state.isConnected = true
        state.frontmostAppProvider = { nil }
        var sent: [[String: Any]] = []
        state.sendCommand = { sent.append($0) }
        prepare(state)
        state.handleEvent(["type": "state", "state": "speaking", "text": chunks[1], "duration_ms": 3000,
                           "playback_offset_ms": 1000, "readback_id": "rb-1",
                           "playback_id": "chunk-1", "generation": 1,
                           "long_read": ["id": "read-1", "chunk_index": 1, "chunk_count": 3, "chunk_start_ms": 1000]])
        XCTAssertEqual(state.teleprompterText, document)
        let mapped = words(state)

        state.handleEvent(["type": "playback_state", "state": "paused", "playback_id": "chunk-1", "generation": 2,
                           "offset_ms": 1500, "chunk_offset_ms": 500])
        state.record(pressToTalk: true)
        state.handleEvent(["type": "state", "state": "recording", "bar_owned": true])
        XCTAssertEqual(state.mode, .recording)
        state.cancel()
        state.handleEvent(["type": "state", "state": "idle", "source": "recording"])
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        XCTAssertTrue(state.isPlaybackPaused, "Play is back after the capture")
        XCTAssertEqual(state.teleprompterText, document, "the whole document, not chunk 1's text")
        XCTAssertEqual(words(state).map(\.offsetMs), mapped.map(\.offsetMs), "same global timeline")
        XCTAssertEqual(TeleprompterPlaybackPolicy.currentWordIndex(
            in: words(state), elapsedMilliseconds: state.playbackElapsedMilliseconds()
        ), 3, "still on the paused word (two., chunk 1)")
        state.togglePlaybackPause()
        XCTAssertEqual(sent.last?["playback_id"] as? String, "chunk-1")
    }
}
