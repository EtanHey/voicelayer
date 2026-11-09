import AppKit
import SwiftUI
@testable import VoiceBarUI
import XCTest

/// U5 visual receipt and contrast table. Frames are opt-in (VOICEBAR_U5_SHOTS_DIR); synthetic text, fixed clock, no audio.
@MainActor
final class TeleprompterAShotsTests: XCTestCase {
    private static let text = """
    Teleprompter A keeps the spoken line in the middle row while the rest of the read waits below it. \
    Click any word to jump there, and the player restarts at that word without synthesizing again. \
    Drag the handle to show more lines, from three up to eight, and it snaps to whole lines when you let go. \
    Reduced motion turns the slide into a jump.
    """

    private static func table(_ text: String) -> SpeechWordTable {
        var table = SpeechWordTable(utteranceID: "shots")
        let rows = TeleprompterContentModel.displayTokens(text).enumerated().map { index, token -> [String: Any] in
            ["text": token, "startMs": index * 300, "endMs": index * 300 + 250]
        }
        table.apply(["utteranceId": "shots", "wordOffset": 0, "words": rows])
        return table
    }

    /// Spoken / read / unread ink over the notch backdrops the contrast suite already uses.
    func testContrastTable() throws {
        let backdrops: [(VoiceBarNotchAppearance, String, VoiceBarRGB)] = [
            (.dark, "notch black", VoiceBarRGB(red: 0, green: 0, blue: 0)),
            (.dark, "dark glass", VoiceBarRGB(red: 0.24, green: 0.27, blue: 0.32)),
            (.light, "light glass", VoiceBarRGB(red: 0.86, green: 0.88, blue: 0.92)),
        ]
        var rows = ["| Appearance | Backdrop | Spoken 100 % | Read 64 % | Unread 36 % | Footer (secondary) |",
                    "| --- | --- | ---: | ---: | ---: | ---: |"]
        for (appearance, name, backdrop) in backdrops {
            let palette = VoiceBarNotchContrastPalette.resolve(for: appearance)
            func ratio(_ ink: VoiceBarRGBA, _ factor: Double = 1) -> Double {
                let scaled = VoiceBarRGBA(red: ink.red, green: ink.green, blue: ink.blue, alpha: ink.alpha * factor)
                return VoiceBarContrast.ratio(foreground: scaled.composited(over: backdrop), background: backdrop)
            }
            let tiers = [TeleprompterA.Tier.spoken, .read, .unread].map { ratio(palette.primary, $0.opacity) }
            let footer = ratio(palette.secondary)
            XCTAssertGreaterThanOrEqual(tiers[0], VoiceBarContrast.minimumTextRatio, "\(name) spoken")
            XCTAssertGreaterThanOrEqual(tiers[1], VoiceBarContrast.minimumTextRatio, "\(name) read")
            XCTAssertGreaterThanOrEqual(footer, VoiceBarContrast.minimumTextRatio, "\(name) footer")
            rows.append("| \(appearance) | \(name) | " + (tiers + [footer]).map { String(format: "%.2f:1", $0) }
                .joined(separator: " | ") + " |")
        }
        if let path = ProcessInfo.processInfo.environment["VOICEBAR_U5_SHOTS_DIR"], !path.isEmpty {
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
            try (rows.joined(separator: "\n") + "\n").write(toFile: path + "/contrast.md", atomically: true, encoding: .utf8)
        }
    }

    func testWriteTeleprompterAFramesWhenRequested() throws {
        guard let path = ProcessInfo.processInfo.environment["VOICEBAR_U5_SHOTS_DIR"], !path.isEmpty else {
            throw XCTSkip("Set VOICEBAR_U5_SHOTS_DIR to write the U5 Teleprompter A frames")
        }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let table = Self.table(Self.text)
        // Clock 9.3 s lands mid-paragraph, so the 3-line frame has scrolled and shows the top fade.
        let frames: [(String, Int, Bool, Int, Int)] = [
            ("3-line", 3, false, 0, 9_300), ("8-line", 8, false, 0, 9_300),
            ("paused", 3, true, 0, 9_300), ("queued-2", 3, false, 2, 9_300), ("first-line", 3, false, 0, 600),
        ]
        var index = ["# U5 Teleprompter A frames", "", "Offscreen TeleprompterAView, synthetic text, fixed clock, 2×.", ""]
        for (appearanceName, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            for (name, lines, paused, queued, clock) in frames {
                let view = TeleprompterAView(
                    text: Self.text, speechWords: table, isPaused: paused, visibleLines: lines,
                    playbackElapsedMilliseconds: { clock })
                _ = queued // T1: the queued count is Forward's badge in the leading wing now.
                let filename = "teleprompter-a-\(name)-\(appearanceName).png"
                try render(view, appearance: appearance, to: directory.appendingPathComponent(filename))
                index.append("- [\(filename)](\(filename))")
            }
        }
        try (index.joined(separator: "\n") + "\n").write(to: directory.appendingPathComponent("index.md"),
                                                         atomically: true, encoding: .utf8)
    }

    private func render(_ view: TeleprompterAView, appearance: NSAppearance.Name, to url: URL) throws {
        let notchAppearance: VoiceBarNotchAppearance = appearance == .darkAqua ? .dark : .light
        let size = CGSize(width: TeleprompterA.columnWidth + 36,
                          height: TeleprompterA.bodyHeight(lines: view.visibleLines) + 44)
        let root = view
            .padding(18)
            .frame(width: size.width, height: size.height, alignment: .top)
            .background(RoundedRectangle(cornerRadius: 24)
                .fill(notchAppearance == .dark ? Color.black : Color(red: 0.86, green: 0.88, blue: 0.92)))
            .environment(\.voiceBarNotchAppearance, notchAppearance)
        let host = NSHostingView(rootView: root)
        host.appearance = NSAppearance(named: appearance)
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.backgroundColor = appearance == .aqua ? .white : NSColor(white: 0.18, alpha: 1)
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        window.orderBack(nil)
        defer {
            window.orderOut(nil)
            window.contentView = nil
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url)
    }
}
