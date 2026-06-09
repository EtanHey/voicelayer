@testable import VoiceBar
@testable import VoiceBarUI
import XCTest

final class VoiceBarAnchorModeTests: XCTestCase {
    func testAnchorPreferencesPersistDefaultModeWhenMissing() throws {
        let suiteName = "VoiceBarAnchorModeTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)

        let preferences = VoiceBarAnchorPreferences(defaults: defaults)

        XCTAssertEqual(preferences.loadAnchorMode(), .follow)
        XCTAssertEqual(
            defaults.string(forKey: VoiceBarAnchorPreferences.anchorModeKey),
            VoiceBarAnchorMode.follow.rawValue
        )
    }

    func testAnchorPreferencesPersistSelectedModeAndRemoveLegacyLockState() throws {
        let suiteName = "VoiceBarAnchorModeTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let preferences = VoiceBarAnchorPreferences(defaults: defaults)

        defaults.set(true, forKey: VoiceBarAnchorPreferences.positionLockedKey)
        preferences.saveAnchorMode(.bottomCenter)

        XCTAssertEqual(preferences.loadAnchorMode(), .topCenter)
        XCTAssertEqual(
            defaults.string(forKey: VoiceBarAnchorPreferences.anchorModeKey),
            VoiceBarAnchorMode.topCenter.rawValue
        )
        XCTAssertNil(defaults.object(forKey: VoiceBarAnchorPreferences.positionLockedKey))
    }

    func testAnchorPreferencesMigratesExistingLockKeyOutOfDefaults() throws {
        let suiteName = "VoiceBarAnchorModeTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(VoiceBarAnchorMode.topCenter.rawValue, forKey: VoiceBarAnchorPreferences.anchorModeKey)
        defaults.set(true, forKey: VoiceBarAnchorPreferences.positionLockedKey)
        let preferences = VoiceBarAnchorPreferences(defaults: defaults)

        XCTAssertEqual(preferences.loadAnchorMode(), .topCenter)
        XCTAssertNil(defaults.object(forKey: VoiceBarAnchorPreferences.positionLockedKey))
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

    func testAnchoredModesUseTopNotchPlacement() {
        let visibleFrame = CGRect(x: 40, y: 80, width: 1440, height: 900)
        let pillSize = CGSize(width: 190, height: 50)
        let expectedTopY = visibleFrame.maxY + 22

        for mode in VoiceBarAnchorMode.anchoredPositionModes {
            let placement = mode.placement(
                visibleFrame: visibleFrame,
                pillSize: pillSize
            )
            let minY = visibleFrame.origin.y
                + (visibleFrame.height * (placement.verticalOffset ?? -1))
                - (pillSize.height / 2)

            XCTAssertEqual(placement.horizontalOffset, 0.5, accuracy: 0.001)
            XCTAssertEqual(minY + pillSize.height, expectedTopY, accuracy: 0.001)
            XCTAssertFalse(placement.followsMouse)
        }
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

    func testAnchorModesDefineDragAvailabilityWithoutStandaloneLock() {
        XCTAssertTrue(VoiceBarAnchorMode.follow.allowsFreeDrag)
        XCTAssertFalse(VoiceBarAnchorMode.topCenter.allowsFreeDrag)
        XCTAssertFalse(VoiceBarAnchorMode.bottomCenter.allowsFreeDrag)
    }

    func testAnchorMenuTitlesPresentFollowModeAsOff() {
        XCTAssertEqual(VoiceBarAnchorMode.follow.anchorMenuTitle, "Off")
        XCTAssertEqual(VoiceBarAnchorMode.topCenter.anchorMenuTitle, "Notch Center")
        XCTAssertEqual(VoiceBarAnchorMode.bottomCenter.anchorMenuTitle, "Notch Center")
    }
}
