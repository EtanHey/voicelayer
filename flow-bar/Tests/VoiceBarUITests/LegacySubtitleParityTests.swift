import AppKit
import SwiftUI
import XCTest
import OffscreenTestSupport
@testable import VoiceBarUI

@MainActor
final class LegacySubtitleParityTests: XCTestCase {
    private let valid: [[String: Any]] = [
        ["text": "Hello", "offset_ms": 0, "duration_ms": 100],
        ["text": "world", "offset_ms": 500, "duration_ms": 100],
    ]

    func testLegacyEventTableMatches85a1fa5c() throws {
        // Captured from base's subtitle handler + content/playback policies.
        // Each event follows a valid event: missing/mistyped words are no-ops;
        // an explicit empty array clears, and partial display coverage estimates.
        let numericCases: [(String, Any, Any, Int, Int)] = [
            ("negative fraction", -0.5, 100, 0, 100),
            ("negative offset", -1.5, 100, -1, 100),
            ("negative duration", 0, -100.5, 0, -100),
            ("boolean offset true", true, 100, 1, 100),
            ("boolean offset false", false, 100, 0, 100),
            ("boolean duration true", 0, true, 0, 1),
            ("boolean duration false", 0, false, 0, 0),
            ("fractional", 120.5, 80.75, 120, 80),
        ]
        var cases: [(String, [String: Any], [Int], [Int?], Bool, [Int])] = [
            ("valid", ["words": valid], [0, 500], [0, 500], true, [100, 100]),
            ("zero duration", ["words": [["text": "Hello", "offset_ms": 0, "duration_ms": 0], valid[1]]],
             [0, 500], [0, 500], true, [0, 100]),
            ("partial", ["words": [valid[0]]], [0], [nil, nil], false, [100]),
            ("missing", [:], [0, 500], [0, 500], true, [100, 100]),
            ("mistyped", ["words": "bad"], [0, 500], [0, 500], true, [100, 100]),
            ("empty", ["words": []], [], [nil, nil], false, []),
        ]
        for (name, offset, duration, expectedOffset, expectedDuration) in numericCases {
            let row: [String: Any] = ["text": "Hello", "offset_ms": offset, "duration_ms": duration]
            cases.append((name, ["words": [row, valid[1]]], [expectedOffset, 500],
                          [expectedOffset, 500], true, [expectedDuration, 100]))
        }
        for chunkStart in [0, 12000] {
            for (name, payload, offsets, displayOffsets, measured, durations) in cases {
                let state = VoiceState(playbackAmplitudeClock: { 100 })
                state.handleEvent(["type": "state", "state": "speaking", "text": "Hello world",
                                   "long_read": ["chunk_start_ms": chunkStart], "duration_ms": chunkStart + 5000])
                state.handleEvent(["type": "subtitle", "words": valid])
                let previous = state.wordBoundaries
                // Use the real JSON bridge: JSON booleans are NSNumber, not Swift Bool.
                let data = try JSONSerialization.data(withJSONObject: payload.merging(["type": "subtitle"]) { _, new in new })
                let event = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
                state.handleEvent(event)
                if name == "missing" || name == "mistyped" { XCTAssertEqual(state.wordBoundaries, previous, name) }
                let words = TeleprompterContentModel.words(text: "Hello world", wordBoundaries: state.wordBoundaries)
                XCTAssertEqual(state.wordBoundaries.compactMap(\.offsetMs), offsets.map { $0 + chunkStart }, name)
                XCTAssertEqual(state.wordBoundaries.compactMap(\.durationMs), durations, name)
                XCTAssertEqual(words.map(\.offsetMs), displayOffsets.map { $0.map { $0 + chunkStart } }, name)
                XCTAssertEqual(words.map { TeleprompterSeekPolicy.offset(for: $0, isReadback: false) },
                               displayOffsets.map { $0.flatMap { $0 + chunkStart >= 0 ? $0 + chunkStart : nil } }, name)
                XCTAssertEqual(TeleprompterPlaybackPolicy.usesServerTimestamps(in: words), measured, name)
                XCTAssertEqual(TeleprompterPlaybackPolicy.playbackOffsetMilliseconds(forWordAt: 1, in: words),
                               measured ? chunkStart + 500 : 355, name)
            }
        }
    }

    func testLegacyNumericConversionNeverTrapsAndIndexedNumbersStayStrict() throws {
        for chunkStart in [0, 12000] {
            for (offset, duration): (Any, Any) in [(Double.infinity, 100), (Double.nan, 100),
                (1e100, 100), (-1e100, 100), (0, Double.infinity), (Int.max, 1), (Int.min, Int.min)] {
                let rows: [[String: Any]] = [["text": "Hello", "offset_ms": offset, "duration_ms": duration]]
                let decoded = TeleprompterBoundary.subtitleWords(["words": rows], chunkStartMs: chunkStart)
                XCTAssertTrue(decoded.isEmpty, "unsafe legacy timings must drop the row")
            }
            let exact = TeleprompterBoundary.subtitleWords(["words": [["text": "Hello", "offset_ms": Int.max, "duration_ms": 0]]],
                                                          chunkStartMs: chunkStart)
            XCTAssertEqual(exact.first?.offsetMs, chunkStart == 0 ? Int.max : nil)
            XCTAssertEqual(exact.count, chunkStart == 0 ? 1 : 0)
            for (offset, duration): (Any, Any) in [(-0.5, 100), (-1.5, 100), (0, -100.5), (true, 100),
                                                  (false, 100), (0, true), (0, false)] {
                let data = try JSONSerialization.data(withJSONObject: ["aligned_words": [
                    ["word_index": 0, "text": "Hello", "offset_ms": offset, "duration_ms": duration]]])
                let event = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
                let decoded = TeleprompterBoundary.subtitleWords(event, chunkStartMs: chunkStart)
                XCTAssertEqual(decoded.count, 1)
                XCTAssertNil(decoded[0].offsetMs)
                XCTAssertNil(decoded[0].durationMs)
                XCTAssertEqual(decoded[0].wordIndex, 0)
            }
        }
    }

    func testLegacyJSONOverflowDropsOnlyUnsafeRows() throws {
        let cases = [(Int.max, 1, 0), (Int.max, 0, 12000),
                     (Int.max - 12000, 1, 12000), (Int.min, -1, 0)]
        for (offset, duration, chunkStart) in cases {
            let unsafe: [String: Any] = ["text": "unsafe", "offset_ms": offset, "duration_ms": duration]
            for rows in [[unsafe], [valid[0], unsafe, valid[1]]] {
                let data = try JSONSerialization.data(withJSONObject: ["words": rows])
                let event = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
                let decoded = TeleprompterBoundary.subtitleWords(event, chunkStartMs: chunkStart)
                let expected = rows.count == 1 ? [] : valid.map {
                    TeleprompterBoundary(offsetMs: ($0["offset_ms"] as! Int) + chunkStart,
                                         durationMs: $0["duration_ms"] as? Int, text: $0["text"] as! String)
                }
                XCTAssertEqual(decoded, expected, "offset=\(offset), duration=\(duration), chunk=\(chunkStart)")
            }
        }
    }

    func testLegacyOverflowOnlyEventNeverRendersEstimatedKaraoke() async throws {
        for (offset, duration, chunkStart) in [(Int.max, 1, 0), (Int.max, 0, 12000)] {
            let state = VoiceState(playbackAmplitudeClock: { 100 })
            state.handleEvent(["type": "state", "state": "speaking", "text": "Hello world",
                               "long_read": ["chunk_start_ms": chunkStart], "duration_ms": chunkStart + 5000])
            state.handleEvent(["type": "subtitle", "words": valid])
            let data = try JSONSerialization.data(withJSONObject: ["type": "subtitle", "words": [
                ["text": "Hello", "offset_ms": offset, "duration_ms": duration]]])
            let event = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            state.handleEvent(event)
            XCTAssertTrue(state.wordBoundaries.isEmpty)
            for appearance in [VoiceBarNotchAppearance.dark, .light] {
                var elapsed = chunkStart
                let host = NSHostingView(rootView: TeleprompterView(text: "Hello world", wordBoundaries: state.wordBoundaries,
                    playbackElapsedMilliseconds: { elapsed }, wrapWidth: 240, viewportHeight: 60)
                    .environment(\.voiceBarNotchAppearance, appearance).frame(width: 250, height: 70).background(.black))
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 250, height: 70),
                                      styleMask: [.borderless], backing: .buffered, defer: false)
                window.contentView = host
                window.isReleasedWhenClosed = false
                VLOrderTestWindow(window)
                defer { window.close() }
                try await Task.sleep(for: .milliseconds(100))
                XCTAssertNil(try highlightCenter(host), "overflow-only legacy subtitles have no highlight")
                elapsed += 500
                try await Task.sleep(for: .milliseconds(700))
                XCTAssertNil(try highlightCenter(host), "overflow-only legacy subtitles never start estimated karaoke")
            }
        }
    }

    func testMalformedIndexedEventsStillClearPreviousTimings() {
        for malformed: Any in [NSNull(), "bad", [] as [Any]] {
            let state = VoiceState(playbackAmplitudeClock: { 100 })
            state.handleEvent(["type": "subtitle", "words": valid])
            state.handleEvent(["type": "subtitle", "words": valid, "aligned_words": malformed])
            XCTAssertTrue(state.wordBoundaries.isEmpty)
        }
    }

    func testLegacyPartialRendererHighlightsAndAdvancesLikeBase() async throws {
        let boundaries = [TeleprompterBoundary(offsetMs: 0, durationMs: 100, text: "Hello")]
        let words = TeleprompterContentModel.words(text: "Hello world", wordBoundaries: boundaries)
        XCTAssertEqual(words.map(\.offsetMs), [nil, nil])
        XCTAssertTrue(words.allSatisfy { TeleprompterSeekPolicy.offset(for: $0, isReadback: false) == nil })
        for appearance in [VoiceBarNotchAppearance.dark, .light] {
            var elapsed = 0
            let host = NSHostingView(rootView: TeleprompterView(text: "Hello world", wordBoundaries: boundaries,
                playbackElapsedMilliseconds: { elapsed }, wrapWidth: 240, viewportHeight: 60)
                .environment(\.voiceBarNotchAppearance, appearance).frame(width: 250, height: 70).background(.black))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 250, height: 70),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = host
            window.isReleasedWhenClosed = false
            VLOrderTestWindow(window)
            defer { window.close() }
            try await Task.sleep(for: .milliseconds(100))
            let first = try highlightCenter(host)
            XCTAssertNotNil(first, "base highlights the first legacy untimed display word")
            elapsed = 500
            try await Task.sleep(for: .milliseconds(700))
            let second = try highlightCenter(host)
            XCTAssertNotNil(second, "base animates partial legacy subtitles using estimated pacing")
            if let first, let second { XCTAssertGreaterThan(second, first + 20) }
        }
    }

    func testIndexedUnknownAndInvalidIdentityNeverRenderEstimatedHighlight() async throws {
        for rows: [[String: Any]] in [
            [["word_index": 0, "text": "Hello", "offset_ms": NSNull(), "duration_ms": NSNull()]],
            [["word_index": 0, "text": "wrong", "offset_ms": 0, "duration_ms": 100]],
            [["word_index": 0, "text": "Hello", "offset_ms": NSNull(), "duration_ms": NSNull()],
             ["word_index": 1, "text": "world", "offset_ms": 500, "duration_ms": 100]],
        ] {
            let state = VoiceState(playbackAmplitudeClock: { 100 })
            state.handleEvent(["type": "subtitle", "aligned_words": rows])
            let host = NSHostingView(rootView: TeleprompterView(text: "Hello world", wordBoundaries: state.wordBoundaries,
                playbackElapsedMilliseconds: { 0 }, wrapWidth: 240, viewportHeight: 60)
                .frame(width: 250, height: 70).background(.black))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 250, height: 70),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = host
            window.isReleasedWhenClosed = false
            VLOrderTestWindow(window)
            defer { window.close() }
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertNil(try highlightCenter(host), "indexed words without proven timing stay unhighlighted")
        }
    }

    private func highlightCenter(_ host: NSView) throws -> Double? {
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        var xs: [Int] = []
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                guard let c = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                if c.blueComponent > c.redComponent + 0.10 && c.greenComponent > c.redComponent + 0.03 {
                    xs.append(x)
                }
            }
        }
        return xs.isEmpty ? nil : Double(xs.reduce(0, +)) / Double(xs.count)
    }
}
