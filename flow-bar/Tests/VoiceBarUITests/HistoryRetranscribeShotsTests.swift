import AppKit
import SwiftUI
@testable import VoiceBarUI
import XCTest

/// Lane B (QA 2.2.25 C5–C8) shots: the notch History row and Settings › History's detail while a re-transcription
/// runs, light and dark, in offscreen windows at 2×. Synthetic fixtures only. Uses no lane-B API, so the same file
/// renders the "before" set on the base commit.
@MainActor
final class HistoryRetranscribeShotsTests: XCTestCase {
    private final class NoopRouter: BarCommandRouting {
        func handlePrimaryTap() {}
        func handleCancel() {}
        func handleStop() {}
        func handleReplay() {}
        func handleRetranscribeHistoryEntry(recordingPath: String) {}
    }

    private static let selectedPath = "/tmp/lane-b-shots/selected/audio.wav"
    private static let otherPath = "/tmp/lane-b-shots/other/audio.wav"

    func testWriteRetranscribeShotsWhenRequested() throws {
        guard let path = ProcessInfo.processInfo.environment["VOICEBAR_SHOTS_DIR"], !path.isEmpty else {
            throw XCTSkip("Set VOICEBAR_SHOTS_DIR to write local visual artifacts")
        }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        for (appearanceName, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            // The notch row: "Re-transcribing…" beside its spinner.
            let state = VoiceState(
                recentTranscriptionsLoader: { [] }, recentTranscriptionsSaver: { _ in },
                recentTranscriptionEntriesLoader: {
                    [
                        RecentTranscriptionEntry(text: "A synthetic dictation being re-transcribed.",
                                                 recordingPath: Self.selectedPath,
                                                 createdAt: Date().addingTimeInterval(-180)),
                        RecentTranscriptionEntry(text: "Another short synthetic sample.",
                                                 recordingPath: Self.otherPath,
                                                 createdAt: Date().addingTimeInterval(-420)),
                    ]
                },
                recentTranscriptionEntriesSaver: { _ in },
                transcriptionVocabularyLoader: { [] }, transcriptionVocabularyAliasLoader: { [] },
                keepsExpandedInDevState: false
            )
            state.isConnected = true
            state.hotkeyEnabled = true
            state.isCollapsed = false
            state.sendCommand = { _ in }
            state.retranscribeHistoryEntry(recordingPath: Self.selectedPath)
            let model = VoiceBarNotchPresentationModel()
            model.updateOperationalEnvelope(hasTeleprompter: false, isRecording: false, hasCompactStatus: false)
            model.setHovered(true)
            model.setHistoryPanelOpen(true)
            let canvas = VoiceBarNotchMorphCanvasLayout.resolve(for: model.presentation).canvasGeometry
            try render(
                BarView(state: state, commandRouter: NoopRouter(), onOpenSettings: {}, onOpenHistory: {},
                        presentationModel: model, includesPanelOutsets: true),
                size: CGSize(width: canvas.totalWidth + 24, height: canvas.totalHeight + 17),
                appearance: appearance,
                to: directory.appendingPathComponent("notch-history-retranscribing-\(appearanceName).png")
            )

            // Settings › History: idle, this entry re-transcribing, another entry re-transcribing.
            for (stateName, retranscribingPath) in [
                ("idle", nil), ("this-entry", Self.selectedPath), ("another-entry", Self.otherPath),
            ] as [(String, String?)] {
                try render(
                    settingsHistory(retranscribingPath: retranscribingPath),
                    size: CGSize(width: 900, height: 700),
                    appearance: appearance,
                    to: directory.appendingPathComponent("settings-history-\(stateName)-\(appearanceName).png")
                )
            }
        }
    }

    private func settingsHistory(retranscribingPath: String?) -> some View {
        let page = SettingsHistoryPage(groups: [
            SettingsHistoryDayGroup(dayKey: "2026-09-25", date: Date(timeIntervalSince1970: 1_790_294_400), entries: [
                entry(path: Self.selectedPath, transcript: "A synthetic dictation being re-transcribed.", minute: 8),
                entry(path: Self.otherPath, transcript: "Another short synthetic sample.", minute: 3),
            ]),
        ], hasMore: false)
        return SettingsView(
            hotkeyEnabled: true,
            missingPermissions: [],
            availableDevices: { [] },
            selectedDeviceID: { nil },
            modelsStatus: { .loading },
            onRefreshModelsStatus: {},
            vocabularyRevision: { 0 },
            historyPage: { _ in page },
            initialHistoryPage: page,
            isHistoryRetranscribing: { $0 == retranscribingPath },
            isAnyHistoryRetranscribing: { retranscribingPath != nil },
            isTranscribingActive: { retranscribingPath != nil },
            initialTab: .history,
            initialHistoryScope: .recording
        )
    }

    private func entry(path: String, transcript: String, minute: Int) -> SettingsHistoryEntry {
        SettingsHistoryEntry(
            id: path,
            dayKey: "2026-09-25",
            recordingID: URL(fileURLWithPath: path).deletingLastPathComponent().lastPathComponent,
            createdAt: Date(timeIntervalSince1970: 1_790_341_200 + TimeInterval(minute * 60)),
            transcript: transcript,
            audioPath: URL(fileURLWithPath: path),
            durationMs: 10000,
            performanceEffort: .accurate
        )
    }

    private func render(_ view: some View, size: CGSize, appearance: NSAppearance.Name, to url: URL) throws {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height, alignment: .topLeading))
        host.appearance = NSAppearance(named: appearance)
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.backgroundColor = .windowBackgroundColor
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url, options: .atomic)
        window.contentView = nil
    }
}
