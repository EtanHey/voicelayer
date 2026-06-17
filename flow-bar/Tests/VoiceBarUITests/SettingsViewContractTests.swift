@testable import VoiceBarUI
import XCTest

final class SettingsViewContractTests: XCTestCase {
    func testSettingsSourceDoesNotExposeStandalonePositionLock() throws {
        let source = try settingsViewSource()

        XCTAssertFalse(source.contains("Lock position"))
        XCTAssertFalse(source.contains("isPositionLocked"))
        XCTAssertFalse(source.contains("onSetPositionLocked"))
    }

    func testDictionaryTabUsesCanonicalCardSurface() throws {
        let source = try settingsViewSource()

        XCTAssertTrue(source.contains("dictionaryEntryCard"))
        XCTAssertTrue(source.contains("variantChips"))
        XCTAssertFalse(source.contains("Section(\"Find\")"))
        XCTAssertFalse(source.contains("Section(\"Prompt Terms\")"))
        XCTAssertFalse(source.contains("DisclosureGroup"))
    }

    func testDictionaryAddAndSearchAppearBeforeCanonicalCards() throws {
        let source = try settingsViewSource()
        let addRange = try XCTUnwrap(source.range(of: "addTermRow"))
        let searchRange = try XCTUnwrap(source.range(of: "searchRow"))
        let cardRange = try XCTUnwrap(source.range(of: "dictionaryEntryCard"))
        let addVariantRange = try XCTUnwrap(source.range(of: "addVariantInlineEditor"))

        XCTAssertLessThan(addRange.lowerBound, searchRange.lowerBound)
        XCTAssertLessThan(searchRange.lowerBound, cardRange.lowerBound)
        XCTAssertLessThan(cardRange.lowerBound, addVariantRange.lowerBound)
    }

    func testSettingsAnchorUsesOneToggleAndTopBottomPicker() throws {
        let source = try settingsViewSource()

        XCTAssertTrue(source.contains("Toggle(\"Anchor\""))
        XCTAssertTrue(source.contains("Picker(\"Position\""))
        XCTAssertFalse(source.contains("Picker(\"Anchor\""))
    }

    func testAudioTabIncludesPerformanceEffortPicker() throws {
        let source = try settingsViewSource()

        XCTAssertTrue(source.contains("Section(\"Performance\")"))
        XCTAssertTrue(source.contains("Picker(\"Effort\""))
        XCTAssertTrue(source.contains("Fast"))
        XCTAssertTrue(source.contains("Balanced"))
        XCTAssertTrue(source.contains("Accurate"))
        XCTAssertTrue(source.contains("onSelectPerformanceEffort"))
    }

    func testGeneralTabShowsGranularPermissionAndRelayRows() throws {
        let source = try settingsViewSource()

        XCTAssertTrue(source.contains("permissionRow"))
        XCTAssertTrue(source.contains("Microphone"))
        XCTAssertTrue(source.contains("Privacy_Microphone"))
        XCTAssertTrue(source.contains("Section(\"Permissions & Hotkey Setup\")"))
        XCTAssertTrue(source.contains("Relay (hidutil LaunchAgent)"))
        XCTAssertTrue(source.contains("runRelaySetup"))
        XCTAssertTrue(source.contains(".disabled(relaySetupRunning)"))
        XCTAssertFalse(source.contains("Section(\"Karabiner\")"))
    }

    func testDictionaryTextFieldsUseVisibleDictionaryFieldTreatment() throws {
        let source = try settingsViewSource()
        let visibleFieldCount = source.components(separatedBy: ".dictionaryTextField()").count - 1

        XCTAssertGreaterThanOrEqual(visibleFieldCount, 3)
    }

    private func settingsViewSource() throws -> String {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let settingsURL = repoRoot
            .appendingPathComponent("flow-bar")
            .appendingPathComponent("Sources")
            .appendingPathComponent("VoiceBarUI")
            .appendingPathComponent("SettingsView.swift")
        return try String(contentsOf: settingsURL)
    }
}
