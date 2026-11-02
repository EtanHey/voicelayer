import AppKit
import SwiftUI
@testable import VoiceBarUI
import XCTest

/// Production Settings views with synthetic health; never replaces the resident app or opens audio.
@MainActor
final class SettingsSlopShotsTests: XCTestCase {
    func testRecognizerReplacesDuplicateRowsAndEffortControl() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let models = try String(contentsOf: root.appendingPathComponent("Sources/VoiceBarUI/ModelsSettingsView.swift"))
        let settings = try String(contentsOf: root.appendingPathComponent("Sources/VoiceBarUI/SettingsView.swift"))
        XCTAssertTrue(models.contains("RecognizerPickerView("))
        for removed in ["Transcription model", "Last dictation used", "Transcription effort", "models-effort-picker",
                        "no measurable word difference"] {
            XCTAssertFalse(models.contains(removed), removed)
        }
        XCTAssertFalse(settings.contains("lastDictationProvenanceLabel"))
        // Historical facts survive in the selected recording's details, never the list row.
        let rowStart = try XCTUnwrap(settings.range(of: "private func recordingHistoryListRow"))
        let detailStart = try XCTUnwrap(settings.range(of: "private func recordingHistoryDetail"))
        XCTAssertFalse(settings[rowStart.lowerBound..<detailStart.lowerBound].contains("entry.performanceEffort"))
        let details = try String(contentsOf: root.appendingPathComponent("Sources/VoiceBarUI/SettingsHistoryDiagnosticsView.swift"))
        XCTAssertTrue(details.contains("entry.modelLabel"))
        XCTAssertTrue(details.contains("entry.performanceEffort?.displayName"))
    }

    func testRenderCleanedSettings() throws {
        guard let path = ProcessInfo.processInfo.environment["VOICEBAR_SETTINGS_SLOP_SHOTS_DIR"] else {
            throw XCTSkip("Set VOICEBAR_SETTINGS_SLOP_SHOTS_DIR to render cleaned settings")
        }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let state = ModelsSettingsState(healthEvent: [
            "type": "health", "recording_state": "idle",
            "model_status": [
                "residency": "loaded", "configured_effort": "accurate",
                "configured_model": ["name": "large-v3-turbo", "size_bytes": 1_617_000_000, "installed": true],
            ],
            "polish_controls": [
                "model_polish": ["source": "default", "raw": NSNull(), "effective": "off"],
                "outro_gate": ["source": "default", "raw": NSNull(), "effective": true],
                "smart_chunks": ["source": "default", "raw": NSNull(), "effective": false],
            ],
        ])
        for tab in [SettingsTab.general, .transcription] {
            for (name, scheme, appearance) in [
                ("light", ColorScheme.light, NSAppearance.Name.aqua),
                ("dark", .dark, .darkAqua),
            ] {
                let view = SettingsView(
                    hotkeyEnabled: true, missingPermissions: [], availableDevices: { [] }, selectedDeviceID: { nil },
                    modelsStatus: { state }, onRefreshModelsStatus: {}, onSelectResidency: { _ in }, vocabularyRevision: { 0 },
                    footerPresentation: { .resolve(isConnected: true, mode: .idle, captureLive: false,
                                                  errorMessage: nil, remoteSTTConfigured: false, hasFreshHealth: true) },
                    initialTab: tab
                )
                try render(view.environment(\.colorScheme, scheme), appearance: NSAppearance(named: appearance),
                           to: directory.appendingPathComponent("\(tab.title.lowercased())-\(name).png"))
            }
        }
    }

    func testRenderCopySurfaces() throws {
        guard let path = ProcessInfo.processInfo.environment["VOICEBAR_SETTINGS_SLOP_SHOTS_DIR"] else {
            throw XCTSkip("Set VOICEBAR_SETTINGS_SLOP_SHOTS_DIR to render Copy surfaces")
        }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let preview = STTVocabularyPreview(updatedAt: nil, entries: [], displayEntries: [
            STTDictionaryDisplayEntry(source: "personal", entry: STTDictionaryEntry(canonical: "שלום world 👋", variants: ["fixture variant"])),
            STTDictionaryDisplayEntry(source: "bundled", entry: STTDictionaryEntry(canonical: "TypeScript", variants: ["type script"])),
        ])
        let failure = SettingsRelaySetupResult.installerRun(exitCode: 7,
            output: "First diagnostic\nFull fixture setup failure\n", missingAfter: [], finishedAt: Date())
        for tab in [SettingsTab.general, .dictionary, .transcription] {
            for (name, scheme, appearance) in [("light", ColorScheme.light, NSAppearance.Name.aqua),
                                               ("dark", .dark, .darkAqua)] {
                let view = SettingsView(hotkeyEnabled: true, missingPermissions: [], availableDevices: { [] }, selectedDeviceID: { nil },
                    modelsStatus: { .disconnected }, onRefreshModelsStatus: {}, residencyNotice: { "Full recognizer failure\nSecond line" },
                    processingNotice: { "Full processing failure" }, vocabularyRevision: { 0 }, initialTab: tab,
                    initialAdvancedExpanded: true, initialRelaySetupFeedback: (.setUp, failure),
                    initialHotkeyListenerRestart: .failed(missing: []), initialDictionaryPreview: preview,
                    initialIncludedTermsExpanded: true)
                try render(view.environment(\.colorScheme, scheme), appearance: NSAppearance(named: appearance),
                           size: CGSize(width: 780, height: tab == .general ? 1600 : 620),
                           to: directory.appendingPathComponent("copy-\(tab.title.lowercased())-\(name).png"))
            }
        }
    }

    private func render(_ view: some View, appearance: NSAppearance?, size: CGSize = CGSize(width: 780, height: 620), to url: URL) throws {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height)
            .background(Color(nsColor: .windowBackgroundColor)))
        host.appearance = appearance
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.appearance = appearance
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        defer { window.orderOut(nil); window.contentView = nil }
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        bitmap.size = size
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url, options: .atomic)
    }
}
