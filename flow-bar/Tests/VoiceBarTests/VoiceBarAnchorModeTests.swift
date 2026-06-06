@testable import VoiceBar
@testable import VoiceBarUI
import XCTest

final class VoiceBarAnchorModeTests: XCTestCase {
    func testAnchorPreferencesPersistDefaultModeWhenMissing() {
        let suiteName = "VoiceBarAnchorModeTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)

        let preferences = VoiceBarAnchorPreferences(defaults: defaults)

        XCTAssertEqual(preferences.loadAnchorMode(), .follow)
        XCTAssertEqual(defaults.string(forKey: VoiceBarAnchorPreferences.anchorModeKey), VoiceBarAnchorMode.follow.rawValue)
    }

    func testAnchorPreferencesPersistSelectedModeAndLock() {
        let suiteName = "VoiceBarAnchorModeTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let preferences = VoiceBarAnchorPreferences(defaults: defaults)

        preferences.saveAnchorMode(.bottomCenter)
        preferences.savePositionLocked(true)

        XCTAssertEqual(preferences.loadAnchorMode(), .bottomCenter)
        XCTAssertTrue(preferences.loadPositionLocked())
        XCTAssertEqual(defaults.string(forKey: VoiceBarAnchorPreferences.anchorModeKey), VoiceBarAnchorMode.bottomCenter.rawValue)
    }

    func testVoiceBarDefaultsSupportsIsolatedQASuiteAndParallelOverride() {
        let suiteName = "VoiceBarDefaultsTests.\(UUID().uuidString)"
        let defaults = VoiceBarDefaults.make(environment: [
            VoiceBarDefaults.suiteEnvironmentVariable: suiteName,
        ])
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set("topCenter", forKey: VoiceBarAnchorPreferences.anchorModeKey)

        XCTAssertEqual(
            UserDefaults(suiteName: suiteName)?.string(forKey: VoiceBarAnchorPreferences.anchorModeKey),
            "topCenter"
        )
        XCTAssertFalse(VoiceBarDefaults.shouldEnforceSingleton(environment: [
            VoiceBarDefaults.allowParallelInstanceEnvironmentVariable: "1",
        ]))
        XCTAssertTrue(VoiceBarDefaults.shouldEnforceSingleton(environment: [:]))
        XCTAssertFalse(VoiceBarDefaults.shouldRegisterLaunchServices(environment: [
            VoiceBarDefaults.skipLaunchServicesRegistrationEnvironmentVariable: "1",
        ]))
        XCTAssertTrue(VoiceBarDefaults.shouldRegisterLaunchServices(environment: [:]))
        XCTAssertFalse(VoiceBarDefaults.shouldPromptForPermissions(environment: [
            VoiceBarDefaults.skipPermissionPromptsEnvironmentVariable: "1",
        ]))
        XCTAssertTrue(VoiceBarDefaults.shouldPromptForPermissions(environment: [:]))
        XCTAssertFalse(VoiceBarDefaults.shouldStartHotkey(environment: [
            VoiceBarDefaults.skipHotkeyEnvironmentVariable: "1",
        ]))
        XCTAssertTrue(VoiceBarDefaults.shouldStartHotkey(environment: [:]))
    }

    func testAnchorModeDefaultsToFollowWhenMissingOrUnknown() {
        XCTAssertEqual(VoiceBarAnchorMode(defaultsValue: nil), .follow)
        XCTAssertEqual(VoiceBarAnchorMode(defaultsValue: "wide-orange"), .follow)
    }

    func testBottomCenterAnchorUsesCenteredXAndDockClearedYOffset() {
        let visibleFrame = CGRect(x: 40, y: 80, width: 1440, height: 900)
        let pillSize = CGSize(width: 190, height: 50)

        let placement = VoiceBarAnchorMode.bottomCenter.placement(
            visibleFrame: visibleFrame,
            pillSize: pillSize
        )

        XCTAssertEqual(placement.horizontalOffset, 0.5, accuracy: 0.001)
        XCTAssertEqual(placement.verticalOffset ?? -1, (24 + (pillSize.height / 2)) / visibleFrame.height, accuracy: 0.001)
        XCTAssertFalse(placement.followsMouse)
    }

    func testFollowAnchorKeepsLegacyTopCenterMouseFollowing() {
        let placement = VoiceBarAnchorMode.follow.placement(
            visibleFrame: CGRect(x: 0, y: 0, width: 1000, height: 800),
            pillSize: CGSize(width: 190, height: 50)
        )

        XCTAssertEqual(placement.horizontalOffset, 0.5, accuracy: 0.001)
        XCTAssertNil(placement.verticalOffset)
        XCTAssertTrue(placement.followsMouse)
    }

}
