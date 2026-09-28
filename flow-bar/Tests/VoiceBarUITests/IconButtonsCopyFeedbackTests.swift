import AppKit
import SwiftUI
@testable import VoiceBarUI
import XCTest

/// UXP-3 (UX pass #5, #7, #15): one Copy button with feedback on every surface, a Paste glyph that can't be
/// mistaken for Copy, tooltips and 24 pt targets on Settings' icon buttons, row actions reachable without hover,
/// and a Last-dictation card that hugs its content. Headless: models, sizes and source pins only.
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

    // MARK: - #7 Paste glyph, tooltips, row actions

    func testPasteHasItsOwnGlyphEverywhere() throws {
        XCTAssertFalse(VoiceBarActionSymbol.paste.hasPrefix("doc.on"), "Paste must not read as another Copy")
        XCTAssertNotNil(NSImage(systemSymbolName: VoiceBarActionSymbol.paste, accessibilityDescription: nil))
        XCTAssertEqual(
            NotchHistoryPresentation.rowActions.first { $0.kind == .paste }?.symbol, VoiceBarActionSymbol.paste
        )
        let settings = try sourceFile("SettingsView.swift")
        XCTAssertFalse(settings.contains("\"doc.on.clipboard\""), "Settings still draws the old Paste glyph")
    }

    func testEveryIconOnlySettingsButtonHasATooltipAndA24PointTarget() throws {
        XCTAssertGreaterThanOrEqual(SettingsIconButtonSpec.hitTarget, 24)
        let symbols = Set(SettingsIconButtonSpec.all.map(\.symbol))
        XCTAssertTrue(
            symbols.isSuperset(of: ["arrow.clockwise", "arrow.up.to.line", "xmark.circle.fill"]),
            "the toolbar's Refresh / Jump to latest and the search field's Clear are in the inventory: \(symbols)"
        )
        for spec in SettingsIconButtonSpec.all {
            XCTAssertFalse(spec.help.isEmpty, "\(spec.symbol) has no tooltip")
        }
        let settings = try sourceFile("SettingsView.swift")
        for glyph in ["arrow.clockwise", "arrow.up.to.line", "xmark.circle.fill"] {
            XCTAssertFalse(
                settings.contains("Image(systemName: \"\(glyph)\")"),
                "\(glyph) is still a bare glyph button instead of a SettingsIconButton"
            )
        }
    }

    func testRowActionsAreReachableWithoutHover() throws {
        let withAudio = RecentTranscriptionEntry(text: "Synthetic.", recordingPath: "/synthetic/a.wav")
        let withoutAudio = RecentTranscriptionEntry(text: "Synthetic.")
        XCTAssertEqual(
            NotchHistoryPresentation.accessibilityActions(for: withAudio).map(\.kind), [.copy, .paste, .retranscribe]
        )
        XCTAssertEqual(NotchHistoryPresentation.accessibilityActions(for: withoutAudio).map(\.kind), [.copy, .paste])
        XCTAssertTrue(
            try sourceFile("NotchHistoryPanel.swift")
                .contains("NotchHistoryPresentation.accessibilityActions(for: entry)"),
            "the row must offer its actions to VoiceOver"
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
