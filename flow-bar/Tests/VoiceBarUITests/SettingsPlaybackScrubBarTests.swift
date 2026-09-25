import AppKit
import SwiftUI
@testable import VoiceBarUI
import XCTest

/// H1-b: the History scrub bar. Logic is proven on the model (SettingsAudioPlaybackTests); these
/// pin the bar's key/VoiceOver steps, that its fill follows the clip, where SettingsView mounts
/// it, and write the light/dark shots to look at.
@MainActor
final class SettingsPlaybackScrubBarTests: XCTestCase {
    private let clipURL = URL(fileURLWithPath: "/tmp/recording-latest/audio.wav")

    func testArrowKeysStepByTheKeyboardSeekStep() {
        XCTAssertEqual(SettingsPlaybackScrubBar.seekDelta(for: .leftArrow), -5)
        XCTAssertEqual(SettingsPlaybackScrubBar.seekDelta(for: .rightArrow), 5)
        XCTAssertNil(SettingsPlaybackScrubBar.seekDelta(for: .upArrow))
        XCTAssertNil(SettingsPlaybackScrubBar.seekDelta(for: .space))
    }

    func testVoiceOverIncrementAndDecrementStepTheSameAmount() {
        XCTAssertEqual(SettingsPlaybackScrubBar.seekDelta(for: .increment), 5)
        XCTAssertEqual(SettingsPlaybackScrubBar.seekDelta(for: .decrement), -5)
    }

    func testTheFillFollowsTheClipPosition() throws {
        let early = try renderBar(currentTime: 10, duration: 100)
        let late = try renderBar(currentTime: 90, duration: 100)
        let midX = early.pixelsWide / 2
        let midY = early.pixelsHigh / 2

        let earlyMid = try XCTUnwrap(early.colorAt(x: midX, y: midY))
        let lateMid = try XCTUnwrap(late.colorAt(x: midX, y: midY))

        // At 10 % the track's midpoint is unfilled; at 90 % it is the accent fill.
        XCTAssertGreaterThan(colorDistance(earlyMid, lateMid), 0.2)
    }

    func testTheBarIsMountedOnlyUnderThePlayingPart() throws {
        let source = try source(named: "SettingsView.swift")

        XCTAssertTrue(source.contains(
            "if let audioPath = part.audioPath, historyPlayback.isPlaying(audioPath) {\n"
                + "                SettingsPlaybackScrubBar("
        ))
    }

    /// The bar samples the clock several times a second. SettingsView must never read the
    /// position itself, or every tick re-renders the whole Settings window.
    func testSettingsViewNeverSamplesThePlaybackPosition() throws {
        let source = try source(named: "SettingsView.swift")

        XCTAssertFalse(source.contains(".position(of:"))
        XCTAssertFalse(source.contains("TimelineView"))
    }

    func testWritesScrubBarArtifactsInLightAndDark() throws {
        try VisualArtifactTestPolicy.requireRegeneration()
        let outputDirectory = repoRoot()
            .appendingPathComponent("docs.local")
            .appendingPathComponent("design")
            .appendingPathComponent("2026-09-25-h1b-scrub")
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        for (scope, scopeName, playingURL) in [
            (SettingsHistoryScope.recording, "dictations", clipURL),
            (SettingsHistoryScope.ask, "ask", URL(fileURLWithPath: "/tmp/ask-latest/agent-audio.mp3")),
        ] {
            for (appearance, appearanceName) in [
                (NSAppearance(named: .aqua), "light"),
                (NSAppearance(named: .darkAqua), "dark"),
            ] {
                let playback = fakePlayback(currentTime: 23, duration: 65)
                playback.toggle(playingURL)
                let view = settingsView(scope: scope, playback: playback)
                    .frame(width: 900, height: 620)
                let bitmap = try render(view, size: CGSize(width: 900, height: 620), appearance: appearance)
                let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                try data.write(
                    to: outputDirectory.appendingPathComponent("history-\(scopeName)-playing-\(appearanceName).png"),
                    options: .atomic
                )
            }
        }
    }

    // MARK: - Helpers

    private func fakePlayback(currentTime: TimeInterval, duration: TimeInterval) -> SettingsAudioPlayback {
        SettingsAudioPlayback(
            start: { _ in true },
            stop: {},
            position: { SettingsAudioPlaybackPosition(currentTime: currentTime, duration: duration) },
            seek: { _ in }
        )
    }

    private func renderBar(currentTime: TimeInterval, duration: TimeInterval) throws -> NSBitmapImageRep {
        let playback = fakePlayback(currentTime: currentTime, duration: duration)
        playback.toggle(clipURL)
        // Both time labels share one min width, so the track's midpoint is the image's midpoint.
        let bar = SettingsPlaybackScrubBar(playback: playback, url: clipURL, accessibilityNoun: "recording audio")
            .frame(width: 400, height: 20)
        return try render(bar, size: CGSize(width: 400, height: 20), appearance: NSAppearance(named: .aqua))
    }

    private func render(_ view: some View, size: CGSize, appearance: NSAppearance?) throws -> NSBitmapImageRep {
        let host = NSHostingView(rootView: view)
        host.appearance = appearance
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        bitmap.size = size
        host.cacheDisplay(in: host.bounds, to: bitmap)
        return bitmap
    }

    private func colorDistance(_ lhs: NSColor, _ rhs: NSColor) -> CGFloat {
        guard let a = lhs.usingColorSpace(.sRGB), let b = rhs.usingColorSpace(.sRGB) else { return 0 }
        return abs(a.redComponent - b.redComponent)
            + abs(a.greenComponent - b.greenComponent)
            + abs(a.blueComponent - b.blueComponent)
    }

    private func settingsView(scope: SettingsHistoryScope, playback: SettingsAudioPlayback) -> SettingsView {
        let askGroups = [
            SettingsAskHistoryDayGroup(
                dayKey: "2026-09-25",
                date: Self.sampleDate(hour: 0),
                entries: [
                    SettingsAskHistoryEntry(
                        id: "/tmp/ask-latest",
                        dayKey: "2026-09-25",
                        askID: "2026-09-25T09-40-00-000Z-latest",
                        createdAt: Self.sampleDate(hour: 9, minute: 40),
                        questionText: "Do you want the scrub bar under the clip or next to Play?",
                        questionAudioPath: URL(fileURLWithPath: "/tmp/ask-latest/agent-audio.mp3"),
                        responseTranscript: "Under the clip, full width, so I can drag it.",
                        responseAudioPath: URL(fileURLWithPath: "/tmp/ask-latest/audio.wav")
                    ),
                ]
            ),
        ]
        return SettingsView(
            hotkeyEnabled: true,
            missingPermissions: [],
            availableDevices: { [MicrophoneDevice(id: "built-in", name: "MacBook Pro Microphone")] },
            selectedDeviceID: { "built-in" },
            onSelectDevice: { _ in },
            modelsStatus: { .loading },
            onRefreshModelsStatus: {},
            vocabularyRevision: { 0 },
            initialHistoryPage: SettingsHistoryPage(
                groups: [
                    SettingsHistoryDayGroup(
                        dayKey: "2026-09-25",
                        date: Self.sampleDate(hour: 0),
                        entries: [
                            SettingsHistoryEntry(
                                id: clipURL.path,
                                dayKey: "2026-09-25",
                                recordingID: "2026-09-25T09-30-00-000Z-latest",
                                createdAt: Self.sampleDate(hour: 9, minute: 30),
                                transcript: "History playback finally has a scrub bar I can drag.",
                                audioPath: clipURL
                            ),
                        ]
                    ),
                ],
                hasMore: false
            ),
            askHistoryPage: { _ in SettingsAskHistoryPage(groups: askGroups, hasMore: false) },
            initialAskHistoryPage: SettingsAskHistoryPage(groups: askGroups, hasMore: false),
            initialTab: .history,
            initialHistoryScope: scope,
            historyPlayback: playback
        )
    }

    private static func sampleDate(hour: Int, minute: Int = 0) -> Date {
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

    private func source(named name: String) throws -> String {
        try String(
            contentsOf: repoRoot()
                .appendingPathComponent("flow-bar/Sources/VoiceBarUI")
                .appendingPathComponent(name),
            encoding: .utf8
        )
    }

    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
