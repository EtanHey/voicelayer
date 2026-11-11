import AppKit
import SwiftUI
@testable import VoiceBarUI
import XCTest

/// C7 L3 follow-ups from the Cursor pre-review (c7/cursor/C4.md): F1, F3, F4, F6, F7; and Sol R900 P2.
@MainActor
final class ReadingFollowupsL3Tests: XCTestCase {
    private var now: TimeInterval = 1_000
    private var sent: [[String: Any]] = []
    private var seeks: [[String: Any]] { sent.filter { $0["cmd"] as? String == "speech_seek" } }

    private func readingState(timedWords: Int?) throws -> VoiceState {
        let fixture = try XCTUnwrap(try JSONSerialization.jsonObject(
            with: Data(TeleprompterSeekTargetsL3Tests.payload.utf8)) as? [String: Any])
        let state = VoiceState(recentTranscriptionsLoader: { [] }, recentTranscriptionsSaver: { _ in },
                               recentTranscriptionEntriesLoader: { [] }, recentTranscriptionEntriesSaver: { _ in },
                               playbackAmplitudeClock: { [unowned self] in now })
        state.isConnected = true
        state.isCollapsed = false
        state.sendCommand = { [unowned self] in sent.append($0) }
        state.handleEvent(["type": "state", "state": "speaking", "text": fixture["text"] as Any, "duration_ms": 39_000,
                           "playback_id": "v09", "generation": 1, "utteranceId": "u-v09",
                           "long_read": ["id": "u-v09", "chunk_index": 0, "chunk_count": 1, "chunk_start_ms": 0,
                                         "display": fixture["display"] as Any]])
        if let timedWords { state.handleEvent(try words(from: 0, count: timedWords)) }
        return state
    }

    private func words(from offset: Int, count: Int? = nil) throws -> [String: Any] {
        let fixture = try XCTUnwrap(try JSONSerialization.jsonObject(
            with: Data(TeleprompterSeekTargetsL3Tests.payload.utf8)) as? [String: Any])
        var event = try XCTUnwrap(fixture["words"] as? [String: Any])
        let rows = try XCTUnwrap(event["words"] as? [[String: Any]]).dropFirst(offset)
        event["wordOffset"] = offset
        event["words"] = Array(count.map { rows.prefix($0) } ?? rows)
        return event
    }

    private func model(_ state: VoiceState) throws -> TeleprompterAModel {
        TeleprompterAModelCache().model(text: try XCTUnwrap(state.teleprompterText),
            boundaries: state.teleprompterWordBoundaries, blocks: state.teleprompterDisplayBlocks,
            complete: state.teleprompterHasCompleteDisplay, column: TeleprompterA.columnWidth)
    }

    // MARK: F1: a pending seek never fires late

    func testATimingThatArrivesAfterTheWindowNeverMovesTheVoice() throws {
        let state = try readingState(timedWords: 25)
        state.seekSpeechWord(utteranceID: "u-v09", wordIndex: 26) // "Copy", not timed yet
        XCTAssertEqual(state.pendingSpeechSeekWordIndex, 26, "drawn as waiting")
        now += VoiceState.pendingSpeechSeekWindow + 0.5 // the next chunk takes longer than the window
        state.handleEvent(try words(from: 25))
        XCTAssertTrue(seeks.isEmpty, "a late timing is dropped: the voice never jumps seconds after the click")
        XCTAssertNil(state.pendingSpeechSeekWordIndex)
    }

    func testATimingInsideTheWindowSeeksTheClickedWordOnce() throws {
        let state = try readingState(timedWords: 25)
        state.seekSpeechWord(utteranceID: "u-v09", wordIndex: 26)
        now += VoiceState.pendingSpeechSeekWindow - 0.2
        state.handleEvent(try words(from: 25))
        XCTAssertEqual(seeks.count, 1)
        XCTAssertEqual(seeks.first?["wordIndex"] as? Int, 26)
        XCTAssertNil(state.pendingSpeechSeekWordIndex)
    }

    // MARK: R900 P2: a newer explicit navigation supersedes a queued word click

    /// Sol R900 P2: click untimed word 26, scrub, then the word's timing lands inside the window. The scrub is the
    /// newer intent; the queued click must never drag the voice back to word 26.
    func testANewerScrubCancelsAQueuedWordClick() throws {
        let state = try readingState(timedWords: 25)
        state.seekSpeechWord(utteranceID: "u-v09", wordIndex: 26)
        now += 0.2
        state.seek(offsetMs: 1_000)
        let scrubAt = try XCTUnwrap(sent.lastIndex { $0["cmd"] as? String == "seek" }, "the scrub was sent")
        XCTAssertNil(state.pendingSpeechSeekWordIndex, "the scrub retires the waiting click and its underline")
        now += 0.2 // +0.4 s: well inside the 1.5 s window
        state.handleEvent(try words(from: 25))
        XCTAssertFalse(sent[(scrubAt + 1)...].contains { $0["cmd"] as? String == "speech_seek" },
                       "no word seek after the newer scrub")
    }

    /// The same intent rule for every other playback navigation the reading player offers.
    func testEveryNewerPlaybackNavigationCancelsAQueuedWordClick() throws {
        let actions: [(name: String, cmd: String, run: (VoiceState) -> Void)] = [
            ("another word click", "speech_seek", { $0.seekSpeechWord(utteranceID: "u-v09", wordIndex: 10) }),
            ("pause", "pause", { $0.togglePlaybackPause() }),
            ("speed change", "set_playback_speed", { $0.cyclePlaybackSpeed() }),
            ("skip to next read", "read_next", { $0.skipToNextRead() }),
            ("previous read", "previous_read", { $0.playPreviousRead() }),
            ("stop", "stop", { $0.stop() }),
        ]
        for action in actions {
            sent = []
            let state = try readingState(timedWords: 25)
            state.handleEvent(["type": "read_queue", "count": 1, "current_request_id": "r-current"])
            state.handleEvent(["type": "playback_session", "phase": "playing", "previous_available": true])
            state.seekSpeechWord(utteranceID: "u-v09", wordIndex: 26)
            now += 0.2
            action.run(state)
            let at = try XCTUnwrap(sent.lastIndex { $0["cmd"] as? String == action.cmd }, "\(action.name) was sent")
            XCTAssertNil(state.pendingSpeechSeekWordIndex, "\(action.name) retires the waiting click")
            now += 0.2
            state.handleEvent(try words(from: 25))
            XCTAssertFalse(sent[(at + 1)...].contains { $0["cmd"] as? String == "speech_seek" },
                           "no queued word seek fires after \(action.name)")
        }
    }

    // MARK: F3: before the first chunk, a click waits for its word

    func testBeforeTheFirstChunkEveryWordIsATargetAndAClickWaitsForIt() throws {
        let state = try readingState(timedWords: nil)
        let model = try model(state)
        let dead = model.layouts.indices.filter { model.seekTarget(for: $0, table: state.speechWords) == nil }
        XCTAssertEqual(dead, [], "no dead zone before the first speech_words chunk")
        state.seekSpeechWord(utteranceID: "u-v09", wordIndex: 3)
        XCTAssertTrue(seeks.isEmpty, "nothing the daemon would refuse is sent")
        now += 0.4
        state.handleEvent(try words(from: 0, count: 25))
        XCTAssertEqual(seeks.first?["wordIndex"] as? Int, 3, "the first chunk's timing seeks the clicked word")
    }

    // MARK: F4: the canvas outlasts the read by one collapse

    func testTheCanvasOutlastsTheReadUntilTheCollapseSettles() {
        let model = VoiceBarNotchPresentationModel()
        var release: (() -> Void)?
        var delay: TimeInterval?
        model.scheduleReadingCanvasRelease = { delay = $0; release = $1 }
        func canvasHeight() -> CGFloat { VoiceBarNotchMorphCanvasLayout.resolve(for: model.presentation).canvasGeometry.totalHeight }
        model.setTeleprompterLines(8)
        model.updateOperationalEnvelope(hasTeleprompter: true, isRecording: false, hasCompactStatus: false,
                                        holdsReadingCanvas: true)
        let reading = canvasHeight()
        // Stop / Close read: the read leaves the screen and the shell starts collapsing to idle.
        model.updateOperationalEnvelope(hasTeleprompter: false, isRecording: false, hasCompactStatus: false,
                                        holdsReadingCanvas: false)
        XCTAssertEqual(model.presentation.visualState, .idle)
        XCTAssertEqual(canvasHeight(), reading, "the canvas does not shrink under the collapsing shell")
        XCTAssertEqual(delay, VoiceBarNotchModelTestsSupport.releaseDelay)
        release?()
        XCTAssertLessThan(canvasHeight(), reading, "then it shrinks, once the shell has settled")
    }

    func testANewReadCancelsAPendingRelease() {
        let model = VoiceBarNotchPresentationModel()
        var release: (() -> Void)?
        model.scheduleReadingCanvasRelease = { release = $1 }
        model.updateOperationalEnvelope(hasTeleprompter: true, isRecording: false, hasCompactStatus: false,
                                        holdsReadingCanvas: true)
        model.updateOperationalEnvelope(hasTeleprompter: false, isRecording: false, hasCompactStatus: false,
                                        holdsReadingCanvas: false)
        model.updateOperationalEnvelope(hasTeleprompter: true, isRecording: false, hasCompactStatus: false,
                                        holdsReadingCanvas: true)
        release?()
        XCTAssertTrue(model.presentation.holdsReadingCanvas, "a stale release never drops a live read's canvas")
    }

    // MARK: F6: one unmatched word costs only its own target

    func testAWordTokenMismatchKeepsEveryOtherWordSeekable() {
        // A document whose words disagree with the text's tokens (one token has no drawn word).
        let document = TeleprompterRenderCache().document(text: "Hello brave world again", wordBoundaries: [],
                                                          displayBlocks: [], hasCompleteDisplay: false)
        let model = TeleprompterAModel(document: document, text: "Hello brave new world again",
                                       column: TeleprompterA.columnWidth)
        XCTAssertNil(model.tokenOfWord, "the exact piece map is unavailable here")
        var table = SpeechWordTable(utteranceID: "u1")
        _ = table.apply(["utteranceId": "u1", "wordOffset": 0, "words": [
            ["text": "Hello", "startMs": 0, "endMs": 200], ["text": "brave", "startMs": 300, "endMs": 500],
            ["text": "new", "startMs": 600, "endMs": 800], ["text": "world", "startMs": 900, "endMs": 1100],
            ["text": "again", "startMs": 1200, "endMs": 1400],
        ]])
        let targets = model.layouts.indices.map { model.seekTarget(for: $0, table: table) }
        XCTAssertEqual(targets, [.word(utteranceID: "u1", index: 0), .word(utteranceID: "u1", index: 1),
                                 .word(utteranceID: "u1", index: 3), .word(utteranceID: "u1", index: 4)])
        XCTAssertEqual(model.focusWord(table: table, clock: 950), 2, "the highlight follows the aligned token")
        XCTAssertEqual(TeleprompterAModel.alignedTokens(words: ["Hello", "zzz", "world"], tokens: ["Hello", "world"]),
                       [0, nil, 1], "a word found nowhere maps to nil alone")
    }

    // MARK: F7: a speed change always re-anchors the clock

    func testASpeedChangeEdgeIsNeverTreatedAsStale() throws {
        let state = try readingState(timedWords: 59)
        state.handleEvent(["type": "playback_position", "playback_id": "v09", "generation": 1, "offset_ms": 5_000,
                           "playback_rate": 1])
        XCTAssertEqual(state.playbackElapsedMilliseconds(), 5_000, accuracy: 5)
        // The daemon restarts the player at 2x from the current word (4600 ms), behind the client's 5000 ms.
        state.handleEvent(["type": "state", "state": "speaking", "text": try XCTUnwrap(state.teleprompterText),
                           "duration_ms": 39_000, "playback_id": "v09", "generation": 2, "utteranceId": "u-v09",
                           "playback_offset_ms": 4_600, "playback_rate": 2,
                           "long_read": ["id": "u-v09", "chunk_index": 0, "chunk_count": 1, "chunk_start_ms": 0]])
        now += 1
        XCTAssertEqual(state.playbackElapsedMilliseconds(), 6_600, accuracy: 20,
                       "audio is at 4600 + 2 x 1000 ms; the highlight must be too")
    }
}

/// The release delay the model schedules, read here so the test pins the shell-collapse budget.
enum VoiceBarNotchModelTestsSupport {
    static let releaseDelay = VoiceBarNotchPresentationModel.readingCanvasReleaseDelay
}
