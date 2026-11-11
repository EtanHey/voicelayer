import AppKit
import OffscreenTestSupport
import SwiftUI
@testable import VoiceBarUI
import XCTest

/// c7 lane S: renders the notch Settings drawer at Etan's real width (420 pt) for the before/after PNGs. Writes PNGs
/// only when `VOICEBAR_LANE_S_PNG_DIR` is set; otherwise it just checks every scenario renders.
@MainActor
final class SettingsDrawerLaneSSnapshotTests: XCTestCase {
    private final class NoLauncher: VoiceBarUpdateLaunching, @unchecked Sendable {
        var isAvailable = true
        func launch() throws {}
    }

    static let drawerWidth: CGFloat = 420

    static func micSnapshot() -> MicrophonePrioritySnapshot {
        MicrophonePrioritySnapshot(rows: [
            MicrophonePriorityRow(uid: "wireless", deviceID: "1", label: "Wireless Mic Rx", isConnected: false),
            MicrophonePriorityRow(uid: "builtin", deviceID: "2", label: "MacBook Pro Microphone", isConnected: true),
            MicrophonePriorityRow(uid: "airpods", deviceID: "3", label: "Master iPhone’s AirPods Pro #2", isConnected: false),
            MicrophonePriorityRow(uid: "usb", deviceID: "4", label: "USB Audio Device", isConnected: true),
        ], nextDeviceName: "MacBook Pro Microphone", nextDeviceUID: "builtin", nextDeviceID: "2")
    }

    private static func setting(_ effective: Any) -> [String: Any] {
        ["source": "default", "raw": NSNull(), "effective": effective]
    }

    static func modelsState() -> ModelsSettingsState {
        ModelsSettingsState(healthEvent: [
            "type": "health", "recording_state": "idle",
            "model_status": ["residency": "loaded", "configured_effort": "accurate",
                             "configured_model": ["name": "large-v3-turbo", "size_mb": 1600, "installed": true]],
            "polish_controls": ["model_polish": setting("on"), "outro_gate": setting(true),
                                "smart_chunks": setting(false)],
        ])
    }

    static func recognizer() -> RecognizerPickerState {
        RecognizerPickerState(selected: .parakeet, effective: .parakeet, parakeet: .loaded, whisper: .unloaded,
                              parakeetAvailable: true, parakeetAssetsPresent: true, whisperAssetsPresent: true,
                              diskBytes: [.parakeet: 2_509_000_000, .whisper: 1_620_000_000], downloads: [:],
                              idleUnloadSeconds: 300, unloadWhenIdle: RecognizerUnloadWhenIdle(effective: false))
    }

    static func pane(_ tab: SettingsTab, advanced: Bool) -> SettingsView {
        SettingsView(
            hotkeyEnabled: true, missingPermissions: [],
            availableDevices: { [MicrophoneDevice(id: "2", name: "MacBook Pro Microphone")] },
            selectedDeviceID: { "2" },
            prioritySnapshot: { micSnapshot() },
            modelsStatus: { modelsState() }, onRefreshModelsStatus: {},
            recognizerStatus: { recognizer() },
            onReadClipboard: {},
            onToggleProcessing: { _, _ in },
            vocabularyPreview: { STTVocabularyPreview(updatedAt: nil, entries: []) }, vocabularyRevision: { 0 },
            openAtLogin: SettingsToggleInput(isOn: { true }, set: { _ in }),
            mouseSideButtons: SettingsToggleInput(isOn: { true }, set: { _ in }),
            initialTab: tab,
            initialAdvancedExpanded: advanced
        )
    }

    static func updates() async -> NotchUpdateController {
        let controller = NotchUpdateController(
            installed: .init(version: "2.4.0", commit: "8e1d535"),
            describe: VoiceBarGitDescribe(releaseVersion: "2.2.61", commitsAhead: 219),
            check: VoiceBarVersionCheck(fetch: { "cask \"voicebar\" do\n  version \"2.2.61\"\nend\n" }),
            launcher: NoLauncher(), isDictating: { false }
        )
        await controller.checkForUpdates()
        return controller
    }

    static func drawer(_ tab: SettingsTab, advanced: Bool = false, updates: NotchUpdateController?) -> some View {
        NotchSettingsDrawer(
            selectedTab: tab, appearance: .dark,
            context: NotchSettingsDrawerContext(updates: updates, pane: { tab, _ in
                AnyView(pane(tab, advanced: advanced).notchDrawerPane(tab))
            }),
            onSelectTab: { _ in }
        )
    }

    static func render(_ view: some View, height: CGFloat, name: String, scrollToEnd: Bool = false) throws
        -> NSBitmapImageRep {
        let size = CGSize(width: drawerWidth, height: height)
        let framed = view.frame(width: size.width, height: size.height)
            .background(Color(white: 0.16))
            .environment(\.colorScheme, .dark)
        let host = NSHostingView(rootView: framed)
        host.appearance = NSAppearance(named: .darkAqua)
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        VLOrderTestWindow(window)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(1.2))
        if scrollToEnd, let scroll = scrollViews(in: host).first, let document = scroll.documentView {
            let clip = scroll.contentView
            let y = document.isFlipped ? max(0, document.bounds.height - clip.bounds.height) : 0
            clip.scroll(to: NSPoint(x: clip.bounds.minX, y: y))
            scroll.reflectScrolledClipView(clip)
            RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        }
        let bitmap = try EtanQA0510Tests.fixedScaleBitmap(host)
        if let dir = ProcessInfo.processInfo.environment["VOICEBAR_LANE_S_PNG_DIR"], !dir.isEmpty {
            let url = URL(fileURLWithPath: dir).appendingPathComponent("\(name).png")
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url)
        }
        return bitmap
    }

    func testRenderLaneSScenarios() async throws {
        let updates = await Self.updates()
        _ = try Self.render(Self.drawer(.general, updates: updates), height: 470, name: "mic-rows")
        _ = try Self.render(Self.drawer(.general, advanced: true, updates: updates), height: 1500, name: "general")
        _ = try Self.render(Self.drawer(.transcription, updates: nil), height: 1100, name: "transcription")
        // The drawer at its real height (default rows), scrolled to the end: the gap under the last card is the
        // Form's own bottom margin, not the empty band the tall 1500 pt render shows (lead review, c7 07:55Z).
        _ = try Self.render(Self.drawer(.general, advanced: true, updates: updates),
                            height: NotchSettingsDrawerPresentation.lowerSurfaceHeight, name: "general-real-height-end",
                            scrollToEnd: true)
        _ = try Self.render(Self.drawer(.speech, updates: nil), height: 700, name: "speech")
        _ = try Self.render(Self.drawer(.dictionary, updates: nil), height: 700, name: "dictionary")
        _ = try Self.render(Self.drawer(.general, updates: updates)
            .environment(\.settingsHoverPreview, SettingsHoverPreview(microphoneRow: 1)), height: 470, name: "mic-rows-hover")
        _ = try Self.render(Self.drawer(.transcription, updates: nil)
            .environment(\.settingsHoverPreview, SettingsHoverPreview(lockedReasons: true)), height: 1100,
            name: "transcription-hover")
    }

    /// Shots 1-2, hover: Make default appears in the row's trailing column, in space the row always held, so nothing moves.
    func testHoverRevealsMakeDefaultOnTheNameLineAndMovesNothing() async throws {
        let updates = await Self.updates()
        let rest = try SettingsDrawerLaneSLayoutTests.paintedLines(Self.drawer(.general, updates: updates), height: 470)
        let hover = try SettingsDrawerLaneSLayoutTests.paintedLines(Self.drawer(.general, updates: updates)
            .environment(\.settingsHoverPreview, SettingsHoverPreview(microphoneRow: 1)), height: 470)
        XCTAssertFalse(rest.contains { $0.text.contains("make default") }, "hidden at rest")
        let button = try SettingsDrawerLaneSLayoutTests.line(hover, containing: "make default")
        for text in ["macbook pro microphone", "used for dictation", "airpods", "usb audio device"] {
            let before = try SettingsDrawerLaneSLayoutTests.line(rest, containing: text).box
            let after = try SettingsDrawerLaneSLayoutTests.line(hover, containing: text).box
            XCTAssertEqual(before.minY, after.minY, accuracy: 1.5, "[S1] '\(text)' moved on hover")
        }
        let title = try SettingsDrawerLaneSLayoutTests.line(hover, containing: "macbook pro microphone").box
        let status = try SettingsDrawerLaneSLayoutTests.line(hover, containing: "used for dictation").box
        XCTAssertGreaterThan(button.box.maxY, title.minY, "[S1] Make default is on the row, not under it")
        XCTAssertLessThan(button.box.minY, status.maxY, "[S1] Make default is on the row, not under it")
        XCTAssertGreaterThan(button.box.minX, title.maxX, "[S1] and to its right, in the trailing column")
    }

    /// Shot 5, hover: the reason appears just above the switch and covers nothing on the row: the title, the
    /// Experimental badge and the description all stay readable (lead review, c7 07:55Z).
    func testHoveringTheLockedSwitchShowsWhyAboveItCoveringNothing() throws {
        let lines = try SettingsDrawerLaneSLayoutTests.paintedLines(Self.drawer(.transcription, updates: nil)
            .environment(\.settingsHoverPreview, SettingsHoverPreview(lockedReasons: true)), height: 1100)
        let reason = try SettingsDrawerLaneSLayoutTests.line(lines, containing: "unavailable with parakeet")
        let title = try SettingsDrawerLaneSLayoutTests.line(lines, containing: "smart chunks")
        let badge = try SettingsDrawerLaneSLayoutTests.line(lines, containing: "experimental")
        let description = try SettingsDrawerLaneSLayoutTests.line(lines, containing: "splits long")
        XCTAssertLessThan(reason.box.maxY, title.box.minY + 2, "[S4] the bubble sits above the switch's row line")
        XCTAssertGreaterThan(reason.box.maxX, Self.drawerWidth * 0.6, "[S4] anchored at the switch, trailing side")
        for word in [title, badge, description] {
            XCTAssertFalse(reason.box.intersects(word.box), "[S4] the bubble covers '\(word.text)'")
        }
    }

    static func scrollViews(in view: NSView) -> [NSScrollView] {
        if let scroll = view as? NSScrollView { return [scroll] }
        return view.subviews.flatMap(scrollViews(in:))
    }

    /// Item 3: the widened Form's overlay scroller is moved back inside the visible pane (19 pt from the scroll
    /// view's right edge, which sits 20 pt past the pane's clip), so cancelling the gutter never hides it.
    func testTheWidenedFormKeepsItsScrollerInsideThePane() throws {
        let size = CGSize(width: Self.drawerWidth, height: 470)
        let host = NSHostingView(rootView: Self.drawer(.general, updates: nil).frame(width: size.width, height: size.height))
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered,
                              defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        VLOrderTestWindow(window)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(1.0))
        let scroll = try XCTUnwrap(Self.scrollViews(in: host).first, "the General Form scrolls")
        XCTAssertEqual(scroll.scrollerInsets.right, NotchSettingsDrawerPresentation.groupedFormInset - 1,
                       "[S3] the scroller is inset back inside the visible pane")
        let frame = scroll.convert(scroll.bounds, to: host)
        XCTAssertEqual(frame.width, size.width - 2 * NotchSettingsDrawerPresentation.horizontalInset
                       + 2 * NotchSettingsDrawerPresentation.groupedFormInset, accuracy: 1,
                       "[S3] the Form is widened by its inset on both sides")
    }
}
