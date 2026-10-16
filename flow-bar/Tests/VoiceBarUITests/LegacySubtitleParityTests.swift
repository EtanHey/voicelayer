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

    func testLegacyEventTableMatches85a1fa5c() {
        // Captured from base's subtitle handler + content/playback policies.
        // Each event follows a valid event: missing/mistyped words are no-ops;
        // an explicit empty array clears, and partial display coverage estimates.
        let cases: [(String, [String: Any], [Int], [Int?], Bool)] = [
            ("valid", ["words": valid], [0, 500], [0, 500], true),
            ("zero duration", ["words": [["text": "Hello", "offset_ms": 0, "duration_ms": 0], valid[1]]],
             [0, 500], [0, 500], true),
            ("partial", ["words": [valid[0]]], [0], [nil, nil], false),
            ("missing", [:], [0, 500], [0, 500], true),
            ("mistyped", ["words": "bad"], [0, 500], [0, 500], true),
            ("empty", ["words": []], [], [nil, nil], false),
        ]
        for chunkStart in [0, 12000] {
            for (name, payload, offsets, displayOffsets, measured) in cases {
                let state = VoiceState(playbackAmplitudeClock: { 100 })
                state.handleEvent(["type": "state", "state": "speaking", "text": "Hello world",
                                   "long_read": ["chunk_start_ms": chunkStart], "duration_ms": chunkStart + 5000])
                state.handleEvent(["type": "subtitle", "words": valid])
                let previous = state.wordBoundaries
                state.handleEvent(payload.merging(["type": "subtitle"]) { _, new in new })
                if name == "missing" || name == "mistyped" { XCTAssertEqual(state.wordBoundaries, previous, name) }
                let words = TeleprompterContentModel.words(text: "Hello world", wordBoundaries: state.wordBoundaries)
                XCTAssertEqual(state.wordBoundaries.compactMap(\.offsetMs), offsets.map { $0 + chunkStart }, name)
                XCTAssertEqual(words.map(\.offsetMs), displayOffsets.map { $0.map { $0 + chunkStart } }, name)
                XCTAssertEqual(TeleprompterPlaybackPolicy.usesServerTimestamps(in: words), measured, name)
                XCTAssertEqual(TeleprompterPlaybackPolicy.playbackOffsetMilliseconds(forWordAt: 1, in: words),
                               measured ? chunkStart + 500 : 355, name)
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
