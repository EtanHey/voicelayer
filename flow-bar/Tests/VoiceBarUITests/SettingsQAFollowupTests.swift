import Foundation
@testable import VoiceBarUI
import XCTest

/// 2.2.61 Lane B QA follow-ups (qa-session-2026-11-02-0454): one focused guard per finding.
@MainActor
final class SettingsQAFollowupTests: XCTestCase {
    /// QA-05: a radio mark carries the selected state; the row no longer relies on a faint trailing check.
    func testRecognizerSelectionIsARadioMark() throws {
        XCTAssertEqual(RecognizerPickerView.selectionSymbol(isSelected: true), "largecircle.fill.circle")
        XCTAssertEqual(RecognizerPickerView.selectionSymbol(isSelected: false), "circle")
        let source = try Self.source("RecognizerPickerView.swift")
        XCTAssertFalse(source.contains("\"checkmark\""))
    }

    /// QA-27: the Dictionary search has the same clear (X) as the History search, and it empties the query.
    func testDictionarySearchHasAClearButton() throws {
        let source = try Self.source("SettingsView.swift")
        let start = try XCTUnwrap(source.range(of: "private var searchRow: some View {"))
        let end = try XCTUnwrap(source.range(of: "private func dictionaryEntryCard(", range: start.upperBound..<source.endIndex))
        let row = String(source[start.upperBound..<end.lowerBound])
        XCTAssertTrue(row.contains("SettingsIconButton(spec: .clearSearch"))
        XCTAssertTrue(row.contains("dictionarySearch = \"\""))
        XCTAssertTrue(row.contains("if dictionarySearch != \"\""))
        XCTAssertEqual(SettingsIconButtonSpec.clearSearch.help, "Clear search")
    }

    /// QA-30: equal marketing and build versions show one number.
    func testVersionLabelSaysEqualNumbersOnce() {
        XCTAssertEqual(SettingsDiagnosticSummary.versionLabel(version: "2.2.60", build: "2.2.60"), "2.2.60")
        XCTAssertEqual(SettingsDiagnosticSummary.versionLabel(version: "2.2.60", build: "412"), "2.2.60 (build 412)")
        XCTAssertEqual(SettingsDiagnosticSummary.versionLabel(version: nil, build: nil), "Unknown")
    }

    /// QA-32: the sidebar is not "Ready" while the selected recognizer is loading.
    func testFooterSaysLoadingUntilTheSelectedRecognizerIsReady() {
        let loading = VoiceBarFooterPresentation.resolve(
            isConnected: true, mode: .idle, captureLive: false, errorMessage: nil,
            remoteSTTConfigured: false, hasFreshHealth: true, loadingRecognizer: .parakeet)
        XCTAssertEqual(loading.status, "Loading Parakeet…")
        XCTAssertFalse(loading.isReady)
        let ready = VoiceBarFooterPresentation.resolve(
            isConnected: true, mode: .idle, captureLive: false, errorMessage: nil,
            remoteSTTConfigured: false, hasFreshHealth: true)
        XCTAssertEqual(ready.status, "Ready")
    }

    func testFooterReadsTheLoadPhaseFromVoiceState() {
        let voice = RecognizerBindingTests.voice()
        voice.setConnectionStatus(true)
        voice.handleEvent(RecognizerBindingTests.event(1, desired: "parakeet", effective: nil, phase: "loading",
                                                       parakeet: "loading", whisper: "sleeping"))
        XCTAssertEqual(VoiceBarFooterPresentation.loadingRecognizer(voice.recognizerPickerState), .parakeet)
        voice.handleEvent(RecognizerBindingTests.event(2, desired: "parakeet", effective: "parakeet", phase: "ready",
                                                       parakeet: "ready", whisper: "sleeping"))
        XCTAssertNil(VoiceBarFooterPresentation.loadingRecognizer(voice.recognizerPickerState))
        // Loading the other, unselected engine does not hold the sidebar.
        voice.handleEvent(RecognizerBindingTests.event(3, desired: "parakeet", effective: "parakeet", phase: "ready",
                                                       parakeet: "ready", whisper: "loading"))
        XCTAssertNil(VoiceBarFooterPresentation.loadingRecognizer(voice.recognizerPickerState))
    }

    private static func source(_ name: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/VoiceBarUI")
        return try String(contentsOf: root.appendingPathComponent(name), encoding: .utf8)
    }
}
