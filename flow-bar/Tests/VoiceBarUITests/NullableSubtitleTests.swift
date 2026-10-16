import XCTest
import SwiftUI
import OffscreenTestSupport
@testable import VoiceBarUI

@MainActor
final class NullableSubtitleTests: XCTestCase {
    private func row(_ index: Int, _ text: String, _ offset: Any = NSNull(), _ duration: Any = NSNull()) -> [String: Any] {
        ["word_index": index, "text": text, "offset_ms": offset, "duration_ms": duration]
    }

    private func receive(_ text: String, _ rows: [[String: Any]], chunkStart: Int = 0) -> VoiceState {
        let state = VoiceState(playbackAmplitudeClock: { 100 })
        state.handleEvent(["type": "state", "state": "speaking", "text": text,
                           "duration_ms": chunkStart + 5000, "long_read": ["chunk_start_ms": chunkStart]])
        state.handleEvent(["type": "subtitle", "words": [], "aligned_words": rows])
        return state
    }

    private func words(_ state: VoiceState) -> [TeleprompterWord] {
        TeleprompterContentModel.words(text: state.statusText, wordBoundaries: state.wordBoundaries)
    }

    func testLegacyEdgeZeroDurationKeepsOffsetAndSeekWhileIndexedStaysNull() {
        for chunkStart in [0, 12000] {
            let state = receive("- MP3", [row(0, "-", 0, 0), row(1, "MP3", 0, 250)], chunkStart: chunkStart)
            XCTAssertEqual(words(state).map(\.offsetMs), [nil, chunkStart])
            state.handleEvent(["type": "subtitle", "words": [["text": "-", "offset_ms": 0, "duration_ms": 0],
                                                           ["text": "MP3", "offset_ms": 0, "duration_ms": 250]]])
            XCTAssertEqual(state.wordBoundaries.map(\.offsetMs), [chunkStart, chunkStart])
            XCTAssertEqual(words(state).map(\.durationMs), [0, 250])
            XCTAssertEqual(words(state).map { TeleprompterSeekPolicy.offset(for: $0, isReadback: false) }, [chunkStart, chunkStart])
            XCTAssertTrue(TeleprompterPlaybackPolicy.usesServerTimestamps(in: words(state)))
        }
    }

    func testIndexedPartialTimelineUsesOnlyMeasuredWords() {
        let mapped = words(receive("one two three", [row(0, "one", 0, 200), row(1, "two"), row(2, "three", 700, 200)]))
        XCTAssertTrue(TeleprompterPlaybackPolicy.usesServerTimestamps(in: mapped))
        XCTAssertNil(TeleprompterPlaybackPolicy.playbackOffsetMilliseconds(forWordAt: 1, in: mapped))
        XCTAssertEqual(TeleprompterPlaybackPolicy.currentWordIndex(in: mapped, elapsedMilliseconds: 660), 0)
        XCTAssertEqual(TeleprompterPlaybackPolicy.currentWordIndex(in: mapped, elapsedMilliseconds: 700), 2)
    }

    func testNullWordsKeepTheirPositionsAndOnlyProvenOccurrencesSeek() {
        let state = receive("go now go home", [row(3, "home", 900, 100), row(1, "now", 200, 100),
                                                row(0, "go"), row(2, "go")], chunkStart: 12000)
        let mapped = words(state)
        XCTAssertEqual(mapped.map(\.text), ["go", "now", "go", "home"])
        XCTAssertEqual(mapped.map(\.offsetMs), [nil, 12200, nil, 12900])
        XCTAssertEqual(mapped.map(\.durationMs), [nil, 100, nil, 100])
        var commands: [[String: Any]] = []
        state.sendCommand = { commands.append($0) }
        for word in mapped { TeleprompterSeekPolicy.seek(word, isReadback: false, seek: state.seek) }
        XCTAssertEqual(commands.compactMap { $0["offset_ms"] as? Int }, [12200, 12900])
        XCTAssertTrue(mapped.allSatisfy { !$0.hasEstimatedTiming })
    }

    func testSevenTimingsNeverCompactOntoTenWords() {
        let text = (0..<10).map { "word\($0)" }.joined(separator: " ")
        let state = receive(text, (0..<10).map {
            $0 % 3 == 0 && $0 != 0 ? row($0, "word\($0)") : row($0, "word\($0)", $0 * 100, 80)
        })
        XCTAssertEqual(state.wordBoundaries.count, 10)
        XCTAssertEqual(words(state).map(\.offsetMs), [0, 100, 200, nil, 400, 500, nil, 700, 800, nil])
    }

    func testIndexIsBeforeVisualWrappingAndSparseRowsNeverShift() {
        let token = String(repeating: "a", count: 50)
        let mapped = words(receive(token + " gap end", [row(2, "end", 700, 80), row(0, token, 100, 300)]))
        XCTAssertEqual(mapped.map(\.offsetMs), [100, 100, 100, nil, 700])
        XCTAssertEqual(mapped.map(\.text).joined(), token + "gapend")
        XCTAssertTrue(TeleprompterPlaybackPolicy.usesServerTimestamps(in: mapped))
    }

    func testInvalidIndexedIdentityNeverFallsBackToLegacyTimings() {
        for rows in [[row(0, "go", 100, 80), row(0, "go", 500, 80)],
                     [row(1, "wrong", 100, 80)], [row(3, "go", 100, 80)]] {
            let state = receive("go go", rows)
            state.handleEvent(["type": "subtitle", "words": [["text": "go", "offset_ms": 50, "duration_ms": 80]],
                               "aligned_words": rows])
            XCTAssertTrue(words(state).allSatisfy { $0.offsetMs == nil })
        }
    }

    func testMalformedTimingStaysNullWithoutLosingTheWord() {
        for pair: (Any, Any) in [(NSNull(), 80), (100, NSNull()), (-1, 80), (-0.5, 80), (100, -1),
                                 (true, 80), (Double.infinity, 80), (1e100, 80)] {
            let state = receive("first second", [row(0, "first", pair.0, pair.1), row(1, "second", 500, 80)])
            XCTAssertEqual(words(state).map(\.offsetMs), [nil, 500])
        }
    }

    func testOldDaemonAndRetainedReadbackRemainCompatible() {
        let state = receive("Hello world", [])
        state.handleEvent(["type": "subtitle", "words": [["text": "Hello", "offset_ms": 120.5, "duration_ms": 80],
                                                          ["text": "world", "offset_ms": 500, "duration_ms": 90]]])
        XCTAssertEqual(words(state).map(\.offsetMs), [120, 500])
        state.handleEvent(["type": "subtitle", "words": [], "aligned_words": [row(0, "Hello"), row(1, "world", 500, 90)]])
        state.handleEvent(["type": "state", "state": "idle", "source": "playback"])
        let retained = TeleprompterContentModel.words(text: state.teleprompterText ?? "", wordBoundaries: state.teleprompterWordBoundaries)
        XCTAssertEqual(retained.map(\.offsetMs), [nil, 500])
        XCTAssertTrue(retained.allSatisfy { TeleprompterSeekPolicy.offset(for: $0, isReadback: true) == nil })
        state.handleEvent(["type": "state", "state": "speaking", "text": "Next reply", "duration_ms": 5000])
        XCTAssertTrue(state.wordBoundaries.isEmpty)
    }

    func testAllNullNoticeAndSameLengthLateTimingUpdate() {
        let state = receive("first second", [row(0, "first"), row(1, "second")])
        let wrapper = TeleprompterPlaybackScrubBar(state: state)
        XCTAssertEqual(wrapper.timingNotice, "Word timing unavailable")
        XCTAssertTrue(wrapper.control.allowsSeeking, "time scrubbing remains available")
        XCTAssertFalse(TeleprompterPlaybackPolicy.usesServerTimestamps(in: words(state)))
        let epoch = state.playbackEpoch
        state.handleEvent(["type": "subtitle", "words": [], "aligned_words": [row(0, "first"), row(1, "second", 500, 80)]])
        XCTAssertEqual(state.playbackEpoch, epoch, "timing delivery does not restart audio")
        XCTAssertNil(wrapper.timingNotice)
        XCTAssertTrue(TeleprompterPlaybackPolicy.usesServerTimestamps(in: words(state)))
        XCTAssertNil(TeleprompterPlaybackPolicy.playbackOffsetMilliseconds(forWordAt: 0, in: words(state)))
        XCTAssertEqual(TeleprompterPlaybackPolicy.currentWordIndex(in: words(state), elapsedMilliseconds: 600), 1)
        XCTAssertEqual(words(state).map { TeleprompterSeekPolicy.offset(for: $0, isReadback: false) }, [nil, 500])
    }

    func testWritesNullableTimingArtifacts() async throws {
        try VisualArtifactTestPolicy.requireRegeneration()
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("docs.local/CLN1B")
        let tokens = ["Unknown", "words", "stay", "readable.", "Verified", "words", "become", "clickable."]
        for partial in [false, true] {
            let state = receive(tokens.joined(separator: " "), tokens.enumerated().map {
                partial && $0.offset % 2 == 0 ? row($0.offset, $0.element, $0.offset * 300, 200) : row($0.offset, $0.element)
            })
            let view = VStack(spacing: 10) {
                TeleprompterView(text: state.statusText, wordBoundaries: state.wordBoundaries,
                    playbackElapsedMilliseconds: state.playbackElapsedMilliseconds, onSeek: state.seek)
                TeleprompterPlaybackScrubBar(state: state)
            }.padding(12).frame(width: 465, height: 170).background(Color.black)
            let host = NSHostingView(rootView: view)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 465, height: 170),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = host
            window.appearance = NSAppearance(named: .darkAqua)
            window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
            window.isReleasedWhenClosed = false
            VLOrderTestWindow(window)
            defer { window.close() }
            try await Task.sleep(for: .milliseconds(100))
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                .write(to: directory.appendingPathComponent(partial ? "partial.png" : "all-null.png"))
        }
    }
}
