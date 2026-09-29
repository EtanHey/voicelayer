import AppKit
import SwiftUI
@testable import VoiceBarUI
import XCTest

/// UXP-3 (UX pass #5, #15): one Copy button with feedback on every surface, and a Last-dictation card that hugs its
/// content. Headless: models, sizes and source pins only. (#7 is the stacked PR above this one.)
@MainActor
final class IconButtonsCopyFeedbackTests: XCTestCase {
    private let t0 = Date(timeIntervalSinceReferenceDate: 1000)

    // MARK: - #5 CopyFeedback, over an explicit clock

    func testCopyShowsTheTickForOneAndAHalfSecondsThenReturnsToIdle() {
        var feedback = CopyFeedback()
        XCTAssertFalse(feedback.isCopied(at: t0))

        feedback.copied(succeeded: true, byPointer: true, at: t0)

        XCTAssertTrue(feedback.isCopied(at: t0.addingTimeInterval(1.49)))
        XCTAssertFalse(feedback.isCopied(at: t0.addingTimeInterval(1.5)))
        feedback.expire(at: t0.addingTimeInterval(1.5))
        XCTAssertEqual(feedback, {
            var idle = CopyFeedback()
            idle.copied(succeeded: true, byPointer: true, at: t0) // same focus-ring memory as `feedback`
            idle.expire(at: t0.addingTimeInterval(1.5))
            return idle
        }())
    }

    func testASecondCopyRestartsTheWindowAndAnOlderExpiryCannotCutItShort() {
        var feedback = CopyFeedback()
        feedback.copied(succeeded: true, byPointer: false, at: t0)
        feedback.copied(succeeded: true, byPointer: false, at: t0.addingTimeInterval(1.0))

        feedback.expire(at: t0.addingTimeInterval(1.5)) // the first copy's timer firing
        XCTAssertTrue(feedback.isCopied(at: t0.addingTimeInterval(2.4)))
        XCTAssertFalse(feedback.isCopied(at: t0.addingTimeInterval(2.5)))
    }

    func testACopyThatNeverReachedThePasteboardClaimsNothing() {
        var feedback = CopyFeedback()
        feedback.copied(succeeded: false, byPointer: true, at: t0)
        XCTAssertFalse(feedback.isCopied(at: t0))
    }

    func testRowsAreTickedIndependently() {
        var feedback = CopyFeedback()
        feedback.copied(key: "row-a", succeeded: true, byPointer: true, at: t0)
        XCTAssertTrue(feedback.isCopied(key: "row-a", at: t0))
        XCTAssertFalse(feedback.isCopied(key: "row-b", at: t0))
    }

    /// The #200 pattern: a pointer click leaves no focus ring behind; focus that arrives by keyboard keeps it.
    func testAPointerCopyHidesTheFocusRingUntilFocusLeaves() {
        var feedback = CopyFeedback()
        feedback.copied(succeeded: true, byPointer: true, at: t0)
        XCTAssertTrue(feedback.hidesFocusRing)
        feedback.focusChanged(to: false)
        XCTAssertFalse(feedback.hidesFocusRing)

        feedback.copied(succeeded: true, byPointer: false, at: t0)
        XCTAssertFalse(feedback.hidesFocusRing, "a keyboard copy keeps its ring")
    }

    func testTheSameCopyButtonServesAllThreeSurfacesWithOneTick() throws {
        XCTAssertGreaterThanOrEqual(CopyFeedbackButton.hitTarget, 24)
        for file in ["NotchHistoryPanel.swift", "DictationCard.swift", "MenuBarPopoverView.swift"] {
            let source = try sourceFile(file)
            XCTAssertTrue(source.contains("CopyFeedbackButton("), "\(file) must use the shared Copy button")
            XCTAssertFalse(source.contains("Image(systemName: \"doc.on.doc\")"), "\(file) still draws its own Copy")
        }
        XCTAssertFalse(
            try sourceFile("NotchHistoryPanel.swift").contains("copyTitle(isCopied: true)"),
            "the notch showed \"Copied ✓\" next to a ✓ glyph: one tick is enough"
        )
    }

    // MARK: - #15 the Last dictation card

    func testTheLastDictationCardHugsAShortTranscript() throws {
        let card = DictationCard(
            entry: RecentTranscriptionEntry(text: "A short synthetic dictation."),
            insertionStatus: .pasted,
            onCopy: { _ in true }
        )
        let host = NSHostingView(rootView: card.frame(width: 520))
        let height = host.fittingSize.height
        XCTAssertLessThanOrEqual(height, 90, "the card is \(height) pt tall for one line: an empty band remains")

        let source = try sourceFile("DictationCard.swift")
        XCTAssertFalse(source.contains(".background(Color(nsColor: .controlBackgroundColor))"),
                       "a card inside the Form's own card")
    }

    private func sourceFile(_ name: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/VoiceBarUI").appendingPathComponent(name)
        return try String(contentsOf: url, encoding: .utf8)
    }
}
