@testable import VoiceBarUI
import XCTest

/// D1-c / fold-3 review S2: a Dictionary reload that finishes while an edit is open was dropped and never
/// re-queued, so an external change (e.g. `voicelayer vocab` from the CLI) didn't show until the next revision.
final class DictionaryReloadGateTests: XCTestCase {
    func testALoadDuringAnEditIsDeferredAndRunsWhenTheEditEnds() {
        var gate = SettingsView.DictionaryReloadGate()

        XCTAssertFalse(gate.loadFinished(duringEdit: true), "never overwrite the list under an open edit")
        XCTAssertTrue(gate.editEnded(), "the deferred reload runs once the edit ends")
        XCTAssertFalse(gate.editEnded(), "and only once")
    }

    func testALoadWithNoEditAppliesAndLeavesNothingPending() {
        var gate = SettingsView.DictionaryReloadGate()

        XCTAssertTrue(gate.loadFinished(duringEdit: false))
        XCTAssertFalse(gate.editEnded())
    }

    func testALaterCleanLoadClearsAnEarlierDeferral() {
        var gate = SettingsView.DictionaryReloadGate()

        XCTAssertFalse(gate.loadFinished(duringEdit: true))
        XCTAssertTrue(gate.loadFinished(duringEdit: false))
        XCTAssertFalse(gate.editEnded(), "the clean load already brought the list up to date")
    }

    func testTheViewDefersAndReloadsThroughTheGate() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/VoiceBarUI/SettingsView.swift")
        let source = try String(contentsOf: url, encoding: .utf8)

        XCTAssertTrue(source.contains("guard dictionaryReloadGate.loadFinished(duringEdit: hasPendingDictionaryEdit)"))
        XCTAssertTrue(source.contains(".onChange(of: hasPendingDictionaryEdit)"))
        XCTAssertTrue(source.contains("if !pending, dictionaryReloadGate.editEnded()"))
        XCTAssertFalse(source.contains("guard !hasPendingDictionaryEdit else { return }"))
    }
}
