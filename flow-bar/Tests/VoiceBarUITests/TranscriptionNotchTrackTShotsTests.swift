import AppKit
import OffscreenTestSupport
import SwiftUI
@testable import VoiceBarUI
import XCTest

/// 2.4.6 UI track T: the Transcription pane and the General pane inside the notch Settings drawer, at the drawer's
/// real width, in both appearances, with invented fixtures (lane S's Parakeet-loaded recognizer and microphones). Writes
/// PNGs only when `VOICEBAR_TRACK_T_PNG_DIR` is set; otherwise it checks every scenario renders.
@MainActor
final class TranscriptionNotchTrackTShotsTests: XCTestCase {
    /// Two invented microphones (one connected), so the General note sits in the drawer's first viewport.
    static func micSnapshot() -> MicrophonePrioritySnapshot {
        MicrophonePrioritySnapshot(rows: [
            MicrophonePriorityRow(uid: "builtin", deviceID: "2", label: "MacBook Pro Microphone", isConnected: true),
            MicrophonePriorityRow(uid: "studio", deviceID: "5", label: "Studio Mic Rx", isConnected: false),
        ], nextDeviceName: "MacBook Pro Microphone", nextDeviceUID: "builtin", nextDeviceID: "2")
    }

    /// Lane S's models fixture with live recognizer controls (switching, Load/Unload, the idle switch), as the app wires them.
    static func pane(_ tab: SettingsTab) -> SettingsView {
        SettingsView(
            hotkeyEnabled: true, missingPermissions: [],
            availableDevices: { [MicrophoneDevice(id: "2", name: "MacBook Pro Microphone")] },
            selectedDeviceID: { "2" },
            prioritySnapshot: { micSnapshot() },
            modelsStatus: { SettingsDrawerLaneSSnapshotTests.modelsState() }, onRefreshModelsStatus: {},
            recognizerStatus: { SettingsDrawerLaneSSnapshotTests.recognizer() },
            onSelectRecognizer: { _ in }, onManageRecognizer: { _, _ in }, onSetUnloadWhenIdle: { _ in },
            onReadClipboard: {},
            onToggleProcessing: { _, _ in },
            vocabularyPreview: { STTVocabularyPreview(updatedAt: nil, entries: []) }, vocabularyRevision: { 0 },
            openAtLogin: SettingsToggleInput(isOn: { true }, set: { _ in }),
            mouseSideButtons: SettingsToggleInput(isOn: { true }, set: { _ in }),
            initialTab: tab,
            initialAdvancedExpanded: false, installedVersion: .init(version: "2.4.6", commit: "abc1234")
        )
    }

    private final class NoLauncher: VoiceBarUpdateLaunching, @unchecked Sendable {
        var isAvailable = true
        func launch() throws {}
    }

    /// An invented, up-to-date 2.4.6 build: the footer as a normal user sees it (lead, 23 Nov: these pictures go on
    /// Etan's page).
    static func updates() async -> NotchUpdateController {
        let controller = NotchUpdateController(
            installed: .init(version: "2.4.6", commit: "abc1234"),
            describe: VoiceBarGitDescribe(releaseVersion: "2.4.6", commitsAhead: 0),
            check: VoiceBarVersionCheck(fetch: { "cask \"voicebar\" do\n  version \"2.4.6\"\nend\n" }),
            launcher: NoLauncher(), isDictating: { false }
        )
        await controller.checkForUpdates()
        return controller
    }

    static func drawer(_ tab: SettingsTab, _ appearance: VoiceBarNotchAppearance,
                       updates: NotchUpdateController?) -> some View {
        NotchSettingsDrawer(
            selectedTab: tab, appearance: appearance,
            context: NotchSettingsDrawerContext(updates: updates, pane: { tab, _ in
                AnyView(pane(tab).notchDrawerPane(tab))
            }),
            onSelectTab: { _ in }
        )
    }

    @discardableResult
    static func render(_ view: some View, appearance: VoiceBarNotchAppearance, name: String,
                       height: CGFloat = NotchSettingsDrawerPresentation.lowerSurfaceHeight) throws -> NSBitmapImageRep {
        let size = CGSize(width: SettingsDrawerLaneSSnapshotTests.drawerWidth, height: height)
        let scheme: ColorScheme = appearance == .dark ? .dark : .light
        let nsAppearance = NSAppearance(named: appearance == .dark ? .darkAqua : .aqua)
        let framed = view.frame(width: size.width, height: size.height)
            .background(DictionaryNotchTrackDShotsTests.backdrop(appearance))
            .environment(\.colorScheme, scheme)
        let host = NSHostingView(rootView: framed)
        host.appearance = nsAppearance
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = nsAppearance
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        VLOrderTestWindow(window)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(1.0))
        let bitmap = try EtanQA0510Tests.fixedScaleBitmap(host)
        if let dir = ProcessInfo.processInfo.environment["VOICEBAR_TRACK_T_PNG_DIR"], !dir.isEmpty {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            let url = URL(fileURLWithPath: dir).appendingPathComponent("\(name).png")
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url)
        }
        return bitmap
    }

    static func scenes(_ appearance: VoiceBarNotchAppearance,
                       updates: NotchUpdateController) -> [(String, AnyView, CGFloat)] {
        let suffix = appearance == .dark ? "dark" : "light"
        return [
            ("transcription-\(suffix)", AnyView(drawer(.transcription, appearance, updates: nil)),
             NotchSettingsDrawerPresentation.lowerSurfaceHeight),
            ("transcription-full-\(suffix)", AnyView(drawer(.transcription, appearance, updates: nil)), 1000),
            ("general-\(suffix)", AnyView(drawer(.general, appearance, updates: updates)),
             NotchSettingsDrawerPresentation.lowerSurfaceHeight),
        ]
    }

    func testRenderTrackTScenarios() async throws {
        let updates = await Self.updates()
        for appearance in [VoiceBarNotchAppearance.dark, .light] {
            for (name, view, height) in Self.scenes(appearance, updates: updates) {
                try Self.render(view, appearance: appearance, name: name, height: height)
            }
        }
    }

    /// Goldens for the track T panes in both appearances, under `Snapshots/ui-transcription/`. Same contract as track D:
    /// compared only with `VOICEBAR_SNAPSHOTS=1` on the reference host (Mac16,5, the M4), replaced only with
    /// `VOICEBAR_SNAPSHOTS_RECORD=1`; each RGBA channel tolerates 16/255 and at most 25 pixels may exceed it.
    func testGoldens() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["VOICEBAR_SNAPSHOTS"] == "1" else { throw XCTSkip("Pixel goldens: set VOICEBAR_SNAPSHOTS=1") }
        guard DictionaryNotchTrackDShotsTests.hostModel() == "Mac16,5" else {
            throw XCTSkip("SNAPSHOTS NOT COMPARED: references are from Mac16,5, this host is \(DictionaryNotchTrackDShotsTests.hostModel())")
        }
        let record = env["VOICEBAR_SNAPSHOTS_RECORD"] == "1"
        let references = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Snapshots/ui-transcription")
        try FileManager.default.createDirectory(at: references, withIntermediateDirectories: true)
        let updates = await Self.updates()
        for appearance in [VoiceBarNotchAppearance.dark, .light] {
            for (id, view, height) in Self.scenes(appearance, updates: updates) where !id.contains("-full-") {
                let actual = try Self.render(view, appearance: appearance, name: "golden-\(id)", height: height)
                let png = try XCTUnwrap(actual.representation(using: .png, properties: [:]))
                let reference = references.appendingPathComponent("\(id).png")
                if record { try png.write(to: reference) }
                let expected = try XCTUnwrap(NSBitmapImageRep(data: Data(contentsOf: reference)), "missing \(id)")
                let a = try DictionaryNotchTrackDShotsTests.rgba(actual)
                let e = try DictionaryNotchTrackDShotsTests.rgba(expected)
                var changed = Int.max
                if a.count == e.count {
                    changed = stride(from: 0, to: a.count, by: 4).filter { offset in
                        (0 ..< 4).contains { abs(Int(a[offset + $0]) - Int(e[offset + $0])) > 16 }
                    }.count
                }
                XCTAssertLessThanOrEqual(changed, 25, "\(id): \(changed) pixels changed")
            }
        }
    }
}
