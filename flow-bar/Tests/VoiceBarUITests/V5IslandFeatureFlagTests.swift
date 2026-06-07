@testable import VoiceBarUI
import XCTest

final class V5IslandFeatureFlagTests: XCTestCase {
    func testDefaultsToEnabledForDogfoodWhenNoSettingOrEnvironmentOverrideExists() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "voicebar.v5.flag.tests.default"))
        defaults.removePersistentDomain(forName: "voicebar.v5.flag.tests.default")

        XCTAssertTrue(V5IslandFeatureFlag.isEnabled(defaults: defaults, environment: [:]))
    }

    func testEnvironmentOverrideWinsOverStoredSetting() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "voicebar.v5.flag.tests.env"))
        defaults.removePersistentDomain(forName: "voicebar.v5.flag.tests.env")
        V5IslandFeatureFlag.setEnabled(true, defaults: defaults)

        XCTAssertFalse(V5IslandFeatureFlag.isEnabled(
            defaults: defaults,
            environment: [V5IslandFeatureFlag.environmentKey: "0"]
        ))
        XCTAssertTrue(V5IslandFeatureFlag.isEnabled(
            defaults: defaults,
            environment: [V5IslandFeatureFlag.environmentKey: "true"]
        ))
    }

    func testStoredSettingControlsWhenEnvironmentIsAbsent() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "voicebar.v5.flag.tests.stored"))
        defaults.removePersistentDomain(forName: "voicebar.v5.flag.tests.stored")

        V5IslandFeatureFlag.setEnabled(false, defaults: defaults)
        XCTAssertFalse(V5IslandFeatureFlag.isEnabled(defaults: defaults, environment: [:]))

        V5IslandFeatureFlag.setEnabled(true, defaults: defaults)
        XCTAssertTrue(V5IslandFeatureFlag.isEnabled(defaults: defaults, environment: [:]))
    }
}
