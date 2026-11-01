import AppKit
import SwiftUI
@testable import VoiceBarUI
import XCTest

@MainActor
final class SettingsCopyContractTests: XCTestCase {
    private let sourceRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources/VoiceBarUI")

    func testProductionCopySitesKeepCanonicalTermsAndFullFeedback() throws {
        let source = try String(contentsOf: sourceRoot.appendingPathComponent("SettingsView.swift"))
        for site in ["SettingsCopyButton(text: entry.canonical", "SettingsDiagnosticSummary.build(",
                     "result.failureCopyText",
                     "SettingsCopyButton(text: failure", "SettingsCopyButton(text: shortcutCheckFeedback.message",
                     "SettingsCopyButton(text: hotkeyListenerRestartLine.text",
                     "SettingsCopyButton(text: failure, label: \"processing error\")"] {
            XCTAssertTrue(source.contains(site), site)
        }
        let details = try String(contentsOf: sourceRoot.appendingPathComponent("SettingsHistoryDiagnosticsView.swift"))
        XCTAssertTrue(details.contains("SettingsDiagnosticSummary.historyMetadata(entry)"))
        let header = try XCTUnwrap(source.range(of: "private func dictionaryEntryHeader"))
        let body = source[header.lowerBound...]
        XCTAssertLessThan(try XCTUnwrap(body.range(of: "SettingsCopyButton(text: entry.canonical")).lowerBound,
                          try XCTUnwrap(body.range(of: "if isEditable")).lowerBound,
                          "Included terms must have Copy too")
        XCTAssertFalse(source.contains("Copy question"))
    }

    func testInstallerReportRetainsFullOutputForCopy() throws {
        let source = try String(contentsOf: sourceRoot.appendingPathComponent("SettingsRelaySetupFeedback.swift"))
        XCTAssertTrue(source.contains("installerOutput"))
        XCTAssertTrue(source.contains("failureCopyText"))
    }
    func testExactPayloadsUseARealIsolatedPasteboardAndEmptyDoesNotClearIt() throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        for payload in ["  two word term  ", "שלום 👋🏽 e\u{301}",
                        "first error\nsecond error\n" + String(repeating: "details ", count: 300),
                        "voicelayer daemon --port 8880"] {
            XCTAssertTrue(SettingsCopyPayload.write(payload, to: board))
            XCTAssertEqual(Data(try XCTUnwrap(board.string(forType: .string)).utf8), Data(payload.utf8))
        }
        let before = board.changeCount
        XCTAssertFalse(SettingsCopyPayload.write(nil, to: board))
        XCTAssertFalse(SettingsCopyPayload.write(" \n ", to: board))
        XCTAssertEqual(board.changeCount, before)
        XCTAssertEqual(board.string(forType: .string), "voicelayer daemon --port 8880")
    }

    func testRenderingACommandDoesNotCopyOrInvokeAnything() {
        var calls = 0
        let host = NSHostingView(rootView: SettingsCopyButton(text: "voicelayer daemon", label: "daemon command", onCopy: { _ in
            calls += 1
            return true
        }))
        host.frame = NSRect(x: 0, y: 0, width: 250, height: 50)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(calls, 0)
        let source = try? String(contentsOf: sourceRoot.appendingPathComponent("SettingsDiagnosticSummary.swift"))
        XCTAssertFalse(source?.contains("Process(") ?? true)
        XCTAssertFalse(source?.contains("git rev-parse") ?? true)
    }

    func testFullInstallerOutputSurvivesTheConciseVisibleLine() throws {
        let output = "first diagnostic\nשלום 👋\n" + String(repeating: "long detail\n", count: 80) + "last error\n"
        let result = SettingsRelaySetupResult.installerRun(exitCode: 7, output: output,
                                                        missingAfter: [], finishedAt: Date())
        XCTAssertEqual(result.installerOutput, output)
        XCTAssertTrue(try XCTUnwrap(result.failureCopyText).hasSuffix(output))
        XCTAssertTrue(SettingsRelaySetupFeedback.line(for: result, action: .setUp).contains("last error"))
        XCTAssertFalse(SettingsRelaySetupFeedback.line(for: result, action: .setUp).contains("first diagnostic"))
        XCTAssertNil(SettingsRelaySetupResult.installerRun(exitCode: 0, output: output,
                                                         missingAfter: [], finishedAt: Date()).failureCopyText)
        let attention = SettingsRelaySetupResult.installerRun(exitCode: 0, output: output,
                                                             missingAfter: ["relay missing"], finishedAt: Date())
        XCTAssertTrue(try XCTUnwrap(attention.failureCopyText).contains("relay missing"))
        XCTAssertTrue(try XCTUnwrap(attention.failureCopyText).hasSuffix(output))
    }

    func testBuildIdentityComesFromBundleAndDaemonRemainsUnknown() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".bundle")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let info = ["CFBundleIdentifier": "test.copy.fixture", "CFBundleShortVersionString": "1.2.3",
                    "CFBundleVersion": "42", "GitCommit": "bundle-commit"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: directory.appendingPathComponent("Info.plist"))
        let bundle = try XCTUnwrap(Bundle(url: directory))
        let models = ModelsSettingsState(healthEvent: ["type": "health", "recording_state": "idle",
            "model_status": ["configured_model": ["name": "configured-model", "installed": true],
                             "residency": "loaded", "active_model": "external-model",
                             "configured_effort": "fast", "active_effort": "accurate"]])
        let summary = SettingsDiagnosticSummary.build(bundle: bundle, models: models)
        for fact in ["1.2.3 (build 42)", "App commit: bundle-commit", "Daemon identity: Unknown (not reported)",
                     "Configured model: configured-model", "Active model: external-model",
                     "Configured effort: fast", "Active effort: accurate"] {
            XCTAssertTrue(summary.contains(fact), fact)
        }
        XCTAssertTrue(SettingsDiagnosticSummary.build(models: .disconnected).contains("Daemon identity: Unknown"))
    }

    func testHistoryCopyPreservesFactsAndOmitsTranscriptAndAudioPath() {
        let entry = SettingsHistoryEntry(id: "id", dayKey: "day", recordingID: "recording", createdAt: Date(timeIntervalSince1970: 0),
                                        transcript: "DO_NOT_COPY_TRANSCRIPT", audioPath: URL(fileURLWithPath: "/PRIVATE_AUDIO/audio.wav"),
                                        durationMs: 12345, modelLabel: "saved-model", performanceEffort: .balanced,
                                        inputDeviceLabel: "Fixture microphone")
        let text = SettingsDiagnosticSummary.historyMetadata(entry)
        for fact in ["saved-model", "balanced", "Fixture microphone", "12345"] { XCTAssertTrue(text.contains(fact)) }
        XCTAssertFalse(text.contains(entry.transcript))
        XCTAssertFalse(text.contains("PRIVATE_AUDIO"))
    }

    func testAskQuestionNeverGainsCopyEvenWhenStoredTextExists() {
        let part = SettingsHistoryMediaPart(role: .question, displayText: "Stored question", isPlaceholder: false,
                                           actionableText: nil, audioPath: nil, durationLabel: nil, transcribedDurationLabel: nil)
        XCTAssertEqual(part.actions, [.play])
    }

    func testDisconnectedProcessingNoticeDoesNotOfferCopyForHiddenText() throws {
        XCTAssertEqual(try processingNoticePixels(state: .disconnected, notice: nil),
                       try processingNoticePixels(state: .disconnected, notice: "Hidden processing failure"))
    }

    func testNoPolishControlsDoesNotOfferCopyForHiddenText() throws {
        let state = processingState(withControls: false)
        XCTAssertEqual(state.availability, .available)
        XCTAssertNil(state.polishControls)
        XCTAssertEqual(try processingNoticePixels(state: state, notice: nil),
                       try processingNoticePixels(state: state, notice: "Hidden processing failure"))
    }

    func testSupportedProcessingNoticeRemainsVisible() throws {
        let state = processingState(withControls: true)
        XCTAssertNotNil(state.polishControls)
        XCTAssertNotEqual(try processingNoticePixels(state: state, notice: nil),
                          try processingNoticePixels(state: state, notice: "Visible processing failure"))
    }

    private func processingState(withControls: Bool) -> ModelsSettingsState {
        var health: [String: Any] = ["type": "health", "recording_state": "idle",
            "model_status": ["configured_model": ["name": "fixture-model", "installed": true],
                             "residency": "loaded", "configured_effort": "accurate"]]
        if withControls {
            health["polish_controls"] = [
                "model_polish": ["source": "default", "raw": NSNull(), "effective": "off"],
                "outro_gate": ["source": "default", "raw": NSNull(), "effective": true],
                "smart_chunks": ["source": "default", "raw": NSNull(), "effective": false],
            ]
        }
        return ModelsSettingsState(healthEvent: health)
    }

    private func processingNoticePixels(state: ModelsSettingsState, notice: String?) throws -> Data {
        let view = SettingsView(hotkeyEnabled: true, missingPermissions: [], availableDevices: { [] },
                                selectedDeviceID: { nil }, modelsStatus: { state }, onRefreshModelsStatus: {},
                                processingNotice: { notice }, vocabularyRevision: { 0 }, initialTab: .transcription)
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 780, height: 620)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        return Data(bytes: try XCTUnwrap(bitmap.bitmapData), count: bitmap.bytesPerRow * bitmap.pixelsHigh)
    }

}
