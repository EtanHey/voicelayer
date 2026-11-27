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

    static func pane(_ tab: SettingsTab, bindings: HotkeyBindingsModel? = nil) -> SettingsView {
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
            hotkeyBindings: bindings,
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

    /// GO-1126 W1 (centre the Dictionary rows): with a mouse attached macOS gives scroll views a legacy scroller,
    /// which took its width out of the list and left the rows ending short of the toolbar on one side. The list's
    /// scroller must come back as an overlay, so the rows span the drawer's full width. Fails on the old drawer.
    func testDictionaryRowsSpanTheToolbarWithAMouseScroller() throws {
        let size = CGSize(width: SettingsDrawerLaneSSnapshotTests.drawerWidth,
                          height: NotchSettingsDrawerPresentation.lowerSurfaceHeight)
        let host = NSHostingView(rootView: Self.drawer(.dictionary, .dark).frame(width: size.width, height: size.height)
            .background(DictionaryNotchTrackDShotsTests.backdrop(.dark)).environment(\.colorScheme, .dark))
        host.appearance = NSAppearance(named: .darkAqua)
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = host.appearance
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        VLOrderTestWindow(window)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        func scrollViews(_ view: NSView) -> [NSScrollView] {
            ((view as? NSScrollView).map { [$0] } ?? []) + view.subviews.flatMap(scrollViews)
        }
        let list = try XCTUnwrap(scrollViews(host).max { $0.frame.height < $1.frame.height }, "the term list")
        // A mouse: AppKit switches every scroll view to legacy and announces the preference change.
        scrollViews(host).forEach { $0.scrollerStyle = .legacy }
        NotificationCenter.default.post(name: NSScroller.preferredScrollerStyleDidChangeNotification, object: nil)
        host.needsLayout = true
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        XCTAssertEqual(list.scrollerStyle, .overlay, "the list's scroller overlays the rows")
        XCTAssertEqual(list.contentView.bounds.width, list.frame.width, accuracy: 0.5,
                       "the rows get the list's full width; no scroller gutter on one side")
        let bitmap = try EtanQA0510Tests.fixedScaleBitmap(host)
        if let dir = ProcessInfo.processInfo.environment["VOICEBAR_W1_PNG_DIR"], !dir.isEmpty {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                .write(to: URL(fileURLWithPath: dir).appendingPathComponent("w1-dictionary-mouse-dark.png"))
        }
    }

    /// L105 (slice B): General's Dictation section with the read-only F5 row it had before (no bindings input), with
    /// the key and mouse pickers at today's defaults, and rebound to F6 with Back acting like the key. Tall enough to
    /// reach the Dictation and Shortcuts sections.
    func testRenderRebindingRows() throws {
        func drawer(_ bindings: HotkeyBindingsModel?) -> some View {
            NotchSettingsDrawer(
                selectedTab: .general, appearance: .dark,
                context: NotchSettingsDrawerContext(updates: nil, pane: { tab, _ in
                    AnyView(Self.pane(tab, bindings: bindings).notchDrawerPane(tab))
                }),
                onSelectTab: { _ in }
            )
        }
        let rebound = VoiceBarHotkeyBindings(key: .f6, forward: .returnKey, back: .dictation)
        let cases: [(String, HotkeyBindingsModel?)] = [
            ("readonly", nil),
            ("defaults", HotkeyBindingsModel(bindings: .defaults, apply: { _, done in done(nil) })),
            ("rebound-f6", HotkeyBindingsModel(bindings: rebound, apply: { _, done in done(nil) })),
        ]
        for (name, input) in cases {
            let bitmap = try DictionaryNotchTrackDShotsTests.render(drawer(input), appearance: .dark,
                name: "w1-general-rebind-\(name)-dark", height: 1500, pngDirectoryVariable: "VOICEBAR_W1_PNG_DIR")
            XCTAssertGreaterThan(bitmap.pixelsWide, 0)
        }
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
