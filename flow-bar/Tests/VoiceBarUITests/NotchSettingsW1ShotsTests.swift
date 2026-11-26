import AppKit
import OffscreenTestSupport
import SwiftUI
@testable import VoiceBarUI
import XCTest

/// GO-1126 W1: every notch Settings drawer tab, at the drawer's real width and default height, in both appearances.
/// Invented data only. Writes PNGs only when `VOICEBAR_W1_PNG_DIR` is set (before/after proof for the PR);
/// otherwise it only checks every tab renders.
@MainActor
final class NotchSettingsW1ShotsTests: XCTestCase {
    static func history(_ appearance: VoiceBarNotchAppearance) -> AnyView {
        let palette = VoiceBarNotchContrastPalette.resolve(for: appearance)
        return AnyView(VStack(alignment: .leading, spacing: 10) {
            ForEach(["Pick up coffee on the way home.", "Move lunch to one thirty.", "Two oat flat whites."],
                    id: \.self) { line in
                Text(line).font(.system(size: 12)).foregroundStyle(palette.primary.color)
            }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8))
    }

    static func pane(_ tab: SettingsTab) -> SettingsView {
        let terms = DictionaryNotchTrackDShotsTests.preview()
        return SettingsView(
            hotkeyEnabled: true, missingPermissions: [],
            availableDevices: { [MicrophoneDevice(id: "2", name: "MacBook Pro Microphone")] },
            selectedDeviceID: { "2" },
            prioritySnapshot: { SettingsDrawerLaneSSnapshotTests.micSnapshot() },
            modelsStatus: { SettingsDrawerLaneSSnapshotTests.modelsState() }, onRefreshModelsStatus: {},
            recognizerStatus: { SettingsDrawerLaneSSnapshotTests.recognizer() },
            onReadClipboard: {},
            onToggleProcessing: { _, _ in },
            vocabularyPreview: { terms }, vocabularyRevision: { 0 },
            openAtLogin: SettingsToggleInput(isOn: { true }, set: { _ in }),
            mouseSideButtons: SettingsToggleInput(isOn: { true }, set: { _ in }),
            initialTab: tab, initialDictionaryPreview: terms,
            installedVersion: .init(version: "2.4.6", commit: "50f4ade")
        )
    }

    static func drawer(_ tab: SettingsTab, _ appearance: VoiceBarNotchAppearance) -> some View {
        NotchSettingsDrawer(
            selectedTab: tab, appearance: appearance,
            context: NotchSettingsDrawerContext(updates: nil, pane: { tab, _ in
                AnyView(pane(tab).notchDrawerPane(tab))
            }),
            history: { history(appearance) },
            onSelectTab: { _ in }
        )
    }

    func testRenderEveryTab() throws {
        for appearance in [VoiceBarNotchAppearance.dark, .light] {
            let suffix = appearance == .dark ? "dark" : "light"
            for tab in SettingsTab.allCases {
                let bitmap = try DictionaryNotchTrackDShotsTests.render(
                    Self.drawer(tab, appearance), appearance: appearance,
                    name: "w1-\(tab.title.lowercased())-\(suffix)", pngDirectoryVariable: "VOICEBAR_W1_PNG_DIR"
                )
                XCTAssertGreaterThan(bitmap.pixelsWide, 0)
            }
        }
    }
}
