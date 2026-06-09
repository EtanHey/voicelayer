import AppKit
import SwiftUI
@testable import VoiceBarUI
import XCTest

@MainActor
final class DictionaryVisualArtifactTests: XCTestCase {
    func testWritesDictionarySettingsAndAddSheetArtifacts() throws {
        let outputDirectory = repoRoot()
            .appendingPathComponent("docs.local")
            .appendingPathComponent("voicebar-dictionary-anchor")
            .appendingPathComponent("visual-qa")
        try FileManager.default.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: true
        )

        let preview = STTVocabularyPreview(
            updatedAt: "2026-06-05T20:00:00Z",
            promptTerms: ["VoiceLayer", "Wispr Flow", "SongScript"],
            aliases: [
                STTVocabularyAliasPreview(from: "voice lair", to: "VoiceLayer"),
                STTVocabularyAliasPreview(from: "whisper flow", to: "Wispr Flow"),
            ]
        )

        for scheme in [ColorScheme.light, .dark] {
            try writePNG(
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
                    initialTab: .dictionary
                )
                .environment(\.colorScheme, scheme)
                .frame(width: 520, height: 620),
                size: CGSize(width: 520, height: 620),
                named: "settings-dictionary-\(scheme.artifactSlug).png",
                in: outputDirectory
            )
        }

        for scheme in [ColorScheme.light, .dark] {
            try writePNG(
                DictionaryAddSheetView(
                    draft: STTVocabularyDraft(
                        correct: "VoiceLayer",
                        wrong: "voice lair"
                    ),
                    onSave: { _ in },
                    onCancel: {}
                )
                .environment(\.colorScheme, scheme)
                .frame(width: 420, height: 240),
                size: CGSize(width: 420, height: 240),
                named: "add-to-dictionary-sheet-\(scheme.artifactSlug).png",
                in: outputDirectory
            )
        }
    }

    private func writePNG(
        _ view: some View,
        size: CGSize,
        named name: String,
        in directory: URL
    ) throws {
        let host = NSHostingView(rootView: view)
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
        XCTAssertGreaterThan(try FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? Int ?? 0, 0)
    }

    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}

private extension ColorScheme {
    var artifactSlug: String {
        switch self {
        case .light: "light"
        case .dark: "dark"
        @unknown default: "unknown"
        }
    }
}
