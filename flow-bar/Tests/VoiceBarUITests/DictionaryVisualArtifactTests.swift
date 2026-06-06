@testable import VoiceBarUI
import AppKit
import SwiftUI
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

        try writePNG(
            SettingsView(
                hotkeyEnabled: true,
                missingPermissions: [],
                availableDevices: { [MicrophoneDevice(id: "built-in", name: "MacBook Pro Microphone")] },
                selectedDeviceID: { "built-in" },
                onSelectDevice: { _ in },
                anchorMode: { .follow },
                onSelectAnchorMode: { _ in },
                isPositionLocked: { true },
                onSetPositionLocked: { _ in },
                vocabularyPreview: { preview },
                onAddVocabularyAlias: { _, _ in },
                onRemoveVocabularyAlias: { _ in },
                initialTab: .dictionary
            )
            .environment(\.colorScheme, .light)
            .frame(width: 520, height: 620),
            size: CGSize(width: 520, height: 620),
            named: "settings-dictionary.png",
            in: outputDirectory
        )

        try writePNG(
            DictionaryAddSheetView(
                draft: STTVocabularyDraft(
                    correct: "VoiceLayer",
                    wrong: "voice lair"
                ),
                onSave: { _ in },
                onCancel: {}
            )
            .environment(\.colorScheme, .light)
            .frame(width: 420, height: 240),
            size: CGSize(width: 420, height: 240),
            named: "add-to-dictionary-sheet.png",
            in: outputDirectory
        )
    }

    private func writePNG<Content: View>(
        _ view: Content,
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
