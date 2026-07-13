import AppKit
import SwiftUI
@testable import VoiceBarUI
import XCTest

/// Renders the 2026-06-06 settings design pass in BOTH appearances.
/// Artifacts land in docs.local/design/2026-06-06-settings-pass/after/
/// (the #237 rule: tests-green ≠ visually-correct — eyeball the PNGs).
@MainActor
final class SettingsDesignPassArtifactTests: XCTestCase {
    func testWritesSettingsArtifactsInLightAndDark() throws {
        try VisualArtifactTestPolicy.requireRegeneration()
        let outputDirectory = repoRoot()
            .appendingPathComponent("docs.local")
            .appendingPathComponent("design")
            .appendingPathComponent("2026-06-06-settings-pass")
            .appendingPathComponent("after")
        try FileManager.default.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: true
        )

        let preview = STTVocabularyPreview(
            updatedAt: "2026-06-06T20:00:00Z",
            promptTerms: ["VoiceLayer", "Wispr Flow", "SongScript"],
            aliases: [
                STTVocabularyAliasPreview(from: "voice lair", to: "VoiceLayer"),
                STTVocabularyAliasPreview(from: "whisper flow", to: "Wispr Flow"),
            ]
        )

        for (tab, tabName) in [
            (SettingsTab.dictionary, "dictionary"),
            (SettingsTab.general, "general"),
            (SettingsTab.history, "history"),
        ] {
            for (appearance, appearanceName) in [
                (NSAppearance(named: .aqua), "light"),
                (NSAppearance(named: .darkAqua), "dark"),
            ] {
                try writePNG(
                    settingsView(preview: preview, tab: tab)
                        .frame(width: 520, height: 620),
                    size: CGSize(width: 520, height: 620),
                    appearance: appearance,
                    named: "settings-\(tabName)-\(appearanceName).png",
                    in: outputDirectory
                )
            }
        }
    }

    private func settingsView(preview: STTVocabularyPreview, tab: SettingsTab) -> SettingsView {
        SettingsView(
            hotkeyEnabled: true,
            missingPermissions: [],
            availableDevices: { [MicrophoneDevice(id: "built-in", name: "MacBook Pro Microphone")] },
            selectedDeviceID: { "built-in" },
            onSelectDevice: { _ in },
            anchorMode: { .follow },
            onSelectAnchorMode: { _ in },
            vocabularyPreview: { preview },
            onAddVocabularyAlias: { _, _ in },
            onRemoveVocabularyAlias: { _ in },
            onAddPromptTerm: { _ in },
            onRemovePromptTerm: { _ in },
            isHotkeyRemapActive: { true },
            initialHistoryPage: SettingsHistoryPage(
                groups: Self.sampleHistoryGroups,
                loadedEntryCount: Self.sampleHistoryGroups.reduce(0) { $0 + $1.entries.count },
                hasMore: true
            ),
            onCopyHistoryTranscript: { _ in },
            onPasteHistoryTranscript: { _ in },
            onRetranscribeHistoryEntry: { _ in },
            initialTab: tab
        )
    }

    private static var sampleHistoryGroups: [SettingsHistoryDayGroup] {
        [
            SettingsHistoryDayGroup(
                dayKey: "2026-06-25",
                date: sampleDate(year: 2026, month: 6, day: 25),
                entries: [
                    SettingsHistoryEntry(
                        id: "/tmp/2026-06-25T21-30-00-000Z-latest/audio.wav",
                        dayKey: "2026-06-25",
                        recordingID: "2026-06-25T21-30-00-000Z-latest",
                        createdAt: sampleDate(year: 2026, month: 6, day: 25, hour: 21, minute: 30),
                        transcript: "Latest clip visible at the top of the full History page.",
                        audioPath: URL(fileURLWithPath: "/tmp/2026-06-25T21-30-00-000Z-latest/audio.wav")
                    ),
                    SettingsHistoryEntry(
                        id: "/tmp/2026-06-25T07-05-00-000Z-first/audio.wav",
                        dayKey: "2026-06-25",
                        recordingID: "2026-06-25T07-05-00-000Z-first",
                        createdAt: sampleDate(year: 2026, month: 6, day: 25, hour: 7, minute: 5),
                        transcript: "Morning clip with the corrected Etan spelling.",
                        audioPath: URL(fileURLWithPath: "/tmp/2026-06-25T07-05-00-000Z-first/audio.wav")
                    ),
                ]
            ),
            SettingsHistoryDayGroup(
                dayKey: "2026-06-23",
                date: sampleDate(year: 2026, month: 6, day: 23),
                entries: [
                    SettingsHistoryEntry(
                        id: "/tmp/2026-06-23T18-45-00-000Z-old/audio.wav",
                        dayKey: "2026-06-23",
                        recordingID: "2026-06-23T18-45-00-000Z-old",
                        createdAt: sampleDate(year: 2026, month: 6, day: 23, hour: 18, minute: 45),
                        transcript: "Eitan was misheard in this older clip before the dictionary fix.",
                        audioPath: URL(fileURLWithPath: "/tmp/2026-06-23T18-45-00-000Z-old/audio.wav")
                    ),
                ]
            ),
        ]
    }

    private static func sampleDate(
        year: Int,
        month: Int,
        day: Int,
        hour: Int = 0,
        minute: Int = 0
    ) -> Date {
        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.timeZone = TimeZone(secondsFromGMT: 0)
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        return components.date!
    }

    private func writePNG(
        _ view: some View,
        size: CGSize,
        appearance: NSAppearance?,
        named name: String,
        in directory: URL
    ) throws {
        let host = NSHostingView(rootView: view)
        host.appearance = appearance
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()

        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            XCTFail("Could not create bitmap for \(name)")
            return
        }
        bitmap.size = size
        host.cacheDisplay(in: host.bounds, to: bitmap)

        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            XCTFail("Could not encode PNG for \(name)")
            return
        }

        let outputURL = directory.appendingPathComponent(name)
        try data.write(to: outputURL, options: .atomic)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outputURL.path))
    }

    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
