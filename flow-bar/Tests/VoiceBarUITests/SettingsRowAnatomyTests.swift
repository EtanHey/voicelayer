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

    private static let long = String(repeating: "A long description that keeps going ", count: 8)

    func testTheGuardPassesAWellFormedRowAtBothWidths() {
        SettingsRowClippingGuard.check("well-formed row") { _ in
            SettingsRow(title: "A title long enough to need a second line at the narrow width", description: Self.long,
                        lead: { SettingsSetupMark(isDone: false) }) { SettingsRowCase.button("Open System Settings") }
        }
    }

    /// Fail-first: each deliberately clipped text must come back RED from the rendered check.
    func testTheGuardGoesRedOnDeliberatelyClippedRows() {
        let font = SettingsRowLabel.descriptionFont
        let width = SettingsRowClippingGuard.rowWidth(window: 390)
        let broken: [(String, AnyView)] = [
            ("head truncation", AnyView(Text(Self.long).font(font).lineLimit(2).truncationMode(.head)
                .fixedSize(horizontal: false, vertical: true).settingsTextAudit(Self.long, font: font))),
            ("one-line clip", AnyView(Text(Self.long).font(font).lineLimit(1)
                .fixedSize(horizontal: false, vertical: true).settingsTextAudit(Self.long, font: font))),
            ("third line", AnyView(Text(Self.long).font(font).lineLimit(3)
                .fixedSize(horizontal: false, vertical: true).settingsTextAudit(Self.long, font: font))),
            ("horizontal crop", AnyView(Text(Self.long).font(font).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                .frame(width: width).settingsTextAudit(Self.long, font: font)
                .frame(width: width * 0.55, alignment: .leading).clipped()
                .frame(width: width, alignment: .leading))),
        ]
        for (name, view) in broken {
            let found = SettingsRowClippingGuard.violations(in: view, width: width)
            print("U3a-RED \(name): \(found)")
            XCTAssertFalse(found.isEmpty, "the guard missed a \(name)")
        }
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
