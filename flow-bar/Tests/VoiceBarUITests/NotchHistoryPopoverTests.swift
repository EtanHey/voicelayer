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

    func testPanelCopy() {
        XCTAssertEqual(NotchHistoryPresentation.openHistoryTitle, "Open History…")
        XCTAssertEqual(NotchHistoryPresentation.pasteHint, "Paste types into the app you were using.")
    }

    /// CodeRabbit (#161, 4100349296): copying the same row twice within 1.5 s let the first timer clear the tick
    /// early. UXP-3 moved this onto the shared `CopyFeedback`: the tick lasts 1.5 s from the LATEST copy.
    func testASecondCopyKeepsItsOwnFeedbackWindow() {
        let t0 = Date(timeIntervalSinceReferenceDate: 0)
        var feedback = CopyFeedback()
        feedback.copied(key: "a", succeeded: true, byPointer: true, at: t0)
        feedback.copied(key: "a", succeeded: true, byPointer: true, at: t0.addingTimeInterval(1))
        XCTAssertTrue(feedback.isCopied(key: "a", at: t0.addingTimeInterval(1)))

        feedback.expire(at: t0.addingTimeInterval(1.5)) // the first copy's timer
        XCTAssertTrue(feedback.isCopied(key: "a", at: t0.addingTimeInterval(1.5)), "the older timer must not clear it")
        feedback.expire(at: t0.addingTimeInterval(2.5))
        XCTAssertFalse(feedback.isCopied(key: "a", at: t0.addingTimeInterval(2.5)))

        feedback.copied(key: "b", succeeded: true, byPointer: true, at: t0.addingTimeInterval(3))
        XCTAssertFalse(feedback.isCopied(key: "a", at: t0.addingTimeInterval(3)))
        XCTAssertTrue(feedback.isCopied(key: "b", at: t0.addingTimeInterval(3)))
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
        XCTAssertGreaterThanOrEqual(CopyFeedback.duration, 1.2)
        XCTAssertLessThanOrEqual(CopyFeedback.duration, 3)
    }
}
