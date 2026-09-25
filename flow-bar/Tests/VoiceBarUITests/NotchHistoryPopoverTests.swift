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

    func testCopiedFeedbackLastsLongEnoughToRead() {
        XCTAssertGreaterThanOrEqual(NotchHistoryPresentation.copiedFeedbackDuration, .milliseconds(1200))
        XCTAssertLessThanOrEqual(NotchHistoryPresentation.copiedFeedbackDuration, .seconds(3))
    }
}
