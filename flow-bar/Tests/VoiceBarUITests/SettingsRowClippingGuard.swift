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

    /// Content width a row gets inside the pane's grouped Form at that window width.
    static func rowWidth(window: CGFloat) -> CGFloat { paneWidth(window: window) - 2 * formInset }

    /// Renders `row` (the real consumer layout) at both window widths and checks every visible row text against the
    /// pixels actually drawn. See `violations(in:width:)`.
    static func check(_ name: String, file: StaticString = #filePath, line: UInt = #line,
                      _ row: @escaping (CGFloat) -> some View) {
        for window in windowWidths {
            let found = violations(in: row(rowWidth(window: window)), width: rowWidth(window: window))
            XCTAssertEqual(found, [], "\(name) @\(Int(window))", file: file, line: line)
        }
    }

    static func check(_ rows: [SettingsRowCase], file: StaticString = #filePath, line: UInt = #line) {
        for row in rows {
            let lead = row.hasLead ? AnyView(SettingsSetupMark(isDone: false)) : AnyView(EmptyView())
            check(row.title, file: file, line: line) { _ in
                SettingsRow(title: row.title, description: row.description, lead: { lead }) { row.controls }
            }
        }
    }

    /// Compare each audited text with a full, untruncated reference at the exact rendered width. This catches
    /// missing lines and horizontal crops, while allowing the complete wrapping required in both Settings surfaces.
    static func violations(in view: some View, width: CGFloat) -> [String] {
        let box = AuditBox()
        let root = view.frame(width: width).fixedSize(horizontal: false, vertical: true)
            .onPreferenceChange(SettingsTextAuditKey.self) { box.entries = $0 }
        let size = CGSize(width: width, height: ceil(NSHostingView(rootView: root).fittingSize.height))
        guard let actual = try? render(root, size: size, appearance: NSAppearance(named: .aqua)!) else {
            return ["render failed"]
        }
        guard !box.entries.isEmpty else { return ["no audited text found"] }
        let scale = CGFloat(actual.pixelsWide) / size.width
        return box.entries.compactMap { entry in
            let label = "\"\(entry.text.prefix(40))\""
            guard CGRect(origin: .zero, size: size).insetBy(dx: -0.5, dy: -0.5).contains(entry.frame) else {
                return "\(label) lies outside the row (\(entry.frame))"
            }
            let reference = Text(entry.text).font(entry.font).lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: entry.frame.width, alignment: .topLeading)
                .foregroundStyle(Color.black)
            let referenceHeight = NSHostingView(rootView: reference).fittingSize.height
            if abs(referenceHeight - entry.frame.height) > 1.5 {
                return "\(label) is \(Int(entry.frame.height)) pt tall; full copy needs \(Int(referenceHeight)) pt"
            }
            guard let drawn = try? render(reference, size: entry.frame.size, appearance: NSAppearance(named: .aqua)!)
            else { return "\(label) reference render failed" }
            let mine = InkMask(actual, frame: entry.frame, scale: scale)
            let theirs = InkMask(drawn, frame: CGRect(origin: .zero, size: entry.frame.size),
                                 scale: CGFloat(drawn.pixelsWide) / entry.frame.width)
            guard mine.inked > 0 else { return "\(label) draws no text in its frame" }
            let unmatched = mine.unmatched(against: theirs) + theirs.unmatched(against: mine)
            let allowed = max(12, theirs.inked / 12)
            return unmatched > allowed
                ? "\(label) rendering differs from full untruncated copy (\(unmatched) px, allowed \(allowed))" : nil
        }
    }

    private final class AuditBox { var entries: [SettingsTextAuditEntry] = [] }

    /// Which pixels in a crop are text: far from the crop's own background (its most common colour), relative to
    /// the strongest ink in the crop, so light-on-dark and grey helper text binarize like black on white.
    struct InkMask {
        let width: Int, height: Int
        let ink: [Bool]
        var inked: Int { ink.lazy.filter { $0 }.count }

        init(_ bitmap: NSBitmapImageRep, frame: CGRect, scale: CGFloat) {
            let x0 = Int((frame.minX * scale).rounded()), y0 = Int((frame.minY * scale).rounded())
            width = max(0, min(Int((frame.width * scale).rounded()), bitmap.pixelsWide - x0))
            height = max(0, min(Int((frame.height * scale).rounded()), bitmap.pixelsHigh - y0))
            var pixels: [(Int, Int, Int)] = []
            pixels.reserveCapacity(width * height)
            var sample = [Int](repeating: 0, count: max(4, bitmap.samplesPerPixel))
            for y in 0 ..< height {
                for x in 0 ..< width {
                    bitmap.getPixel(&sample, atX: x0 + x, y: y0 + y)
                    let shift = bitmap.bitsPerSample > 8 ? 8 : 0
                    pixels.append((sample[0] >> shift, sample[1] >> shift, sample[2] >> shift))
                }
            }
            var counts: [Int: Int] = [:]
            for p in pixels { counts[(p.0 / 8) << 10 | (p.1 / 8) << 5 | p.2 / 8, default: 0] += 1 }
            let key = counts.max { $0.value < $1.value }?.key ?? 0
            let bg = ((key >> 10) * 8 + 4, (key >> 5 & 31) * 8 + 4, (key & 31) * 8 + 4)
            let distance = pixels.map { abs($0.0 - bg.0) + abs($0.1 - bg.1) + abs($0.2 - bg.2) }
            let strongest = distance.max() ?? 0
            ink = strongest < 30 ? Array(repeating: false, count: pixels.count) : distance.map { $0 * 10 > strongest * 4 }
        }

        /// Ink here with no ink in `other` within one pixel.
        func unmatched(against other: InkMask) -> Int {
            var count = 0
            for y in 0 ..< height {
                for x in 0 ..< width where ink[y * width + x] {
                    let near = (-1 ... 1).contains { dy in (-1 ... 1).contains { dx in
                        let (nx, ny) = (x + dx, y + dy)
                        return nx >= 0 && ny >= 0 && nx < other.width && ny < other.height && other.ink[ny * other.width + nx]
                    } }
                    if !near { count += 1 }
                }
            }
            return count
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
