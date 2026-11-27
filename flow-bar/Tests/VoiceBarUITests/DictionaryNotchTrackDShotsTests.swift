import AppKit
import OffscreenTestSupport
import SwiftUI
import Vision
@testable import VoiceBarUI
import XCTest

/// 2.4.6 UI track D: the Dictionary pane and its Add / Edit term sheets inside the notch Settings drawer, at the
/// drawer's real width and default height, in both appearances. Invented terms only. Writes PNGs only when
/// `VOICEBAR_TRACK_D_PNG_DIR` is set; otherwise it checks every scenario renders.
@MainActor
final class DictionaryNotchTrackDShotsTests: XCTestCase {
    static let personal = [
        STTDictionaryEntry(canonical: "Kestrel", variants: []),
        STTDictionaryEntry(canonical: "Quillfeather", variants: ["quill feather", "quill father", "quillfether"]),
        STTDictionaryEntry(canonical: "Marlowe Grid", variants: ["marlow grid"]),
        STTDictionaryEntry(canonical: "Orbitron", variants: []),
        STTDictionaryEntry(canonical: "Tangelo API", variants: ["tangelo a p i", "tangle o api"]),
        STTDictionaryEntry(canonical: "Wrenfield", variants: []),
        STTDictionaryEntry(canonical: "Zephyrine", variants: ["zephyr in"]),
    ]
    static let included = [
        STTDictionaryEntry(canonical: "AppKit", variants: []),
        STTDictionaryEntry(canonical: "macOS", variants: []),
    ]

    static func preview() -> STTVocabularyPreview {
        STTVocabularyPreview(
            updatedAt: nil, entries: personal,
            displayEntries: personal.map { STTDictionaryDisplayEntry(source: "personal", entry: $0) }
                + included.map { STTDictionaryDisplayEntry(source: "bundled", entry: $0) }
        )
    }

    static func pane(sheet: DictionaryTermEdit?, search: String = "", selected: String? = nil) -> SettingsView {
        let data = preview()
        return SettingsView(
            hotkeyEnabled: true, missingPermissions: [],
            availableDevices: { [] }, selectedDeviceID: { nil },
            modelsStatus: { .loading }, onRefreshModelsStatus: {},
            vocabularyPreview: { data }, vocabularyRevision: { 0 },
            initialTab: .dictionary, initialDictionarySearch: search, initialDictionaryPreview: data,
            initialSelectedTermRowID: selected, initialTermSheet: sheet
        )
    }

    static func drawer(_ appearance: VoiceBarNotchAppearance, sheet: DictionaryTermEdit?, search: String = "",
                       selected: String? = nil) -> some View {
        NotchSettingsDrawer(
            selectedTab: .dictionary, appearance: appearance,
            context: NotchSettingsDrawerContext(updates: nil, pane: { tab, _ in
                AnyView(pane(sheet: sheet, search: search, selected: selected).notchDrawerPane(tab))
            }),
            onSelectTab: { _ in }
        )
    }

    /// The notch glass stand-ins: the lane S dark backdrop, and a light grey for the light glass.
    static func backdrop(_ appearance: VoiceBarNotchAppearance) -> Color {
        appearance == .dark ? Color(white: 0.16) : Color(white: 0.86)
    }

    @discardableResult
    static func render(_ view: some View, appearance: VoiceBarNotchAppearance, name: String,
                       height: CGFloat = NotchSettingsDrawerPresentation.lowerSurfaceHeight,
                       pngDirectoryVariable: String = "VOICEBAR_TRACK_D_PNG_DIR") throws -> NSBitmapImageRep {
        let size = CGSize(width: SettingsDrawerLaneSSnapshotTests.drawerWidth, height: height)
        let scheme: ColorScheme = appearance == .dark ? .dark : .light
        let nsAppearance = NSAppearance(named: appearance == .dark ? .darkAqua : .aqua)
        let framed = view.frame(width: size.width, height: size.height)
            .background(backdrop(appearance))
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
        if let dir = ProcessInfo.processInfo.environment[pngDirectoryVariable], !dir.isEmpty {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            let url = URL(fileURLWithPath: dir).appendingPathComponent("\(name).png")
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url)
        }
        return bitmap
    }

    static let editing: DictionaryTermEdit = {
        var edit = DictionaryTermEdit(original: personal[1])
        edit.wrong = "quil feather"
        return edit
    }()

    /// A misheard spelling that already belongs to another term: the sheet's blocking error.
    static let conflicting = DictionaryTermEdit(correct: "Orbitron", wrong: "wrenfield")

    func testRenderTrackDScenarios() throws {
        for appearance in [VoiceBarNotchAppearance.dark, .light] {
            let suffix = appearance == .dark ? "dark" : "light"
            try Self.render(Self.drawer(appearance, sheet: nil, selected: "personal:Marlowe Grid"),
                            appearance: appearance, name: "dictionary-\(suffix)")
            try Self.render(Self.drawer(appearance, sheet: nil, search: "quill"),
                            appearance: appearance, name: "dictionary-search-\(suffix)")
            try Self.render(Self.drawer(appearance, sheet: DictionaryTermEdit()),
                            appearance: appearance, name: "add-term-\(suffix)")
            try Self.render(Self.drawer(appearance, sheet: Self.editing),
                            appearance: appearance, name: "edit-term-\(suffix)")
            try Self.render(Self.drawer(appearance, sheet: Self.conflicting),
                            appearance: appearance, name: "add-term-error-\(suffix)")
        }
    }

    /// Goldens for the five track D panes in both appearances, under `Snapshots/ui-dictionary/`. Same contract as the
    /// synthetic catalog: compared only with `VOICEBAR_SNAPSHOTS=1` on the reference host (Mac16,5, the M4), replaced
    /// only with `VOICEBAR_SNAPSHOTS_RECORD=1`; each RGBA channel tolerates 16/255 and at most 25 pixels may exceed it.
    func testGoldens() throws {
        let env = ProcessInfo.processInfo.environment
        guard env["VOICEBAR_SNAPSHOTS"] == "1" else { throw XCTSkip("Pixel goldens: set VOICEBAR_SNAPSHOTS=1") }
        guard Self.hostModel() == "Mac16,5" else {
            throw XCTSkip("SNAPSHOTS NOT COMPARED: references are from Mac16,5, this host is \(Self.hostModel())")
        }
        let record = env["VOICEBAR_SNAPSHOTS_RECORD"] == "1"
        let references = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Snapshots/ui-dictionary")
        try FileManager.default.createDirectory(at: references, withIntermediateDirectories: true)
        for appearance in [VoiceBarNotchAppearance.dark, .light] {
            let suffix = appearance == .dark ? "dark" : "light"
            let scenes: [(String, AnyView)] = [
                ("dictionary", AnyView(Self.drawer(appearance, sheet: nil, selected: "personal:Marlowe Grid"))),
                ("add-term", AnyView(Self.drawer(appearance, sheet: DictionaryTermEdit()))),
                ("edit-term", AnyView(Self.drawer(appearance, sheet: Self.editing))),
                ("add-term-error", AnyView(Self.drawer(appearance, sheet: Self.conflicting))),
            ]
            for (name, view) in scenes {
                let id = "\(name)-\(suffix)"
                let actual = try Self.render(view, appearance: appearance, name: "golden-\(id)")
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

    /// Taste review P1 (6f45b985e): placeholders painted at primary ink, so empty fields looked filled. Each
    /// placeholder's glyph cores must sit at the note tier: nearer note ink than primary ink, as composited over the
    /// field well on the glass, in both appearances.
    func testPlaceholdersPaintAtNoteInkNotPrimary() throws {
        for appearance in [VoiceBarNotchAppearance.dark, .light] {
            let suffix = appearance == .dark ? "dark" : "light"
            let cases: [(String, AnyView, String)] = [
                ("add-term", AnyView(Self.drawer(appearance, sheet: DictionaryTermEdit())), "intended text"),
                ("add-term", AnyView(Self.drawer(appearance, sheet: DictionaryTermEdit())), "misheard text"),
                ("dictionary", AnyView(Self.drawer(appearance, sheet: nil)), "search terms"),
            ]
            let palette = VoiceBarNotchContrastPalette.resolve(for: appearance)
            let glass = appearance == .dark ? 0.16 : 0.86
            // The well: palette primary at 8 % over the glass. Then a glyph at `alpha` of primary over the well.
            let primaryGrey = (palette.primary.red + palette.primary.green + palette.primary.blue) / 3
            let well = glass + (primaryGrey - glass) * palette.primary.alpha * 0.08
            func ink(_ opacity: Double) -> Double { (well + (primaryGrey - well) * palette.primary.alpha * opacity) * 255 }
            let note = ink(NotchPaneInk.noteOpacity(appearance)), primary = ink(1)
            for (name, view, text) in cases {
                let bitmap = try Self.render(view, appearance: appearance, name: "placeholder-\(name)-\(suffix)")
                let box = try Self.ocrBox(bitmap, containing: text)
                var extreme = appearance == .dark ? 0.0 : 255.0
                for y in Int(box.minY) ..< Int(box.maxY) {
                    for x in Int(box.minX) ..< Int(box.maxX) {
                        guard let c = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                        let grey = (c.redComponent + c.greenComponent + c.blueComponent) / 3 * 255
                        extreme = appearance == .dark ? max(extreme, grey) : min(extreme, grey)
                    }
                }
                XCTAssertLessThan(abs(extreme - note), abs(extreme - primary),
                                  "\(suffix) '\(text)' paints at \(extreme), note \(note), primary \(primary)")
            }
        }
    }

    /// The pixel box (bitmap coordinates, top-left origin) of the first OCR line containing `text`.
    static func ocrBox(_ bitmap: NSBitmapImageRep, containing text: String) throws -> CGRect {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: XCTUnwrap(bitmap.cgImage), options: [:]).perform([request])
        let hit = try XCTUnwrap((request.results ?? []).first {
            $0.topCandidates(1).first?.string.lowercased().contains(text) == true
        }, "OCR did not read '\(text)'")
        let w = Double(bitmap.pixelsWide), h = Double(bitmap.pixelsHigh), b = hit.boundingBox
        return CGRect(x: b.minX * w, y: (1 - b.maxY) * h, width: b.width * w, height: b.height * h)
    }
}
