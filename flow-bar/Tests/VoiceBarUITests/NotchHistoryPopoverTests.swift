import AppKit
@testable import VoiceBarUI
import XCTest

/// R4 UI pass #13 + spec §4 wording: the notch History popover had no time per row (only "Latest"), no sign
/// that Copy worked, no way to the full History, and nothing saying Paste types into the app behind it.
final class NotchHistoryPopoverTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    func testRowHeaderIsTimeAndLength() throws {
        let receipt = try XCTUnwrap(DictationReceipt(
            audioDurationMilliseconds: 13400,
            processingDurationMilliseconds: 900
        ))
        let dated = RecentTranscriptionEntry(
            text: "a",
            dictationReceipt: receipt,
            createdAt: now.addingTimeInterval(-120)
        )
        XCTAssertEqual(NotchHistoryPresentation.rowHeader(for: dated, now: now), "2 min ago · 0:13")

        let noReceipt = RecentTranscriptionEntry(text: "b", createdAt: now.addingTimeInterval(-10))
        XCTAssertEqual(NotchHistoryPresentation.rowHeader(for: noReceipt, now: now), "Just now")

        let legacy = RecentTranscriptionEntry(text: "c")
        XCTAssertNil(NotchHistoryPresentation.rowHeader(for: legacy, now: now),
                     "an entry saved before times were recorded shows no header rather than a wrong one")
    }

    func testLongRecordingsShowMinutes() throws {
        let receipt = try XCTUnwrap(DictationReceipt(
            audioDurationMilliseconds: 135_000,
            processingDurationMilliseconds: 900
        ))
        let entry = RecentTranscriptionEntry(
            text: "a",
            dictationReceipt: receipt,
            createdAt: now.addingTimeInterval(-7200)
        )
        XCTAssertEqual(NotchHistoryPresentation.rowHeader(for: entry, now: now), "2 hr ago · 2:15")
    }

    func testCopyFeedbackAndPlainCopy() {
        XCTAssertEqual(NotchHistoryPresentation.copyTitle(isCopied: false), "Copy")
        XCTAssertEqual(NotchHistoryPresentation.copyTitle(isCopied: true), "Copied ✓")
        XCTAssertEqual(NotchHistoryPresentation.openHistoryTitle, "Open History…")
        XCTAssertEqual(NotchHistoryPresentation.pasteHint, "Paste types into the app you were using.")
    }

    /// CodeRabbit (#161, 4100349296): copying the same row twice within 1.5 s let the first timer clear
    /// "Copied ✓" early. Each copy gets a generation; only the latest one's expiry clears it.
    func testASecondCopyKeepsItsOwnFeedbackWindow() {
        var feedback = NotchHistoryCopyFeedback()
        let first = feedback.copied(row: "a")
        let second = feedback.copied(row: "a")
        XCTAssertTrue(feedback.isCopied(row: "a"))

        feedback.expire(first)
        XCTAssertTrue(feedback.isCopied(row: "a"), "the older timer must not clear the newer copy")
        feedback.expire(second)
        XCTAssertFalse(feedback.isCopied(row: "a"))

        let other = feedback.copied(row: "b")
        XCTAssertFalse(feedback.isCopied(row: "a"))
        XCTAssertTrue(feedback.isCopied(row: "b"))
        feedback.expire(other)
        XCTAssertFalse(feedback.isCopied(row: "b"))
    }

    /// CodeRabbit (#161, 4100349275): "Copied ✓" showed even when nothing reached the pasteboard.
    func testCopyReportsWhetherThePasteboardTookTheText() {
        let state = VoiceState()
        var pasteboard: String?
        state.pasteboardWriter = { pasteboard = $0 }
        state.pasteboardStringProvider = { pasteboard }

        XCTAssertTrue(state.copyTranscript("  kept words "))
        XCTAssertEqual(pasteboard, "kept words")
        XCTAssertFalse(state.copyTranscript("   "), "nothing to copy")

        state.pasteboardWriter = { _ in }
        pasteboard = "something else"
        XCTAssertFalse(state.copyTranscript("new words"), "the write didn't land")
    }

    func testCopiedFeedbackLastsLongEnoughToRead() {
        XCTAssertGreaterThanOrEqual(NotchHistoryPresentation.copiedFeedbackDuration, .milliseconds(1200))
        XCTAssertLessThanOrEqual(NotchHistoryPresentation.copiedFeedbackDuration, .seconds(3))
    }
}
