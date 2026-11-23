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

    /// `fg` at `alpha` laid over `bg`.
    private func over(_ fg: VoiceBarRGBA, alpha: Double, _ bg: VoiceBarRGB) -> VoiceBarRGB {
        VoiceBarRGBA(red: fg.red, green: fg.green, blue: fg.blue, alpha: alpha).composited(over: bg)
    }

    /// The glasses each appearance is checked on: the c9-P offscreen wing's light glass (185) and a lighter 219; the
    /// dark glass at 35 and 41.
    private static let glasses: [(VoiceBarNotchAppearance, [Double])] = [(.light, [185, 219]), (.dark, [35, 41])]

    func testErrorTextIsReadableOnBothGlasses() {
        for (appearance, glasses) in Self.glasses {
            let error = rgb(VoiceBarNotchContrastPalette.errorText(for: appearance))
            for glass in glasses {
                let ratio = VoiceBarContrast.ratio(foreground: error, background: grey(glass))
                XCTAssertGreaterThanOrEqual(ratio, VoiceBarContrast.minimumTextRatio, "\(appearance) errorText on \(glass): \(ratio)")
            }
            XCTAssertGreaterThan(error.red, error.green + 0.3, "\(appearance) errorText still reads as red")
        }
    }

    /// #968 CodeRabbit: Delete draws errorText on the prominent drawer capsule over the confirmation bar. The whole
    /// stack (glass, `barFill`, capsule) must keep 4.5:1 in both appearances, and so must the Transcription pane's
    /// Delete (resting capsule on its error-tinted plate).
    func testErrorTextIsReadableOnTheDeleteCapsuleStack() {
        for (appearance, glasses) in Self.glasses {
            let palette = VoiceBarNotchContrastPalette.resolve(for: appearance)
            let errorRGBA = VoiceBarNotchContrastPalette.errorText(for: appearance)
            let error = rgb(errorRGBA)
            for glass in glasses {
                let bar = palette.surfaceTint.composited(over: grey(glass))
                let prominent = palette.primary.alpha * NotchDrawerButton.fillOpacity(prominent: true)
                let resting = palette.primary.alpha * NotchDrawerButton.fillOpacity(prominent: false)
                let stacks: [(String, VoiceBarRGB)] = [
                    // Dictionary's Delete: prominent capsule on the confirmation bar.
                    ("bar + prominent capsule", over(palette.primary, alpha: prominent, bar)),
                    // Transcription's Delete: resting capsule on the error-tinted confirmation plate.
                    ("error plate + resting capsule",
                     over(palette.primary, alpha: resting, over(errorRGBA, alpha: 0.10, grey(glass)))),
                    ("glass + resting capsule", over(palette.primary, alpha: resting, grey(glass))),
                ]
                for (name, background) in stacks {
                    let ratio = VoiceBarContrast.ratio(foreground: error, background: background)
                    XCTAssertGreaterThanOrEqual(ratio, VoiceBarContrast.minimumTextRatio,
                                                "\(appearance) errorText on \(name) over \(glass): \(ratio)")
                }
            }
        }
    }

    /// The note ink as painted: palette primary at the note opacity, over `surface`.
    private func note(_ appearance: VoiceBarNotchAppearance, on surface: VoiceBarRGB) -> VoiceBarRGB {
        let primary = VoiceBarNotchContrastPalette.resolve(for: appearance).primary
        return over(primary, alpha: primary.alpha * NotchPaneInk.noteOpacity(appearance), surface)
    }

    /// Lead ruling (review fb68174ad P2) and #968 CodeRabbit: note ink reads at 4.5:1 or better on both glasses, bare
    /// and on every fill it is drawn on (field well, selected row, control plate). Dark keeps the teleprompter read
    /// tier; light rises to 76 %.
    func testNoteInkIsReadableOnBothGlassesAndTheirFills() {
        XCTAssertEqual(NotchPaneInk.noteOpacity(.dark), TeleprompterA.Tier.read.opacity, "dark keeps the read tier")
        XCTAssertEqual(NotchPaneInk.noteOpacity(.light), 0.76)
        XCTAssertEqual(NotchPaneInk.noteSurfaceFillOpacities, [0, 0.08, 0.10, 0.12])
        for (appearance, glasses) in Self.glasses {
            let primary = VoiceBarNotchContrastPalette.resolve(for: appearance).primary
            for glass in glasses {
                for fill in NotchPaneInk.noteSurfaceFillOpacities {
                    let surface = over(primary, alpha: primary.alpha * fill, grey(glass))
                    let ratio = VoiceBarContrast.ratio(foreground: note(appearance, on: surface), background: surface)
                    XCTAssertGreaterThanOrEqual(ratio, VoiceBarContrast.minimumTextRatio,
                                                "\(appearance) note on fill \(fill) over \(glass): \(ratio)")
                }
            }
        }
        // Why light departs: the read tier fails on the darker light glass even bare.
        let primary = VoiceBarNotchContrastPalette.resolve(for: .light).primary
        let readTier = over(primary, alpha: primary.alpha * TeleprompterA.Tier.read.opacity, grey(185))
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

    /// #968 CI (macOS 26) and Etan's M1: a native prompt painted `Color.clear` still drew at primary ink before macOS 27.
    /// No Dictionary field carries a native prompt or title; each keeps an explicit accessibility label, and the
    /// placeholder reaches VoiceOver as the field's hint.
    func testDictionaryFieldsCarryNoNativePrompt() throws {
        for file in ["SettingsView.swift", "DictionaryAddSheetView.swift", "DictionaryTextFieldStyle.swift"] {
            let text = try source(file)
            XCTAssertFalse(text.contains("dictionaryPrompt("), "\(file) still builds a native prompt")
            XCTAssertFalse(text.contains("TextField(\"\", text: $dictionarySearch, prompt:"), file)
        }
        let sheet = try source("DictionaryAddSheetView.swift")
        XCTAssertFalse(sheet.contains("prompt:"), "the Add/Edit fields carry no native prompt")
        XCTAssertTrue(sheet.contains(".accessibilityLabel(\"Correct spelling\")"))
        XCTAssertTrue(sheet.contains(".accessibilityLabel(\"Misheard as\")"))
        XCTAssertTrue(try source("SettingsView.swift").contains(".accessibilityLabel(\"Search your dictionary\")"))
        XCTAssertTrue(try source("DictionaryTextFieldStyle.swift").contains(".accessibilityHint(isEmpty ? placeholder : \"\")"))
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
