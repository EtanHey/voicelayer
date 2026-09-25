import AppKit
import SwiftUI
@testable import VoiceBarUI
import XCTest

/// H1-d: History layout and naming shots, light and dark. Artifacts land in docs.local/design/2026-09-25-h1d/.
/// (The #237 rule: tests-green != visually-correct — look at the PNGs.)
@MainActor
final class SettingsHistoryLayoutArtifactTests: XCTestCase {
    func testWritesHistoryLayoutArtifactsInLightAndDark() throws {
        try VisualArtifactTestPolicy.requireRegeneration()
        let outputDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("docs.local/design/2026-09-25-h1d")
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        for (scope, name) in [(SettingsHistoryScope.recording, "dictations"), (.ask, "ask")] {
            for (appearance, appearanceName) in [
                (NSAppearance(named: .aqua), "light"),
                (NSAppearance(named: .darkAqua), "dark"),
            ] {
                let view = SettingsView(
                    hotkeyEnabled: true,
                    missingPermissions: [],
                    availableDevices: { [] },
                    selectedDeviceID: { nil },
                    onSelectDevice: { _ in },
                    modelsStatus: { .loading },
                    onRefreshModelsStatus: {},
                    vocabularyRevision: { 0 },
                    historyPage: { _ in Self.dictations },
                    initialHistoryPage: Self.dictations,
                    askHistoryPage: { _ in Self.asks },
                    initialAskHistoryPage: Self.asks,
                    initialTab: .history,
                    initialHistoryScope: scope
                )
                let size = CGSize(width: 900, height: 700)
                let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
                host.appearance = appearance
                host.frame = NSRect(origin: .zero, size: size)
                let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: true)
                window.contentView = host
                host.layoutSubtreeIfNeeded()
                let settled = expectation(description: "loads applied")
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(600))
                    settled.fulfill()
                }
                wait(for: [settled], timeout: 5)
                host.layoutSubtreeIfNeeded()
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                bitmap.size = size
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                try data.write(to: outputDirectory.appendingPathComponent("history-\(name)-\(appearanceName).png"))
                window.contentView = nil
            }
        }
    }

    private static let dictations = SettingsHistoryPage(groups: [
        SettingsHistoryDayGroup(dayKey: "2026-09-25", date: date(hour: 0), entries: (0 ..< 9).map { index in
            SettingsHistoryEntry(
                id: "/tmp/h1d-\(index)/audio.wav",
                dayKey: "2026-09-25",
                recordingID: "h1d-\(index)",
                createdAt: date(hour: 21 - index, minute: 3),
                transcript: [
                    "The notch glass looks off in dark mode, can you check the contrast?",
                    "Ship the History search after the review round.",
                    "",
                    "Deploy the notch build to the M1 after lunch.",
                ][index % 4],
                audioPath: URL(fileURLWithPath: "/tmp/h1d-\(index)/audio.wav"),
                durationMs: 4000 + index * 9000,
                performanceEffort: index % 2 == 0 ? .accurate : .balanced
            )
        }),
    ], hasMore: true)

    private static let asks = SettingsAskHistoryPage(groups: [
        SettingsAskHistoryDayGroup(dayKey: "2026-09-25", date: date(hour: 0), entries: [
            SettingsAskHistoryEntry(
                id: "/tmp/h1d-ask-1", dayKey: "2026-09-25", askID: "a1",
                createdAt: date(hour: 10, minute: 15),
                questionText: "Raise the silence timeout to five seconds?",
                questionAudioPath: URL(fileURLWithPath: "/tmp/h1d-ask-1/agent-audio.mp3"),
                responseTranscript: "Yes, but only when I'm mid-sentence.",
                responseAudioPath: URL(fileURLWithPath: "/tmp/h1d-ask-1/audio.wav")
            ),
            SettingsAskHistoryEntry(
                id: "/tmp/h1d-ask-2", dayKey: "2026-09-25", askID: "a2",
                createdAt: date(hour: 9, minute: 40),
                questionText: "Should this ship before the release cut?",
                questionAudioPath: URL(fileURLWithPath: "/tmp/h1d-ask-2/agent-audio.mp3"),
                responseTranscript: "",
                responseAudioPath: URL(fileURLWithPath: "/tmp/h1d-ask-2/audio.wav")
            ),
        ]),
    ], hasMore: false)

    private static func date(hour: Int, minute: Int = 0) -> Date {
        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.timeZone = TimeZone(secondsFromGMT: 0)
        components.year = 2026
        components.month = 9
        components.day = 25
        components.hour = hour
        components.minute = minute
        return components.date ?? Date(timeIntervalSince1970: 0)
    }
}
