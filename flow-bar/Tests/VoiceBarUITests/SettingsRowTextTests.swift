import AppKit
@testable import VoiceBarUI
import XCTest

/// V12 row anatomy shared by Settings › Dictionary and › Speech (controls wrap under the text, tooltips only on
/// clipped text) and the helper/warning text tokens that replace `.secondary` (≥ 4.5:1, light and dark).
@MainActor
final class SettingsRowTextTests: XCTestCase {
    // MARK: - Row anatomy (V12)

    func testControlsWrapUnderTheTextOnlyWhenTheTextColumnWouldDropBelowItsMinimum() {
        let controls: CGFloat = 84
        XCTAssertFalse(SettingsRowLayout.wrapsControls(width: 720 - 36, controlsWidth: controls, spacing: 8,
                                                       textMinWidth: SettingsRowLabel.textMinWidth))
        XCTAssertFalse(SettingsRowLayout.wrapsControls(width: 390 - 36, controlsWidth: controls, spacing: 8,
                                                       textMinWidth: SettingsRowLabel.textMinWidth))
        XCTAssertTrue(SettingsRowLayout.wrapsControls(width: 240, controlsWidth: controls, spacing: 8,
                                                      textMinWidth: SettingsRowLabel.textMinWidth))
    }

    func testTooltipOnlyForActuallyClippedText() {
        XCTAssertTrue(ClippingAwareText.isClipped(fullHeight: 48, limitedHeight: 32))
        XCTAssertFalse(ClippingAwareText.isClipped(fullHeight: 32, limitedHeight: 32))
        XCTAssertFalse(ClippingAwareText.isClipped(fullHeight: 32.3, limitedHeight: 32), "sub-pixel rounding")
        XCTAssertEqual(SettingsRowLabel.lineLimit, 2)
    }

    func testRowActionsShowOnHoverSelectionOrFocusAndStayReachable() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/VoiceBarUI/SettingsView.swift"), encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "private func dictionaryEntryCard("))
        let end = try XCTUnwrap(source.range(of: "private func deleteDictionaryEntryButton("))
        let section = String(source[start.lowerBound..<end.lowerBound])
        XCTAssertTrue(section.contains("let showsActions = isSelected || hoveredTermRowID == rowID"))
        XCTAssertTrue(section.contains("|| focusedTermAction?.rowID == rowID"))
        XCTAssertTrue(section.contains("rowActionsVisible: showsActions"), "Copy uses the shared reveal path")
        XCTAssertEqual(section.components(separatedBy: "SettingsRowActionReveal(visible: showsActions)").count - 1, 2,
                       "Edit and Delete use the shared reveal path")
        let reveal = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/VoiceBarUI/SettingsRowActionReveal.swift"), encoding: .utf8)
        let opacity = try XCTUnwrap(reveal.range(of: ".opacity(visible ? 1 : 0)"))
        let hitTesting = try XCTUnwrap(reveal.range(of: ".allowsHitTesting(visible)"))
        let focus = try XCTUnwrap(reveal.range(of: ".focusable(enabled, interactions: .edit)"))
        XCTAssertLessThan(opacity.lowerBound, focus.lowerBound, "focus must remain outside the transparent content")
        XCTAssertLessThan(hitTesting.lowerBound, focus.lowerBound)
        XCTAssertTrue(section.contains(".accessibilityAction(named: \"Edit\")"))
    }

    // MARK: - Helper text contrast (≥ 4.5:1, light and dark)

    func testHelperAndWarningTextMeetFourAndAHalfToOneOnTheWindowBackground() throws {
        for (name, appearanceName, helper, warning) in [
            ("light", NSAppearance.Name.aqua, SettingsPanePalette.helperLight, SettingsPanePalette.warningLight),
            ("dark", NSAppearance.Name.darkAqua, SettingsPanePalette.helperDark, SettingsPanePalette.warningDark),
        ] {
            let appearance = try XCTUnwrap(NSAppearance(named: appearanceName))
            var background = SettingsPanePalette.RGB(0)
            appearance.performAsCurrentDrawingAppearance {
                let color = NSColor.windowBackgroundColor.usingColorSpace(.sRGB)!
                background = SettingsPanePalette.RGB(
                    UInt32((color.redComponent * 255).rounded()) << 16
                        | UInt32((color.greenComponent * 255).rounded()) << 8
                        | UInt32((color.blueComponent * 255).rounded())
                )
            }
            XCTAssertGreaterThanOrEqual(SettingsPanePalette.contrast(helper, background), 4.5, "helper \(name)")
            XCTAssertGreaterThanOrEqual(SettingsPanePalette.contrast(warning, background), 4.5, "warning \(name)")
        }
    }

    func testContrastFormulaMatchesKnownWCAGValues() {
        XCTAssertEqual(SettingsPanePalette.contrast(.init(0x000000), .init(0xFFFFFF)), 21, accuracy: 0.01)
        XCTAssertEqual(SettingsPanePalette.contrast(.init(0x777777), .init(0xFFFFFF)), 4.48, accuracy: 0.01)
    }
}
