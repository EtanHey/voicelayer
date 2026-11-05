import AppKit
import SwiftUI
@testable import VoiceBarUI
import XCTest

/// One Settings row as the pane draws it: its copy, whether it has a leading mark, and its real trailing controls.
struct SettingsRowCase {
    let title: String
    let description: String?
    var hasLead = false
    let controls: AnyView

    @MainActor static func button(_ title: String) -> AnyView { AnyView(Button(title) {}.buttonStyle(.bordered)) }
    @MainActor static var toggle: AnyView {
        AnyView(Toggle("", isOn: .constant(true)).labelsHidden().toggleStyle(.switch))
    }
}

/// V12 row-clipping guard, frame rendering and the contrast measurements shared by the Settings pane tests.
@MainActor
enum SettingsRowClippingGuard {
    static let windowWidths: [CGFloat] = [720, 390]

    /// Pane content width for a window of that width: the 188 pt sidebar, or the 52 pt icon rail below 480 pt.
    static func paneWidth(window: CGFloat) -> CGFloat { window - (window < 480 ? 52 : 188) }
    /// The grouped Form's section inset plus the row's own padding, on each side.
    static let formInset: CGFloat = 30

    private static func height(_ view: some View, width: CGFloat) -> CGFloat {
        NSHostingView(rootView: view.frame(width: width).fixedSize(horizontal: false, vertical: true)).fittingSize.height
    }

    private static func textHeight(_ text: String, _ font: Font, width: CGFloat, lines: Int?) -> CGFloat {
        height(Text(text).font(font).lineLimit(lines).truncationMode(.tail)
            .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading), width: width)
    }

    /// Every row shows its title and description on up to two lines each: never fewer than the text needs (no
    /// one-line clip, no ellipsis before line 2) and never more (the ellipsis comes after line 2). Trailing controls
    /// never squeeze the text column below its minimum; they wrap under it.
    static func check(_ rows: [SettingsRowCase], file: StaticString = #filePath, line: UInt = #line) {
        let leadWidth = NSHostingView(rootView: SettingsSetupMark(isDone: false)).fittingSize.width + 8
        for window in windowWidths {
            let width = paneWidth(window: window) - 2 * formInset
            for row in rows {
                let where_ = "\(row.title) @\(Int(window))"
                let controls = NSHostingView(rootView: HStack(spacing: 6) { row.controls }.fixedSize()).fittingSize
                let wraps = SettingsRowLayout.wrapsControls(width: width, controlsWidth: controls.width, spacing: 8,
                                                            textMinWidth: SettingsRowLabel.textMinWidth)
                let text = wraps ? width : width - controls.width - 8
                XCTAssertGreaterThanOrEqual(text, SettingsRowLabel.textMinWidth, "\(where_): text squeezed",
                                            file: file, line: line)
                let column = text - (row.hasLead ? leadWidth : 0)
                var expected = textHeight(row.title, SettingsRowLabel.titleFont, width: column, lines: 2)
                for (string, font) in [(row.title, SettingsRowLabel.titleFont)]
                    + (row.description.map { [($0, SettingsRowLabel.descriptionFont)] } ?? []) {
                    let one = textHeight(string, font, width: column, lines: 1)
                    let full = textHeight(string, font, width: column, lines: nil)
                    let two = textHeight(string, font, width: column, lines: 2)
                    if full > one + 0.5 {
                        XCTAssertGreaterThan(two, one + 0.5, "\(where_): ellipsis before line 2", file: file, line: line)
                    }
                }
                if let description = row.description {
                    expected += 2 + textHeight(description, SettingsRowLabel.descriptionFont, width: column, lines: 2)
                }
                let lead = row.hasLead ? AnyView(SettingsSetupMark(isDone: false)) : AnyView(EmptyView())
                let rendered = height(SettingsRow(title: row.title, description: row.description, lead: { lead }) {
                    row.controls
                }, width: width) - 4
                let floor = wraps ? expected + 4 + controls.height : max(expected, controls.height)
                XCTAssertGreaterThanOrEqual(rendered, floor - 1.5, "\(where_): clipped below two lines",
                                            file: file, line: line)
                XCTAssertLessThanOrEqual(rendered, floor + 1.5, "\(where_): grew past two lines", file: file, line: line)
            }
        }
    }

    // MARK: - Frames

    static func render(_ view: some View, size: CGSize, appearance: NSAppearance) throws -> NSBitmapImageRep {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height)
            .background(Color(nsColor: .windowBackgroundColor)))
        host.appearance = appearance
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.appearance = appearance
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        defer { window.orderOut(nil); window.contentView = nil }
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        return bitmap
    }

    /// Writes light + dark frames of `pane` at both window widths, as `<prefix>-<width>-<appearance>.png`.
    static func writeFrames(_ pane: () -> some View, prefix: String, height: CGFloat, to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for window in windowWidths {
            for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                let bitmap = try render(pane(), size: CGSize(width: paneWidth(window: window), height: height),
                                        appearance: try XCTUnwrap(NSAppearance(named: appearance)))
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                    .write(to: directory.appendingPathComponent("\(prefix)-\(Int(window))-\(name).png"))
            }
        }
    }

    // MARK: - Contrast

    typealias RGB = (Double, Double, Double)

    /// Measures the pane's text and glyph colours against the window and the drawn grouped-section background, in
    /// light and dark; asserts each against its WCAG floor and returns the Markdown table.
    static func contrastTable(file: StaticString = #filePath, line: UInt = #line) throws -> String {
        var table = ["| Appearance | Text | Background | Ratio | Needs |", "|---|---|---|---|---|"]
        for (name, appearanceName) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let appearance = try XCTUnwrap(NSAppearance(named: appearanceName))
            let helper = appearanceName == .aqua ? SettingsPanePalette.helperLight : SettingsPanePalette.helperDark
            let warning = appearanceName == .aqua ? SettingsPanePalette.warningLight : SettingsPanePalette.warningDark
            let done = appearanceName == .aqua ? SettingsMarkPalette.doneLight : SettingsMarkPalette.doneDark
            for (bgName, bg) in [("window", resolve(.windowBackgroundColor, appearance)),
                                 ("section", try sectionBackground(appearance))] {
                let label = resolveWithAlpha(.labelColor, appearance)
                let pill = mix(resolve(.controlAccentColor, appearance), bg, 0.18)
                let orangePill = mix(resolve(.systemOrange, appearance), bg, 0.18)
                let greenPill = mix(resolve(.systemGreen, appearance), bg, 0.18)
                let rows: [(String, RGB, RGB, Double)] = [
                    ("Title (label)", composite(label, over: bg), bg, 4.5),
                    ("Description (helper)", (helper.red, helper.green, helper.blue), bg, 4.5),
                    ("Warning text", (warning.red, warning.green, warning.blue), bg, 4.5),
                    ("Pill text on accent 18 % (Used for dictation)", composite(label, over: pill), pill, 4.5),
                    ("Pill text on orange 18 % (Experimental)", composite(label, over: orangePill), orangePill, 4.5),
                    ("Pill text on green 18 % (Recommended)", composite(label, over: greenPill), greenPill, 4.5),
                    ("Warning mark (glyph)", (warning.red, warning.green, warning.blue), bg, 3),
                    ("Done mark (glyph)", (done.red, done.green, done.blue), bg, 3),
                ]
                for (text, fg, back, needs) in rows {
                    let ratio = contrast(fg, back)
                    table.append("| \(name) | \(text) | \(bgName) | \(String(format: "%.2f", ratio)):1 | \(needs):1 |")
                    XCTAssertGreaterThanOrEqual(ratio, needs, "\(name) \(text) on \(bgName)", file: file, line: line)
                }
            }
        }
        return table.joined(separator: "\n") + "\n"
    }

    /// The grouped section background as actually drawn: the centre of a rendered one-row grouped Form.
    private static func sectionBackground(_ appearance: NSAppearance) throws -> RGB {
        let form = Form { Section { Color.clear.frame(height: 60) } }.formStyle(.grouped)
        let bitmap = try render(form, size: CGSize(width: 300, height: 140), appearance: appearance)
        let color = try XCTUnwrap(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)?
            .usingColorSpace(.sRGB))
        return (Double(color.redComponent), Double(color.greenComponent), Double(color.blueComponent))
    }

    private static func resolveWithAlpha(_ color: NSColor, _ appearance: NSAppearance) -> (RGB, Double) {
        var out: (RGB, Double) = ((0, 0, 0), 1)
        appearance.performAsCurrentDrawingAppearance {
            let c = color.usingColorSpace(.sRGB) ?? color
            out = ((Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent)), Double(c.alphaComponent))
        }
        return out
    }

    private static func resolve(_ color: NSColor, _ appearance: NSAppearance) -> RGB {
        resolveWithAlpha(color, appearance).0
    }

    private static func composite(_ fg: (RGB, Double), over bg: RGB) -> RGB { mix(fg.0, bg, fg.1) }

    private static func mix(_ a: RGB, _ b: RGB, _ t: Double) -> RGB {
        (a.0 * t + b.0 * (1 - t), a.1 * t + b.1 * (1 - t), a.2 * t + b.2 * (1 - t))
    }

    private static func contrast(_ a: RGB, _ b: RGB) -> Double {
        func hex(_ c: RGB) -> UInt32 {
            func byte(_ v: Double) -> UInt32 { UInt32(max(0, min(255, (v * 255).rounded()))) }
            return byte(c.0) << 16 | byte(c.1) << 8 | byte(c.2)
        }
        return SettingsPanePalette.contrast(SettingsPanePalette.RGB(hex(a)), SettingsPanePalette.RGB(hex(b)))
    }
}
