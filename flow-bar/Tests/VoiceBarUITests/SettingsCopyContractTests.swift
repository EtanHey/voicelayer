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
                     "SettingsDiagnosticSummary.historyMetadata(entry)", "result.failureCopyText",
                     "SettingsCopyButton(text: failure", "SettingsCopyButton(text: shortcutCheckFeedback.message",
                     "SettingsCopyButton(text: hotkeyListenerRestartLine.text"] {
            XCTAssertTrue(source.contains(site), site)
        }
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

}
