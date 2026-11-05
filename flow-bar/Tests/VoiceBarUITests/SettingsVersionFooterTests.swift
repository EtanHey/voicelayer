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

    /// S1 (Etan, 2026-11-02): "VoiceBar build is here and down here" — one quiet sidebar line, nowhere else.
    func testSidebarLineReadsLikeAStatusBar() {
        let installed = VoiceBarInstalledVersion(version: "2.3.0", commit: "abcdef0123")
        XCTAssertEqual(SettingsVersionFooter.line(installed: installed, status: .latest), "VoiceBar 2.3.0 · Up to date")
        XCTAssertEqual(SettingsVersionFooter.line(installed: installed, status: .available("2.2.62")),
                       "VoiceBar 2.3.0 · Update available")
        XCTAssertEqual(SettingsVersionFooter.line(installed: installed, status: nil), "VoiceBar 2.3.0")
    }

    func testVersionAppearsOnceAcrossSettings() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/VoiceBarUI")
        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("Settings") && $0.pathExtension == "swift" }
        var versionViews = 0
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            XCTAssertFalse(text.contains("\"VoiceBar build\""), file.lastPathComponent)
            XCTAssertFalse(text.contains("value: SettingsDiagnosticSummary.versionLabel()"), file.lastPathComponent)
            versionViews += text.components(separatedBy: "SettingsVersionFooter(installed:").count - 1
        }
        XCTAssertEqual(versionViews, 1, "exactly one on-screen version: the sidebar footer")
    }
}
