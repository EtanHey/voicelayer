import AppKit
import SwiftUI
@testable import VoiceBarUI
import XCTest

/// U3a: the shared Settings row anatomy (V12) and the contrast of its text and marks, light and dark.
@MainActor
final class SettingsRowAnatomyTests: XCTestCase {
    func testControlsWrapUnderTheTextRatherThanSqueezeIt() {
        XCTAssertFalse(SettingsRowLayout.wrapsControls(width: 472, controlsWidth: 150, spacing: 8, textMinWidth: 160))
        XCTAssertTrue(SettingsRowLayout.wrapsControls(width: 278, controlsWidth: 150, spacing: 8, textMinWidth: 160))
    }

    func testALongRowKeepsTwoLinesThenAnEllipsisAtBothWidths() {
        let long = String(repeating: "A long description that keeps going ", count: 8)
        SettingsRowClippingGuard.check([
            SettingsRowCase(title: "A title long enough to need a second line at the narrow width", description: long,
                            hasLead: true, controls: SettingsRowCase.button("Open System Settings")),
            SettingsRowCase(title: "Short", description: nil, controls: SettingsRowCase.toggle),
        ])
    }

    /// Text keeps 4.5:1 and glyph-only marks 3:1, light and dark. Writes the table to VOICEBAR_U3A_SHOTS when set.
    func testRowTextAndMarksKeepTheirContrastInLightAndDark() throws {
        let table = try SettingsRowClippingGuard.contrastTable()
        if let path = ProcessInfo.processInfo.environment["VOICEBAR_U3A_SHOTS"] {
            let directory = URL(fileURLWithPath: path, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try table.write(to: directory.appendingPathComponent("settings-contrast.md"), atomically: true,
                            encoding: .utf8)
        }
    }
}
