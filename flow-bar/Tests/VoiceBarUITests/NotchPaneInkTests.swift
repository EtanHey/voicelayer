import AppKit
import Vision
import SwiftUI
@testable import VoiceBarUI
import XCTest

/// 2.4.6 track D: the Dictionary pane and its Add / Edit sheets draw with the notch palette (Etan's 18 Nov notch
/// rules 2-3): notes in the teleprompter's read-tier ink, errors in a readable palette red, no system semantic
/// colours, and no material slab under the sheet in the drawer.
@MainActor
final class NotchPaneInkTests: XCTestCase {
    private func rgb(_ rgba: VoiceBarRGBA) -> VoiceBarRGB {
        VoiceBarRGB(red: rgba.red, green: rgba.green, blue: rgba.blue)
    }

    private func grey(_ value: Double) -> VoiceBarRGB { VoiceBarRGB(red: value / 255, green: value / 255, blue: value / 255) }

    func testErrorTextIsReadableOnBothGlasses() {
        let light = rgb(VoiceBarNotchContrastPalette.errorText(for: .light))
        let dark = rgb(VoiceBarNotchContrastPalette.errorText(for: .dark))
        // The light glass as the c9-P offscreen wing measured it (185), and a lighter 219; the dark glass at 41.
        for glass in [185.0, 219] {
            XCTAssertGreaterThanOrEqual(VoiceBarContrast.ratio(foreground: light, background: grey(glass)),
                                        VoiceBarContrast.minimumTextRatio, "light errorText on \(glass)")
        }
        XCTAssertGreaterThanOrEqual(VoiceBarContrast.ratio(foreground: dark, background: grey(41)),
                                    VoiceBarContrast.minimumTextRatio, "dark errorText")
        XCTAssertGreaterThan(dark.red, dark.green + 0.3, "still reads as red, not a pink-grey")
        XCTAssertGreaterThan(light.red, light.green + 0.3, "still reads as red, not a brown-grey")
    }

    /// The note ink as painted: palette primary at the note opacity, composited over the glass.
    private func noteOnGlass(_ appearance: VoiceBarNotchAppearance, glass: Double) -> VoiceBarRGB {
        let primary = VoiceBarNotchContrastPalette.resolve(for: appearance).primary
        let alpha = primary.alpha * NotchPaneInk.noteOpacity(appearance)
        let bg = glass / 255
        return VoiceBarRGB(red: primary.red * alpha + bg * (1 - alpha), green: primary.green * alpha + bg * (1 - alpha),
                           blue: primary.blue * alpha + bg * (1 - alpha))
    }

    /// Lead ruling (review fb68174ad P2): note ink reads at 4.5:1 or better on both glasses. Dark keeps the
    /// teleprompter read tier; light rises to 70 % because 64 % measured 3.96:1 on rgb 185.
    func testNoteInkIsReadableOnBothGlasses() {
        XCTAssertEqual(NotchPaneInk.noteOpacity(.dark), TeleprompterA.Tier.read.opacity, "dark keeps the read tier")
        XCTAssertEqual(NotchPaneInk.noteOpacity(.light), 0.70)
        for (appearance, glasses) in [(VoiceBarNotchAppearance.light, [185.0, 219]), (.dark, [35.0, 41])] {
            for glass in glasses {
                let ratio = VoiceBarContrast.ratio(foreground: noteOnGlass(appearance, glass: glass), background: grey(glass))
                XCTAssertGreaterThanOrEqual(ratio, VoiceBarContrast.minimumTextRatio, "\(appearance) note on \(glass): \(ratio)")
            }
        }
        // The departure is the lowest that passes: the read tier itself fails on the darker light glass.
        let primary = VoiceBarNotchContrastPalette.resolve(for: .light).primary
        let alpha = primary.alpha * TeleprompterA.Tier.read.opacity, bg = 185.0 / 255
        let readTier = VoiceBarRGB(red: primary.red * alpha + bg * (1 - alpha), green: primary.green * alpha + bg * (1 - alpha),
                                   blue: primary.blue * alpha + bg * (1 - alpha))
        XCTAssertLessThan(VoiceBarContrast.ratio(foreground: readTier, background: grey(185)), 4.5)
        XCTAssertEqual(NotchPaneInk(colorScheme: .light).appearance, .light)
        XCTAssertEqual(NotchPaneInk(colorScheme: .dark).appearance, .dark)
    }

    /// Review fb68174ad P2: the delete confirmation on glass uses the drawer capsules, Delete in errorText, and keeps
    /// its focus, Escape and Space handling. The overflow count carries no extra dimming.
    func testDeleteConfirmationUsesPaletteCapsules() throws {
        let text = try source("SettingsView.swift")
        let start = try XCTUnwrap(text.range(of: "            if let removal = termRemoval {"))
        let block = String(text[start.lowerBound...].prefix(2200))
        XCTAssertFalse(block.contains("Button(\"Cancel\")"))
        XCTAssertFalse(block.contains("Button(\"Delete\""))
        XCTAssertTrue(block.contains("NotchDrawerButton(title: \"Cancel\""))
        XCTAssertTrue(block.contains("NotchDrawerButton(title: \"Delete\""))
        XCTAssertTrue(block.contains("ink: removalInk.error"))
        XCTAssertTrue(block.contains(".keyboardShortcut(.cancelAction)"))
        XCTAssertTrue(block.contains(".focused($removalCancelFocused)"))
        XCTAssertTrue(block.contains(".onKeyPress(.space) { confirmTermRemoval(); return .handled }"))
        XCTAssertFalse(text.contains(".foregroundStyle(NotchInk.note).opacity("), "no extra dimming on note ink")
    }

    private func source(_ name: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/VoiceBarUI/\(name)")
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// The system colours the installed 2.4.5 sheet and list drew with (NOTCH-UI-GAPS rows Dictionary / Add / Edit).
    static let systemInk = [
        ".foregroundStyle(.secondary)", ".foregroundStyle(.primary)", ".foregroundStyle(.orange)", "Color.accentColor",
        "textBackgroundColor", "separatorColor", "quaternaryLabelColor", "windowBackgroundColor", ".background(.bar)",
        ".regularMaterial", "Divider()",
    ]

    func testTheSheetAndFieldsUseNoSystemInk() throws {
        for file in ["DictionaryAddSheetView.swift", "DictionaryTextFieldStyle.swift", "NotchPaneInk.swift"] {
            let text = try source(file)
            for token in Self.systemInk {
                XCTAssertFalse(text.contains(token), "\(file) still draws with \(token)")
            }
        }
    }

    func testTheDictionaryPaneUsesNoSystemInk() throws {
        let text = try source("SettingsView.swift")
        let start = try XCTUnwrap(text.range(of: "    private var dictionaryTab: some View {"))
        let end = try XCTUnwrap(text.range(of: "    private func confirmTermRemoval() {"))
        var pane = String(text[start.lowerBound ..< end.lowerBound])
        // The row's Copy/Delete menu is a system menu (not glass); its separator is the menu's own.
        pane = pane.replacingOccurrences(of: "                        Divider()\n                        Button(\"Delete…\"", with: "")
        for token in Self.systemInk {
            XCTAssertFalse(pane.contains(token), "the Dictionary pane still draws with \(token)")
        }
        XCTAssertFalse(pane.contains("SettingsPanePalette.helper"), "notes use NotchInk.note, the read tier")
    }

    func testTheDrawerEditorHasNoSlabAndHidesTheListBehindIt() throws {
        let text = try source("SettingsView.swift")
        let start = try XCTUnwrap(text.range(of: "struct DictionaryTermEditorPresentation"))
        let body = String(text[start.lowerBound...].prefix(1800))
        XCTAssertFalse(body.contains("Material"), "no material slab under the drawer editor")
        XCTAssertTrue(body.contains(".opacity(edit == nil ? 1 : 0)"))
        XCTAssertTrue(body.contains(".allowsHitTesting(edit == nil)"))
        XCTAssertTrue(body.contains(".accessibilityHidden(edit != nil)"))
    }

    /// Rendered proof: in the drawer with the Add sheet open, no list row paints through (the old sheet left the
    /// rows under it visible below a lighter slab).
    func testTheOpenSheetHidesEveryListRowInTheDrawer() throws {
        for appearance in [VoiceBarNotchAppearance.dark, .light] {
            let closed = try painted(DictionaryNotchTrackDShotsTests.drawer(appearance, sheet: nil), appearance)
            XCTAssertTrue(closed.contains { $0.contains("kestrel") }, "fixture rows paint when closed")
            let open = try painted(DictionaryNotchTrackDShotsTests.drawer(appearance, sheet: DictionaryTermEdit()),
                                   appearance)
            for row in ["kestrel", "tangelo", "wrenfield", "zephyrine"] {
                XCTAssertFalse(open.contains { $0.contains(row) }, "\(appearance): '\(row)' shows through the sheet")
            }
            XCTAssertTrue(open.contains { $0.contains("misheard as") }, "the sheet itself paints")
        }
    }

    private func painted(_ view: some View, _ appearance: VoiceBarNotchAppearance) throws -> [String] {
        let bitmap = try DictionaryNotchTrackDShotsTests.render(view, appearance: appearance, name: "ocr-scratch")
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: XCTUnwrap(bitmap.cgImage), options: [:]).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string.lowercased() }
    }
}
