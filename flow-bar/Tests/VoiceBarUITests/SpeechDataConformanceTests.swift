import XCTest
@testable import VoiceBarUI

@MainActor
final class SpeechDataConformanceTests: XCTestCase {
    func testFirstSpeakingFrameIncludesTimingBeforeAlignment() throws {
        let state = VoiceState()
        let words: [[String: Any]] = [
            ["word_index": 0, "text": "One", "offset_ms": 0, "duration_ms": 1000, "estimated": true],
            ["word_index": 1, "text": "two", "offset_ms": 1000, "duration_ms": 1000, "estimated": true]
        ]
        var observedReady = false
        state.onModeChange = { mode in
            if mode == .speaking { observedReady = !state.wordBoundaries.isEmpty }
        }
        state.handleEvent(["type": "state", "state": "speaking", "text": "One two", "duration_ms": 2000,
                           "initial_timing": ["type": "subtitle", "words": [], "aligned_words": words, "duration_ms": 2000]])
        XCTAssertTrue(observedReady, "TimingNeverBlankWhilePlaying at the first speaking notification")
        XCTAssertEqual(state.wordBoundaries.map(\.offsetMs), [0, 1000])
        XCTAssertTrue(state.wordBoundaries.allSatisfy(\.isInterpolated))
        state.handleEvent(["type": "subtitle", "words": [], "duration_ms": 2000, "aligned_words": [
            ["word_index": 0, "text": "One", "offset_ms": 100, "duration_ms": 800],
            ["word_index": 1, "text": "two", "offset_ms": 1200, "duration_ms": 700]
        ]])
        XCTAssertEqual(state.wordBoundaries.map(\.offsetMs), [100, 1200], "Real timing replaces the estimate immediately")
        XCTAssertFalse(state.wordBoundaries.contains(where: \.isInterpolated))
    }

    func testStartupTimingUsesChunkDurationAndGlobalOffsetOnce() {
        let state = VoiceState()
        state.handleEvent(["type": "state", "state": "speaking", "text": "Next words", "duration_ms": 9000,
                           "playback_offset_ms": 4000,
                           "long_read": ["id": "read", "chunk_index": 1, "chunk_count": 2, "chunk_start_ms": 4000],
                           "initial_timing": ["type": "subtitle", "words": [], "duration_ms": 1000, "aligned_words": [
                            ["word_index": 0, "text": "Next", "offset_ms": 0, "duration_ms": 500, "estimated": true],
                            ["word_index": 1, "text": "words", "offset_ms": 500, "duration_ms": 500, "estimated": true]
                           ]]])
        XCTAssertEqual(state.wordBoundaries.map(\.offsetMs), [4000, 4500])
        XCTAssertEqual(state.playbackWordTimeline.map(\.offsetMs), [4000, 4500])
    }

    func testRealDaemonQueueAndTimingProjection() throws {
        let env = ProcessInfo.processInfo.environment
        guard let queuePath = env["VOICELAYER_SPEECH_WIRE"], let timingPath = env["VOICELAYER_SPEECH_TIMING_WIRE"] else {
            throw XCTSkip("Run formal/speech-queue/check.sh for real daemon speech-data events")
        }
        let rows = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: queuePath))) as? [[String: Any]])
        for row in rows {
            let state = VoiceState()
            for event in try XCTUnwrap(row["events"] as? [[String: Any]]) { state.handleEvent(event) }
            XCTAssertEqual(state.queuedSpeakCount, row["expected"] as? Int, "QueuedCountExcludesCurrent")
        }
        let timing = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: timingPath))) as? [String: Any])
        let state = VoiceState()
        state.handleEvent(timing)
        XCTAssertTrue(state.wordBoundaries.contains { $0.offsetMs != nil }, "TimingNeverBlankWhilePlaying")
        XCTAssertTrue(state.teleprompterWordBoundaries.contains { $0.offsetMs != nil })
        print("Speech data replayed \(rows.count) real queue snapshots and first speaking frame")
    }
}
