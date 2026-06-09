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

        for (tab, tabName) in [(SettingsTab.dictionary, "dictionary"), (SettingsTab.general, "general")] {
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
            initialTab: tab
        )
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
