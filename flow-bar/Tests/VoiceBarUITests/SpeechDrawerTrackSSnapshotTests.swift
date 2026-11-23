import AppKit
import OffscreenTestSupport
import SwiftUI
@testable import VoiceBarUI
import XCTest

/// 2.4.6 UI track S: the Speech tab as the notch drawer shows it, at the drawer's real width and default height, in
/// both appearances, with invented fixture data only. Writes PNGs only when `VOICEBAR_TRACK_S_PNG_DIR` is set.
@MainActor
final class SpeechDrawerTrackSSnapshotTests: XCTestCase {
    static let width: CGFloat = SettingsDrawerLaneSSnapshotTests.drawerWidth

    enum Scenario: String, CaseIterable {
        /// Engine running, both profiles on the fast voice: the everyday state.
        case running
        /// Engine stopped, the long profile on the cloned voice (fallback warning), rate locked by the environment.
        case stoppedLocked = "stopped-locked"
        /// A speech request failed: the notice and its Copy button.
        case notice
    }

    static func controls(_ scenario: Scenario) throws -> SpeechControlsState {
        var raw = SpeechSettingsTests.controls(rateSource: scenario == .stoppedLocked ? "environment" : "settings")
        raw["short_limit_chars"] = ["source": "settings", "raw": 400, "effective": 400]
        var profiles = raw["profiles"] as! [String: [String: Any]]
        profiles["long"]?["last_first_audio_ms"] = 1300
        if scenario == .stoppedLocked {
            profiles["long"]?["engine"] = ["source": "settings", "raw": "clone", "effective": "clone"]
            profiles["long"]?["voice"] = ["source": "settings", "raw": "theo-c4s", "effective": "theo-c4s"]
        }
        raw["profiles"] = profiles
        raw["clone_daemon"] = scenario == .running ? "up" : "down"
        return try XCTUnwrap(SpeechControlsState(controls: raw))
    }

    /// A fixed clock, so "Ready since" reads the same on every run (the goldens depend on it).
    static let now = ISO8601DateFormatter().date(from: "2026-11-23T10:00:00Z")!

    static func engine(_ scenario: Scenario) -> CloneEngineControlViewModel {
        let snapshot = CloneEngineSnapshot(state: scenario == .stoppedLocked ? .stopped : .running,
                                           since: "2026-11-23T09:00:00Z",
                                           reason: nil, pid: scenario == .stoppedLocked ? nil : 4242,
                                           startWithVoiceBar: true)
        return CloneEngineControlViewModel(snapshot: snapshot, send: { _ in true }, now: { now })
    }

    static func pane(_ scenario: Scenario) throws -> SettingsView {
        let controls = try controls(scenario)
        return SettingsView(
            hotkeyEnabled: true, missingPermissions: [], availableDevices: { [] }, selectedDeviceID: { nil },
            modelsStatus: { .loading }, onRefreshModelsStatus: {},
            speechControls: { controls }, speechConnected: { true }, speechBusyReason: { nil },
            speechNotice: { scenario == .notice ? "Couldn't complete the speech request: provider unavailable." : nil },
            onChangeSpeech: { _, _ in }, onSelectSpeechEngine: { _, _, _ in }, onPreviewSpeech: { _ in },
            cloneEngineControl: engine(scenario),
            vocabularyRevision: { 0 }, initialTab: .speech
        )
    }

    static func drawer(_ scenario: Scenario, appearance: VoiceBarNotchAppearance) throws -> some View {
        let pane = try pane(scenario)
        return NotchSettingsDrawer(
            selectedTab: .speech, appearance: appearance,
            context: NotchSettingsDrawerContext(updates: nil, pane: { tab, _ in
                AnyView(pane.notchDrawerPane(tab))
            }),
            onSelectTab: { _ in }
        )
    }

    /// The drawer's own glass is drawn by BarView; these stand-ins are the measured dark band and a light glass grey.
    static func glass(_ appearance: VoiceBarNotchAppearance) -> Color {
        appearance == .dark ? Color(white: 0.14) : Color(white: 0.90)
    }

    static func render(_ view: some View, appearance: VoiceBarNotchAppearance, height: CGFloat,
                       name: String) throws -> NSBitmapImageRep {
        let size = CGSize(width: width, height: height)
        let named: NSAppearance.Name = appearance == .dark ? .darkAqua : .aqua
        let framed = view.frame(width: size.width, height: size.height)
            .background(glass(appearance))
            .environment(\.colorScheme, appearance == .dark ? .dark : .light)
        let host = NSHostingView(rootView: framed)
        host.appearance = NSAppearance(named: named)
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: named)
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        VLOrderTestWindow(window)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(1.2))
        let bitmap = try EtanQA0510Tests.fixedScaleBitmap(host)
        if let dir = ProcessInfo.processInfo.environment["VOICEBAR_TRACK_S_PNG_DIR"], !dir.isEmpty {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            let url = URL(fileURLWithPath: dir).appendingPathComponent("\(name).png")
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url)
        }
        return bitmap
    }

    /// The drawer at its default height (what Etan sees when he opens the tab) and a tall render of the whole pane.
    func testRenderSpeechDrawer() throws {
        let prefix = ProcessInfo.processInfo.environment["VOICEBAR_TRACK_S_PREFIX"] ?? "speech"
        for scenario in Scenario.allCases {
            for appearance in [VoiceBarNotchAppearance.dark, .light] {
                let suffix = "\(scenario.rawValue)-\(appearance == .dark ? "dark" : "light")"
                _ = try Self.render(Self.drawer(scenario, appearance: appearance), appearance: appearance,
                                    height: NotchSettingsDrawerPresentation.lowerSurfaceHeight,
                                    name: "\(prefix)-drawer-\(suffix)")
                _ = try Self.render(Self.drawer(scenario, appearance: appearance), appearance: appearance,
                                    height: 1000, name: "\(prefix)-full-\(suffix)")
            }
        }
    }

    /// The brief's goal: at the drawer's default height the threshold draft and its actions sit inside the viewport,
    /// with no scrolling, in both appearances; and the pane paints one line per row (no old prose).
    func testThresholdDraftAndActionsFitTheDefaultDrawer() throws {
        for appearance in [VoiceBarNotchAppearance.dark, .light] {
            let height = NotchSettingsDrawerPresentation.lowerSurfaceHeight
            let bitmap = try Self.render(Self.drawer(.running, appearance: appearance), appearance: appearance,
                                         height: height, name: "viewport-check")
            let lines = try SettingsPolishS5Tests.ocr(bitmap)
            for word in ["voice threshold", "apply", "revert", "400", "restart", "stop", "start with voicebar"] {
                XCTAssertTrue(lines.contains { $0.contains(word) }, "[\(appearance)] '\(word)' not in view: \(lines)")
            }
            for prose in ["last reported cutoff", "a change here applies", "profile descriptions and revert", "draft"] {
                XCTAssertFalse(lines.contains { $0.contains(prose) }, "[\(appearance)] '\(prose)' still painted: \(lines)")
            }
        }
    }

    /// Notch rule 3: nothing in the Speech pane or the engine card paints system semantic ink on the glass. The window
    /// fallbacks go through `AnyShapeStyle(...)` behind a nil `notchPaneInk`, so a bare system style is a regression.
    func testSpeechSourcesUseNoBareSystemInk() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/VoiceBarUI")
        for file in ["SpeechSettingsView.swift", "CloneEngineSectionView.swift"] {
            let source = try String(contentsOf: root.appendingPathComponent(file), encoding: .utf8)
            for banned in [".foregroundStyle(.secondary)", ".foregroundStyle(.primary)", ".foregroundStyle(.tertiary)",
                           "accentColor", "textBackgroundColor", "quaternaryLabelColor", ".foregroundStyle(.red)",
                           ".foregroundStyle(.orange)", ".textFieldStyle(.roundedBorder)", "Button(\"Preview\")"] {
                XCTAssertFalse(source.contains(banned), "\(file) uses \(banned)")
            }
        }
    }

    /// Goldens for the Speech drawer in both appearances, under `Snapshots/ui-speech/`. Same contract as track D's:
    /// compared only with `VOICEBAR_SNAPSHOTS=1` on the reference host (Mac16,5), recorded with
    /// `VOICEBAR_SNAPSHOTS_RECORD=1`; each RGBA channel tolerates 16/255 and at most 25 pixels may exceed it.
    func testGoldens() throws {
        let env = ProcessInfo.processInfo.environment
        guard env["VOICEBAR_SNAPSHOTS"] == "1" else { throw XCTSkip("Pixel goldens: set VOICEBAR_SNAPSHOTS=1") }
        guard Self.hostModel() == "Mac16,5" else {
            throw XCTSkip("SNAPSHOTS NOT COMPARED: references are from Mac16,5, this host is \(Self.hostModel())")
        }
        let record = env["VOICEBAR_SNAPSHOTS_RECORD"] == "1"
        let references = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Snapshots/ui-speech")
        try FileManager.default.createDirectory(at: references, withIntermediateDirectories: true)
        for scenario in Scenario.allCases {
            for appearance in [VoiceBarNotchAppearance.dark, .light] {
                let id = "\(scenario.rawValue)-\(appearance == .dark ? "dark" : "light")"
                let actual = try Self.render(Self.drawer(scenario, appearance: appearance), appearance: appearance,
                                             height: 760, name: "golden-\(id)")
                let png = try XCTUnwrap(actual.representation(using: .png, properties: [:]))
                let reference = references.appendingPathComponent("\(id).png")
                if record { try png.write(to: reference) }
                let expected = try XCTUnwrap(NSBitmapImageRep(data: Data(contentsOf: reference)), "missing \(id)")
                let a = try Self.rgba(actual), e = try Self.rgba(expected)
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

    static func hostModel() -> String {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0 else { return "unavailable" }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &bytes, &size, nil, 0) == 0 else { return "unavailable" }
        return String(cString: bytes)
    }

    static func rgba(_ image: NSBitmapImageRep) throws -> [UInt8] {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: image.pixelsWide, height: image.pixelsHigh, bitsPerComponent: 8,
            bytesPerRow: image.pixelsWide * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(try XCTUnwrap(image.cgImage), in: CGRect(x: 0, y: 0, width: image.pixelsWide, height: image.pixelsHigh))
        return Array(UnsafeBufferPointer(start: try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self),
                                         count: image.pixelsWide * image.pixelsHigh * 4))
    }
}
