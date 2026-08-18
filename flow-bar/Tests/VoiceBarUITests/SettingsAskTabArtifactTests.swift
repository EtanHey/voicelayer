import AppKit
import SwiftUI
@testable import VoiceBarUI
import XCTest

/// Renders Settings → History in both scopes so the Ask tab can be eyeballed.
/// Artifacts land in docs.local/design/2026-08-18-history-ask-tab/.
/// (The #237 rule: tests-green != visually-correct — look at the PNGs.)
@MainActor
final class SettingsAskTabArtifactTests: XCTestCase {
    func testWritesHistoryScopeArtifactsInLightAndDark() throws {
        try VisualArtifactTestPolicy.requireRegeneration()
        let outputDirectory = repoRoot()
            .appendingPathComponent("docs.local")
            .appendingPathComponent("design")
            .appendingPathComponent("2026-08-18-history-ask-tab")
        try FileManager.default.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: true
        )

        for (scope, scopeName) in [
            (SettingsHistoryScope.recording, "recording"),
            (SettingsHistoryScope.ask, "ask"),
        ] {
            for (appearance, appearanceName) in [
                (NSAppearance(named: .aqua), "light"),
                (NSAppearance(named: .darkAqua), "dark"),
            ] {
                try writePNG(
                    settingsView(scope: scope)
                        .frame(width: 520, height: 620),
                    size: CGSize(width: 520, height: 620),
                    appearance: appearance,
                    named: "history-\(scopeName)-\(appearanceName).png",
                    in: outputDirectory
                )
            }
        }
    }

    private func settingsView(scope: SettingsHistoryScope) -> SettingsView {
        SettingsView(
            hotkeyEnabled: true,
            missingPermissions: [],
            availableDevices: { [MicrophoneDevice(id: "built-in", name: "MacBook Pro Microphone")] },
            selectedDeviceID: { "built-in" },
            onSelectDevice: { _ in },
            initialHistoryPage: SettingsHistoryPage(
                groups: Self.sampleRecordingGroups,
                hasMore: true
            ),
            askHistoryPage: { _ in
                SettingsAskHistoryPage(groups: Self.sampleAskGroups, hasMore: true)
            },
            initialAskHistoryPage: SettingsAskHistoryPage(
                groups: Self.sampleAskGroups,
                hasMore: true
            ),
            initialTab: .history,
            initialHistoryScope: scope
        )
    }

    private static var sampleRecordingGroups: [SettingsHistoryDayGroup] {
        [
            SettingsHistoryDayGroup(
                dayKey: "2026-08-18",
                date: sampleDate(day: 18),
                entries: [
                    SettingsHistoryEntry(
                        id: "/tmp/recording-latest/audio.wav",
                        dayKey: "2026-08-18",
                        recordingID: "2026-08-18T21-30-00-000Z-latest",
                        createdAt: sampleDate(day: 18, hour: 21, minute: 30),
                        transcript: "An F5 dictation — the recording list is unchanged by the Ask tab.",
                        audioPath: URL(fileURLWithPath: "/tmp/recording-latest/audio.wav")
                    ),
                ]
            ),
        ]
    }

    private static var sampleAskGroups: [SettingsAskHistoryDayGroup] {
        [
            SettingsAskHistoryDayGroup(
                dayKey: "2026-08-18",
                date: sampleDate(day: 18),
                entries: [
                    SettingsAskHistoryEntry(
                        id: "/tmp/ask-latest",
                        dayKey: "2026-08-18",
                        askID: "2026-08-18T21-40-00-000Z-latest",
                        createdAt: sampleDate(day: 18, hour: 21, minute: 40),
                        questionText: "Do you want the silence timeout raised to five seconds?",
                        questionAudioPath: URL(fileURLWithPath: "/tmp/ask-latest/agent-audio.mp3"),
                        responseTranscript: "Yes, but only when I am mid-sentence — never cut me off.",
                        responseAudioPath: URL(fileURLWithPath: "/tmp/ask-latest/audio.wav")
                    ),
                    SettingsAskHistoryEntry(
                        id: "/tmp/ask-untranscribed",
                        dayKey: "2026-08-18",
                        askID: "2026-08-18T20-10-00-000Z-untranscribed",
                        createdAt: sampleDate(day: 18, hour: 20, minute: 10),
                        questionText: "Should this ship before the release cut?",
                        questionAudioPath: URL(fileURLWithPath: "/tmp/ask-untranscribed/agent-audio.mp3"),
                        responseTranscript: "",
                        responseAudioPath: URL(fileURLWithPath: "/tmp/ask-untranscribed/audio.wav")
                    ),
                ]
            ),
        ]
    }

    private static func sampleDate(day: Int, hour: Int = 0, minute: Int = 0) -> Date {
        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.timeZone = TimeZone(secondsFromGMT: 0)
        components.year = 2026
        components.month = 8
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
