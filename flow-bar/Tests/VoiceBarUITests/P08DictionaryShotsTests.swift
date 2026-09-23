import AppKit
import SwiftUI
@testable import VoiceBarUI
import XCTest

@MainActor
final class P08DictionaryShotsTests: XCTestCase {
    func testRenderDictionaryStates() throws {
        guard let path = ProcessInfo.processInfo.environment["VOICEBAR_P08_SHOTS_DIR"] else {
            throw XCTSkip("Set VOICEBAR_P08_SHOTS_DIR to render P08 artifacts")
        }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let personal = [
            STTDictionaryEntry(canonical: "VoiceLayer", variants: ["voice lair", "voice layer"]),
            STTDictionaryEntry(canonical: "SwiftUI", variants: ["swift you eye"]),
            STTDictionaryEntry(canonical: "whisper.cpp", variants: []),
        ]
        let included = [
            STTDictionaryEntry(canonical: "AppKit", variants: []),
            STTDictionaryEntry(canonical: "macOS", variants: []),
        ]
        func preview(_ entries: [STTDictionaryEntry]) -> STTVocabularyPreview {
            STTVocabularyPreview(
                updatedAt: nil,
                entries: entries,
                displayEntries: entries.map { STTDictionaryDisplayEntry(source: "personal", entry: $0) }
                    + included.map { STTDictionaryDisplayEntry(source: "bundled", entry: $0) }
            )
        }
        for (scheme, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            try render(
                DictionaryAddSheetView(
                    draft: STTVocabularyDraft(correct: "VoiceLayer", wrong: "voice lair"),
                    allowTermOnly: true, onSave: { _ in }, onCancel: {}
                ).environment(\.colorScheme, scheme == "light" ? .light : .dark),
                appearance: NSAppearance(named: appearance),
                size: CGSize(width: 420, height: 240),
                to: directory.appendingPathComponent("dictionary-add-term-\(scheme).png")
            )
            for state in ["empty", "populated", "searching", "adding-variant", "collapsed"] {
                let data = state == "empty" ? preview([]) : preview(personal)
                let view = SettingsView(
                    hotkeyEnabled: true,
                    missingPermissions: [],
                    availableDevices: { [] },
                    selectedDeviceID: { nil },
                    onSelectDevice: { _ in },
                    modelsStatus: { .loading },
                    onRefreshModelsStatus: {},
                    vocabularyPreview: { data },
                    vocabularyRevision: { 0 },
                    initialTab: .dictionary,
                    initialDictionarySearch: state == "searching" ? "Swift" : "",
                    initialDictionaryPreview: data,
                    initialAddingVariantFor: state == "adding-variant" ? "VoiceLayer" : nil,
                    initialIncludedTermsExpanded: state == "populated"
                )
                try render(
                    view.environment(\.colorScheme, scheme == "light" ? .light : .dark),
                    appearance: NSAppearance(named: appearance),
                    to: directory.appendingPathComponent("dictionary-\(state)-\(scheme).png")
                )
            }
        }
    }

    private func render(
        _ view: some View, appearance: NSAppearance?,
        size: CGSize = CGSize(width: 780, height: 620), to url: URL
    ) throws {
        let host = NSHostingView(rootView: view
            .frame(width: size.width, height: size.height)
            .background(Color(nsColor: .windowBackgroundColor)))
        host.appearance = appearance
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.appearance = appearance
        window.backgroundColor = .windowBackgroundColor
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        host.layoutSubtreeIfNeeded()
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else {
            throw NSError(domain: "P08DictionaryShots", code: 1)
        }
        bitmap.size = size
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "P08DictionaryShots", code: 2)
        }
        try png.write(to: url, options: .atomic)
        window.contentView = nil
    }
}
