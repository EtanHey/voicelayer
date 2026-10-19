@testable import VoiceBarUI
import XCTest

/// SETUI1 (Etan, 2026-10-19): "the recognizer now says accurate accurate on active effort and configured
/// effort, which is stupid." A matching configured/active pair is one row; the pair shows only when the two
/// differ or the model is not loaded.
final class RecognizerDetailsDedupeTests: XCTestCase {
    func testMatchingConfiguredAndActiveCollapseToOneRowEach() {
        let rows = ModelsSettingsView.recognizerDetailRows(for: ModelsSettingsState(healthEvent: Self.health()))
        XCTAssertEqual(rows, [
            .init(label: "Model", value: "large-v3-turbo"),
            .init(label: "Effort", value: "Accurate"),
        ])
    }

    func testADifferingPairShowsBoth() {
        let rows = ModelsSettingsView.recognizerDetailRows(for: ModelsSettingsState(healthEvent: Self.health(
            activeModel: "large-v3", activeEffort: "fast"
        )))
        XCTAssertEqual(rows, [
            .init(label: "Configured model", value: "large-v3-turbo"),
            .init(label: "Active model", value: "large-v3"),
            .init(label: "Configured effort", value: "Accurate"),
            .init(label: "Active effort", value: "Fast"),
        ])
    }

    func testOnlyTheDifferingFactSplits() {
        let rows = ModelsSettingsView.recognizerDetailRows(for: ModelsSettingsState(healthEvent: Self.health(
            activeEffort: "balanced"
        )))
        XCTAssertEqual(rows.map(\.label), ["Model", "Configured effort", "Active effort"])
    }

    func testNotLoadedShowsThePairEvenWhenTheNamesMatch() {
        let rows = ModelsSettingsView.recognizerDetailRows(for: ModelsSettingsState(healthEvent: Self.health(
            residency: "not_loaded"
        )))
        XCTAssertEqual(rows.map(\.label), ["Configured model", "Active model", "Configured effort", "Active effort"])
    }

    func testAMissingActiveValueIsNeverCollapsedIntoTheConfiguredOne() {
        var health = Self.health()
        var status = health["model_status"] as! [String: Any]
        status.removeValue(forKey: "active_model")
        status.removeValue(forKey: "active_effort")
        health["model_status"] = status
        let rows = ModelsSettingsView.recognizerDetailRows(for: ModelsSettingsState(healthEvent: health))
        XCTAssertEqual(rows, [
            .init(label: "Configured model", value: "large-v3-turbo"),
            .init(label: "Active model", value: "Unknown"),
            .init(label: "Configured effort", value: "Accurate"),
            .init(label: "Active effort", value: "Unknown"),
        ])
    }

    private static func health(
        residency: String = "loaded",
        activeModel: String = "large-v3-turbo",
        activeEffort: String = "accurate"
    ) -> [String: Any] {
        [
            "type": "health",
            "recording_state": "idle",
            "model_status": [
                "configured_model": ["name": "large-v3-turbo", "size_bytes": 10, "installed": true],
                "residency": residency,
                "active_model": activeModel,
                "configured_effort": "accurate",
                "active_effort": activeEffort,
            ] as [String: Any],
        ]
    }
}
