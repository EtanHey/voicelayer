@testable import VoiceBarUI
import XCTest

final class SettingsViewContractTests: XCTestCase {
    func testSettingsSourceDoesNotExposeStandalonePositionLock() throws {
        let source = try settingsViewSource()

        XCTAssertFalse(source.contains("Lock position"))
        XCTAssertFalse(source.contains("isPositionLocked"))
        XCTAssertFalse(source.contains("onSetPositionLocked"))
    }

    func testDictionaryTabUsesOneCoherentDictionarySection() throws {
        let source = try settingsViewSource()

        XCTAssertTrue(source.contains("Section(\"Dictionary\")"))
        XCTAssertFalse(source.contains("Section(\"Find\")"))
        XCTAssertFalse(source.contains("Section(\"Prompt Terms\")"))
    }

    func testDictionaryAddFormAppearsBeforeCollapsibleCorrectionsList() throws {
        let source = try settingsViewSource()
        let editorRange = try XCTUnwrap(source.range(of: "correctionEditor"))
        let disclosureRange = try XCTUnwrap(source.range(of: "DisclosureGroup"))
        let searchRange = try XCTUnwrap(source.range(of: "TextField(\"Search corrections and terms\""))
        let promptTermsRange = try XCTUnwrap(source.range(of: "promptTermsList"))

        XCTAssertLessThan(editorRange.lowerBound, disclosureRange.lowerBound)
        XCTAssertLessThan(disclosureRange.lowerBound, searchRange.lowerBound)
        XCTAssertLessThan(disclosureRange.lowerBound, promptTermsRange.lowerBound)
    }

    func testSettingsAnchorUsesOneToggleAndTopBottomPicker() throws {
        let source = try settingsViewSource()

        XCTAssertTrue(source.contains("Toggle(\"Anchor\""))
        XCTAssertTrue(source.contains("Picker(\"Position\""))
        XCTAssertFalse(source.contains("Picker(\"Anchor\""))
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
