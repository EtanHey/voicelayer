import AppKit
import SwiftUI
@testable import VoiceBarUI
import XCTest

/// U3b UI assessment crops: Settings › Dictionary and › Speech rendered offscreen at a fixed 800 × 640 pt (the window minimum is 780 × 620), 1:1 (one
/// image pixel per point, never scaled), light and dark. Written to `docs.local/u3b/crops/after/`. Gated like the
/// other visual artifacts (VOICEBAR_REGENERATE_VISUAL_ARTIFACTS=1). Rows are synthetic, never Etan's dictionary.
@MainActor
final class U3bVisualArtifactTests: XCTestCase {
    static let size = CGSize(width: 800, height: 640)
    static let preview = STTVocabularyPreview(updatedAt: nil, entries: [], displayEntries: [
        .init(source: "personal", entry: STTDictionaryEntry(canonical: "VoiceLayer", variants: ["voice layer", "voice lair"])),
        .init(source: "personal", entry: STTDictionaryEntry(canonical: "SwiftUI", variants: [])),
        .init(source: "personal", entry: STTDictionaryEntry(
            canonical: "Kubernetes", variants: ["cube netties", "kuber nettis", "cooper nettys", "kubernetis"])),
        .init(source: "bundled", entry: STTDictionaryEntry(canonical: "Figma", variants: [])),
        .init(source: "bundled", entry: STTDictionaryEntry(canonical: "React Native", variants: [])),
        .init(source: "bundled", entry: STTDictionaryEntry(canonical: "Svelte", variants: [])),
    ])

    func testWritesDictionaryAndSpeechCrops() throws {
        try VisualArtifactTestPolicy.requireRegeneration()
        let directory = Self.outputDirectory("after")
        for dark in [false, true] {
            let scheme = dark ? "dark" : "light"
            try Self.render(Self.settings(.dictionary), dark: dark, named: "1-dictionary-\(scheme)", in: directory)
            try Self.render(Self.settings(.dictionary), dark: dark, named: "2-dictionary-no-match-\(scheme)",
                            in: directory, search: "kubectl")
            for (index, (name, snapshot)) in Self.engineStates.enumerated() {
                let model = CloneEngineControlViewModel(snapshot: snapshot, send: { _ in true })
                try Self.render(Self.settings(.speech, cloneEngine: model), dark: dark,
                                named: "\(3 + index)-speech-\(name)-\(scheme)", in: directory)
            }
        }
    }

    static let engineStates: [(String, CloneEngineSnapshot?)] = [
        ("running", .init(state: .running, since: "2026-11-05T09:14:00Z", reason: nil, pid: 4242, startWithVoiceBar: true)),
        ("starting", .init(state: .starting, since: "2026-11-05T09:14:00Z", reason: nil, pid: 4242, startWithVoiceBar: true)),
        ("failed", .init(state: .failed, since: "2026-11-05T09:14:00Z", reason: "python_missing", pid: nil,
                         startWithVoiceBar: true)),
        ("unavailable", nil),
    ]

    static func settings(_ tab: SettingsTab, cloneEngine: CloneEngineControlViewModel? = nil) -> SettingsView {
        SettingsView(
            hotkeyEnabled: true, missingPermissions: [], availableDevices: { [] }, selectedDeviceID: { nil },
            modelsStatus: { .loading }, onRefreshModelsStatus: {}, cloneEngineControl: cloneEngine,
            vocabularyPreview: { preview }, vocabularyRevision: { 0 }, initialTab: tab
        )
    }

    static func outputDirectory(_ phase: String) -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("docs.local/u3b/crops/\(phase)")
    }

    static func render(_ view: SettingsView, dark: Bool, named name: String, in directory: URL,
                       search: String? = nil) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let window = NSWindow(contentRect: NSRect(origin: CGPoint(x: -20_000, y: -20_000), size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        host.frame = NSRect(origin: .zero, size: size)
        window.contentView = host
        defer { window.orderOut(nil) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))  // the dictionary loads on a detached task
        if let search, let field = textFields(in: host).first(where: \.isEditable),
           window.makeFirstResponder(field), let editor = window.firstResponder as? NSTextView {
            editor.insertText(search, replacementRange: editor.selectedRange())
            window.makeFirstResponder(nil)
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        }
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height), bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0,
            bitsPerPixel: 0))
        bitmap.size = size
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: directory.appendingPathComponent("\(name).png"), options: .atomic)
    }

    static func textFields(in view: NSView) -> [NSTextField] {
        let own: [NSTextField] = (view as? NSTextField).map { [$0] } ?? []
        return own + view.subviews.flatMap { textFields(in: $0) }
    }
}
