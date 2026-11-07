import AppKit
@testable import VoiceBarUI
import XCTest

/// Typography specimens from production NSMenuItem values; does not open a native menu or move the pointer.
@MainActor
final class ContextMenuTitleArtifactTests: XCTestCase {
    func testWritesSyntheticTitleSpecimens() throws {
        guard #available(macOS 14.4, *) else { throw XCTSkip("Menu subtitles require macOS 14.4") }
        guard let path = ProcessInfo.processInfo.environment["VOICEBAR_MENU_TITLE_SHOTS"] else {
            throw XCTSkip("Set VOICEBAR_MENU_TITLE_SHOTS for offscreen title specimens")
        }
        let directory = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let controller = PillContextMenuController()
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        controller.now = { now }
        controller.defaultMicrophoneNameProvider = { "Studio microphone with a descriptive USB device name" }
        controller.recentTranscriptionEntriesProvider = {
            ["Short note", "A short opening followed by extraordinarily readable words and a much longer ending",
             "  hello\tthere\n 👩🏽‍💻 שלום  ", String(repeating: "👨‍👩‍👧‍👦", count: 30)]
                .map { RecentTranscriptionEntry(text: $0, createdAt: now.addingTimeInterval(-120)) }
        }
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            var png: Data?
            try XCTUnwrap(NSAppearance(named: appearance)).performAsCurrentDrawingAppearance {
                let image = NSImage(size: NSSize(width: 484, height: 245))
                image.lockFocus()
                NSColor.windowBackgroundColor.setFill()
                NSRect(x: 0, y: 0, width: 484, height: 245).fill()
                let menu = controller.makeMenu()
                let mic = menu.item(withTitle: "Microphone")
                let rows = [NSMenuItem(title: "Microphone", action: nil, keyEquivalent: ""),
                            NSMenuItem(title: mic?.subtitle ?? "", action: nil, keyEquivalent: "")]
                    + controller.makeRecentTranscriptsSubmenu().items
                for (index, item) in rows.enumerated() {
                    let text = item.attributedTitle ?? NSAttributedString(string: item.title, attributes: [
                        .font: NSFont.menuFont(ofSize: index == 1 ? 11 : 13), .foregroundColor: NSColor.labelColor,
                    ])
                    XCTAssertEqual(text.string, item.title)
                    text.draw(in: NSRect(x: 24, y: 210 - index * 34, width: 420, height: 23))
                }
                image.unlockFocus()
                png = image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:))?
                    .representation(using: .png, properties: [:])
            }
            try XCTUnwrap(png).write(to: directory.appendingPathComponent("\(name).png"))
        }
    }
}
