import SwiftUI
@testable import VoiceBarUI
import XCTest

/// U5 guards: one per Teleprompter A behaviour. Sync is proved against the `speech_words` stream, never audio.
@MainActor
final class TeleprompterAModelTests: XCTestCase {
    private func words(_ utterance: String, offset: Int, _ rows: [(String, Int, Int)]) -> [String: Any] {
        ["type": "speech_words", "utteranceId": utterance, "wordOffset": offset, "approximate": false,
         "words": rows.map { ["text": $0.0, "startMs": $0.1, "endMs": $0.2] }]
    }

    func testFirstLineIsFlushThenTheFocusHoldsTheMiddleRow() {
        XCTAssertEqual((0 ... 4).map { TeleprompterA.scrolledLines(focusLine: $0, visibleLines: 3) }, [0, 0, 1, 2, 3])
        XCTAssertEqual((0 ... 5).map { TeleprompterA.scrolledLines(focusLine: $0, visibleLines: 8) }, [0, 0, 0, 0, 1, 2])
        XCTAssertEqual(TeleprompterA.scrolledLines(focusLine: nil, visibleLines: 3), 0)
    }

    func testTopFadeAppearsOnlyOnceALineHasScrolledUnderIt() {
        XCTAssertFalse(TeleprompterA.showsTopFade(scrolledLines: 0))
        XCTAssertTrue(TeleprompterA.showsTopFade(scrolledLines: 1))
    }

    func testLineSlideIs240msQuartAndReducedMotionJumps() {
        XCTAssertEqual(TeleprompterA.slide(reduceMotion: false), .timingCurve(0.77, 0, 0.175, 1, duration: 0.24))
        XCTAssertNil(TeleprompterA.slide(reduceMotion: true))
    }

    func testSpokenReadUnreadTiers() {
        XCTAssertEqual([TeleprompterA.Tier.spoken, .read, .unread].map(\.opacity), [1, 0.64, 0.36])
        XCTAssertEqual([3, 5, 9].map { TeleprompterA.tier(group: $0, focusGroup: 5) }, [.read, .spoken, .unread])
        XCTAssertEqual(TeleprompterA.tier(group: 0, focusGroup: nil), .unread)
    }

    func testMetricsMatchTheSpec() {
        XCTAssertEqual(TeleprompterA.lineHeight, 24)
        XCTAssertEqual(TeleprompterA.fontSize, 17)
        // Lane B: the column follows the teleprompter body's whole text width (was a 404 pt cap).
        XCTAssertEqual(TeleprompterA.columnWidth, VoiceBarNotchContract.material.teleprompterTextWidth)
        XCTAssertEqual(TeleprompterA.topFadeHeight, 16)
        XCTAssertEqual(TeleprompterA.handleSize, CGSize(width: 34, height: 4))
        // T1/T3/T6 (Etan QA 2026-11-09): no footer row under the text.
        XCTAssertEqual(TeleprompterA.bodyHeight(lines: 3), 72)
        // T2/T8: text, scrubber, eye row 3 pt under it (≤ 7), the handle under the eye row.
        XCTAssertLessThanOrEqual(TeleprompterA.controlsGap, 7)
        XCTAssertEqual(TeleprompterA.chromeHeight, 91)
        XCTAssertEqual(TeleprompterA.lowerSurfaceHeight(lines: 3), 163)
    }

    func testHandleRubberBandsPastEitherEndAndSnapsToWholeLines() {
        XCTAssertEqual(TeleprompterA.draggedHeight(startLines: 3, translation: 30), 102)
        let pastEnd = TeleprompterA.draggedHeight(startLines: 8, translation: 400)
        XCTAssertGreaterThan(pastEnd, 192)
        XCTAssertLessThan(pastEnd, 192 + 24)
        XCTAssertLessThan(TeleprompterA.draggedHeight(startLines: 8, translation: 20), 192 + 20)
        let pastStart = TeleprompterA.draggedHeight(startLines: 3, translation: -400)
        XCTAssertLessThan(pastStart, 72)
        XCTAssertGreaterThan(pastStart, 72 - 24)
        XCTAssertEqual(TeleprompterA.snappedLines(startLines: 3, translation: 13), 4)
        XCTAssertEqual(TeleprompterA.snappedLines(startLines: 3, translation: 11), 3)
        XCTAssertEqual(TeleprompterA.snappedLines(startLines: 3, translation: 900), 8)
        XCTAssertEqual(TeleprompterA.snappedLines(startLines: 3, translation: -900), 3)
        XCTAssertEqual([0, 3, 5, 8, 12].map(TeleprompterA.clamp), [3, 3, 5, 8, 8])
    }

    func testFooterStateHasNoReadingProse() {
        // T3 (Etan QA 2026-11-09): reading draws no status words; the pause words are VoiceOver-only.
        XCTAssertEqual(TeleprompterA.footerState(isPaused: false, isPausedForDictation: false), "")
        XCTAssertEqual(TeleprompterA.footerState(isPaused: true, isPausedForDictation: false), "Paused")
        XCTAssertEqual(TeleprompterA.footerState(isPaused: true, isPausedForDictation: true),
                       "Paused for your dictation · resumes after paste")
    }

    func testWrapHonoursWidthForcedBreaksAndGlue() {
        let lines = TeleprompterA.lines(widths: [40, 40, 40, 10, 40], breaks: [false, false, false, false, true],
                                        glues: [false, false, false, true, false], spacing: 5, column: 100)
        XCTAssertEqual(lines, [0 ..< 2, 2 ..< 4, 4 ..< 5])
        XCTAssertEqual(TeleprompterA.lines(widths: [500], breaks: [false], glues: [false], spacing: 5, column: 100), [0 ..< 1])
    }

    func testAccessibilityValueIsTheCurrentSentence() {
        let texts = ["One", "two.", "Three", "four", "five.", "Six"]
        XCTAssertEqual(TeleprompterA.sentence(texts, around: 3), "Three four five.")
        XCTAssertEqual(TeleprompterA.sentence(texts, around: nil), "One two.")
        XCTAssertEqual(TeleprompterA.sentence(texts, around: 5), "Six")
        let quoted = ["He", "said", "\"Hello.\"", "Next", "sentence."]
        XCTAssertEqual(TeleprompterA.sentence(quoted, around: 1), "He said \"Hello.\"")
        XCTAssertEqual(TeleprompterA.sentence(quoted, around: 4), "Next sentence.")
        let curly = ["She", "asked", "“Why?”", "Then", "left."]
        XCTAssertEqual(TeleprompterA.sentence(curly, around: 3), "Then left.")
        XCTAssertEqual(TeleprompterA.sentence(["It", "worked", "(mostly.)", "Then", "stop."], around: 3), "Then stop.")
        XCTAssertEqual(TeleprompterA.sentence(["A", "[note!]", "B", "c."], around: 0), "A [note!]")
        XCTAssertEqual(TeleprompterA.sentence(["Say", "'yes.'", "Go"], around: 2), "Go")
    }

    func testWordTableUpsertsByGlobalIndexAndRefusesOtherUtterances() {
        var table = SpeechWordTable(utteranceID: "u1")
        XCTAssertTrue(table.apply(words("u1", offset: 2, [("again", 1200, 1500)])))
        XCTAssertTrue(table.apply(words("u1", offset: 0, [("Hello", 100, 300), ("world", 600, 850)])))
        XCTAssertFalse(table.apply(words("u2", offset: 0, [("Other", 0, 10)])))
        XCTAssertFalse(table.apply(["type": "speech_words", "utteranceId": "u1", "wordOffset": -1, "words": []]))
        XCTAssertFalse(table.apply(words("u1", offset: 0, [("Bad", 300, 100)])))
        // Times that do not fit Int, or NaN/negative ones, reject the payload without trapping or mutating.
        for (start, end) in [(1e20, 1e20), (100.0, 1e20), (Double.nan, 300.0), (-5.0, 300.0), (100.0, Double.infinity)] {
            XCTAssertFalse(table.apply(["utteranceId": "u1", "wordOffset": 0,
                                        "words": [["text": "Hello", "startMs": start, "endMs": end]]]), "\(start)…\(end)")
        }
        XCTAssertFalse(table.apply(["utteranceId": "u1", "wordOffset": 1e20, "words": [] as [[String: Any]]]))
        XCTAssertEqual(table.words.map { $0?.text }, ["Hello", "world", "again"])
        XCTAssertEqual(table.words[0]?.startMs, 100)
        // A later alignment replaces the same indices.
        XCTAssertTrue(table.apply(words("u1", offset: 2, [("again", 1900, 2300)])))
        XCTAssertEqual(table.words[2]?.startMs, 1900)
        XCTAssertEqual(table.seekIndex(token: 1, text: "world"), 1)
        XCTAssertNil(table.seekIndex(token: 1, text: "word"))
        XCTAssertNil(table.seekIndex(token: 7, text: "world"))
    }

    /// The highlighted word is exactly the last `speech_words` start the utterance clock has reached.
    func testHighlightFollowsSpeechWordsTimestamps() {
        let text = "Hello world again, friend."
        var table = SpeechWordTable(utteranceID: "u1")
        table.apply(words("u1", offset: 0, [("Hello", 100, 300), ("world", 600, 850)]))
        table.apply(words("u1", offset: 2, [("again,", 1200, 1500), ("friend.", 1900, 2300)]))
        let model = TeleprompterAModel(document: TeleprompterRenderCache().document(text: text, wordBoundaries: []),
                                       text: text, column: TeleprompterA.columnWidth)
        let clocks = [0, 99, 100, 599, 600, 1300, 1899, 1900, 5000]
        XCTAssertEqual(clocks.map { model.focusWord(table: table, clock: $0) }, [nil, nil, 0, 0, 1, 2, 2, 3, 3])
        XCTAssertEqual(model.seekTarget(for: 2, table: table), .word(utteranceID: "u1", index: 2))
    }

    func testLongTokenPiecesMapToOneGlobalWordIndex() {
        let long = String(repeating: "x", count: 30)
        let text = "Read \(long) now"
        var table = SpeechWordTable(utteranceID: "u")
        table.apply(words("u", offset: 0, [("Read", 0, 100), (long, 200, 400), ("now", 500, 600)]))
        let model = TeleprompterAModel(document: TeleprompterRenderCache().document(text: text, wordBoundaries: []),
                                       text: text, column: TeleprompterA.columnWidth)
        XCTAssertEqual(model.tokenOfWord, [0, 1, 1, 2])
        XCTAssertEqual(model.focusWord(table: table, clock: 550), 3)
        XCTAssertEqual(model.seekTarget(for: 2, table: table), .word(utteranceID: "u", index: 1))
    }

    func testOldDaemonFallsBackToMeasuredOffsetsOnly() {
        let text = "One two"
        let boundaries = [TeleprompterBoundary(offsetMs: 0, durationMs: 200, text: "One"),
                          TeleprompterBoundary(offsetMs: 400, durationMs: 200, text: "two")]
        let model = TeleprompterAModel(document: TeleprompterRenderCache().document(text: text, wordBoundaries: boundaries),
                                       text: text, column: TeleprompterA.columnWidth)
        XCTAssertEqual(model.focusWord(table: nil, clock: 450), 1)
        XCTAssertEqual(model.seekTarget(for: 1, table: nil), .offset(400))
    }
}
