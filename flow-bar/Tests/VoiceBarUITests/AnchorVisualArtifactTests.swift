import AppKit
import SwiftUI
@testable import VoiceBarUI
import XCTest

@MainActor
final class AnchorVisualArtifactTests: XCTestCase {
    func testWritesAnchorMenuAndSettingsStateArtifacts() throws {
        let outputDirectory = repoRoot()
            .appendingPathComponent("docs.local")
            .appendingPathComponent("voicebar-dictionary-anchor")
            .appendingPathComponent("visual-qa")
        try FileManager.default.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: true
        )

        let states: [(mode: VoiceBarAnchorMode, slug: String)] = [
            (.follow, "follow-mouse"),
            (.topCenter, "notch-center"),
        ]

        for state in states {
            let controller = PillContextMenuController()
            controller.anchorModeProvider = { state.mode }
            let menu = controller.makeMenu()
            let anchorMenu = try XCTUnwrap(menu.items.first { $0.title == "Anchor" }?.submenu)

            try writePNG(
                AnchorMenuArtifactView(items: anchorMenu.items)
                    .environment(\.colorScheme, .light)
                    .frame(width: 260, height: 190),
                size: CGSize(width: 260, height: 190),
                named: "menu-anchor-\(state.slug).png",
                in: outputDirectory
            )

            try writePNG(
                SettingsView(
                    hotkeyEnabled: true,
                    missingPermissions: [],
                    availableDevices: { [MicrophoneDevice(id: "built-in", name: "MacBook Pro Microphone")] },
                    selectedDeviceID: { "built-in" },
                    onSelectDevice: { _ in },
                    anchorMode: { state.mode },
                    onSelectAnchorMode: { _ in },
                    vocabularyPreview: {
                        STTVocabularyPreview(updatedAt: nil, promptTerms: [], aliases: [])
                    },
                    onAddVocabularyAlias: { _, _ in },
                    onRemoveVocabularyAlias: { _ in },
                    initialTab: .general
                )
                .environment(\.colorScheme, .light)
                .frame(width: 520, height: 620),
                size: CGSize(width: 520, height: 620),
                named: "settings-anchor-\(state.slug).png",
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

private struct AnchorMenuArtifactView: View {
    let items: [NSMenuItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Anchor")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                if item.isSeparatorItem {
                    Divider()
                        .padding(.vertical, 4)
                } else {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark")
                            .frame(width: 14)
                            .opacity(item.state == .on ? 1 : 0)
                        Text(item.title)
                        Spacer()
                    }
                    .font(.system(size: 13))
                    .padding(.horizontal, 12)
                    .frame(height: 28)
                }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .padding(12)
    }
}
