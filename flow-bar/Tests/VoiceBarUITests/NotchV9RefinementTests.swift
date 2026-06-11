import CoreGraphics
@testable import VoiceBarUI
import XCTest

/// v9 (corrected) refinements — Etan-approved build (override 2026-06-11).
///   #1 corners: attached-panel corners get a SLIGHT few-px softening, NOT the funnel.
///   #2/#3 layout: live indicators flank the camera island (reserved island gap).
///   bigger stop: the ◼ stop button is visibly larger than a standard pill button.
final class NotchV9RefinementTests: XCTestCase {
    // MARK: - #1 corner softening (few px, not square, not funnel)

    func testAttachedCornerRadiusIsSmallNonZeroSoftening() {
        XCTAssertGreaterThan(Theme.notchAttachedCornerRadius, 0)
        XCTAssertLessThanOrEqual(Theme.notchAttachedCornerRadius, 6)
    }

    func testAttachedSofteningIsSmallerThanFreeStandingRounding() {
        XCTAssertLessThan(Theme.notchAttachedCornerRadius, Theme.notchCornerRadius)
    }

    func testNotchShapeAppliesSofteningWhenPanelAttached() {
        XCTAssertEqual(
            NotchShape.cornerRadius(hasAttachedPanel: true, rectHeight: 200),
            Theme.notchAttachedCornerRadius, accuracy: 0.001
        )
        XCTAssertEqual(
            NotchShape.cornerRadius(hasAttachedPanel: false, rectHeight: 200),
            Theme.notchCornerRadius, accuracy: 0.001
        )
    }

    func testNotchShapeCornerRadiusNeverExceedsHalfHeight() {
        XCTAssertLessThanOrEqual(NotchShape.cornerRadius(hasAttachedPanel: false, rectHeight: 6), 3)
    }

    // MARK: - #2 flanking: recording reserves the island gap

    func testRecordingWidthAccommodatesIslandPlusTwoWings() {
        let width = Theme.pillContentWidth(for: .recording, statusText: "Listening")
        // Must fit the camera island gap plus a wing on each side.
        XCTAssertGreaterThan(width, Theme.notchIslandWidth + 80)
    }

    func testIslandWidthIsPositive() {
        XCTAssertGreaterThan(Theme.notchIslandWidth, 0)
    }

    // MARK: - bigger stop

    func testStopButtonIsLargerThanStandardPillButton() {
        XCTAssertGreaterThan(Theme.stopButtonSize, Theme.pillActionButtonSize)
    }

    func testStopButtonGlyphIsLargerThanStandardPillGlyph() {
        XCTAssertGreaterThan(Theme.stopButtonGlyphSize, 11)
    }
}
