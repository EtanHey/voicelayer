@testable import VoiceBarUI
import XCTest

/// C13 (QA recording 2026-09-25): after Reinstall there was no telling whether it did anything. On main the line
/// read the probe summary alone ("Relay ready: LaunchAgent loaded, F5 + Dictation map to F18."), identical before
/// and after, with no action and no time; a failure was only coloured by the live status, not by the run.
final class SettingsRelaySetupFeedbackTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.locale = Locale(identifier: "en_GB")
        return calendar
    }

    private let finishedAt = Date(timeIntervalSince1970: 1_790_000_000) // 14:13:20 UTC

    func testAReinstallThatWorkedSaysWhatRanWhatIsTrueNowAndWhen() {
        let result = SettingsRelaySetupResult.installerRun(
            exitCode: 0, output: "Installed com.voicelayer.f5-to-f18-hidutil\n", missingAfter: [],
            finishedAt: finishedAt
        )
        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(
            SettingsRelaySetupFeedback.line(for: result, action: .reinstall, calendar: calendar),
            "Reinstalled · helper running · F5 and 🎤 mapped to F18 · checked 14:13"
        )
        XCTAssertEqual(
            SettingsRelaySetupFeedback.line(for: result, action: .setUp, calendar: calendar),
            "Set up · helper running · F5 and 🎤 mapped to F18 · checked 14:13"
        )
    }

    func testAnInstallerThatExitedZeroButLeftTheRelayBrokenIsNotASuccess() {
        let result = SettingsRelaySetupResult.installerRun(
            exitCode: 0, output: "", missingAfter: ["LaunchAgent not loaded", "F5 to F18 mapping missing"],
            finishedAt: finishedAt
        )
        XCTAssertFalse(result.succeeded)
        XCTAssertEqual(
            SettingsRelaySetupFeedback.line(for: result, action: .reinstall, calendar: calendar),
            "Reinstalled, but not working · LaunchAgent not loaded, F5 to F18 mapping missing · checked 14:13"
        )
    }

    func testAFailedInstallerSaysFailedWithItsLastWord() {
        let result = SettingsRelaySetupResult.installerRun(
            exitCode: 1,
            output: "cp: something\nERROR: plist template not found: /x/launchd/y.plist\n\n",
            missingAfter: [], finishedAt: finishedAt
        )
        XCTAssertFalse(result.succeeded, "a non-zero exit is a failure even if the old relay still reads ready")
        XCTAssertEqual(
            SettingsRelaySetupFeedback.line(for: result, action: .reinstall, calendar: calendar),
            "Reinstall failed · installer exited 1: ERROR: plist template not found: /x/launchd/y.plist · 14:13"
        )
        let silent = SettingsRelaySetupResult.installerRun(
            exitCode: 5, output: "  \n", missingAfter: [], finishedAt: finishedAt
        )
        XCTAssertEqual(
            SettingsRelaySetupFeedback.line(for: silent, action: .setUp, calendar: calendar),
            "Set up failed · installer exited 5 · 14:13"
        )
    }

    func testWhileRunningTheLineNamesTheAction() {
        XCTAssertEqual(SettingsRelaySetupFeedback.running(.reinstall), "Reinstalling…")
        XCTAssertEqual(SettingsRelaySetupFeedback.running(.setUp), "Setting up…")
    }

    /// The feedback's colour follows the run's own outcome, not the live remap probe (which can read ready from the
    /// previous install while this one failed).
    func testTheFeedbackLineIsColouredByTheRunNotByTheLiveProbe() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Sources/VoiceBarUI/SettingsView.swift"),
            encoding: .utf8
        )
        XCTAssertFalse(source.contains(".foregroundStyle(isHotkeyRemapActive() ? Color.secondary : Color.red)"))
        XCTAssertTrue(source.contains("SettingsRelaySetupFeedback.line(for: result, action: action)"))
    }
}
