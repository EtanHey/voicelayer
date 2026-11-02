import Foundation
@testable import VoiceBarUI
import XCTest

final class SettingsVersionFooterTests: XCTestCase {
    func testEveryUpdateStateHasCompactCopyAndRetainsFullStatus() {
        let cases: [(VoiceBarVersionStatus, String, String)] = [
            (.checking, "Checking…", "Checking for updates…"),
            (.latest, "Up to date", "You are on the latest version"),
            (.ahead(latest: "2.2.58"), "Ahead of release", "Newer than the latest release (2.2.58)"),
            (.available("2.2.60"), "Update available", "VoiceBar 2.2.60 is available"),
            (.couldNotCheck, "Check failed", "Could not check for updates"),
        ]
        for (status, compact, full) in cases {
            XCTAssertEqual(status.sidebarMessage, compact)
            XCTAssertEqual(status.message, full)
        }
    }

    func testVersionLivesInSidebarAndGeneralHasNoVersionSection() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/VoiceBarUI")
        let settings = try String(contentsOf: root.appendingPathComponent("SettingsView.swift"), encoding: .utf8)
        let shell = try String(contentsOf: root.appendingPathComponent("SettingsNavigationShell.swift"), encoding: .utf8)
        XCTAssertFalse(settings.contains("versionSection"))
        XCTAssertFalse(settings.contains("Section(\"Version\")"))
        XCTAssertTrue(settings.contains("installedVersion: installedVersion, versionStatus: versionStatus"))
        XCTAssertTrue(shell.contains("VoiceBarStatusIndicator(presentation: footer)"))
        XCTAssertTrue(shell.contains("SettingsVersionFooter(installed: installedVersion, status: versionStatus)"))
        XCTAssertFalse(shell.contains("VoiceBarStatusFooter(presentation:"))
        XCTAssertFalse(shell.contains("footer.privacy"))
        XCTAssertTrue(shell.contains(".lineLimit(1)"))
        XCTAssertTrue(shell.contains(".accessibilityValue(status?.message ?? \"\")"))
    }
}
