import AppKit
import SwiftUI
@testable import VoiceBar
@testable import VoiceBarUI
import XCTest

/// Source-model crops at 1 pixel per point. Native tracking/Dock acceptance is a separate captain/M1 gate.
@MainActor
final class U1MenuAssessmentTests: XCTestCase {
    func testWriteNumberedMenuCropsWhenRequested() throws {
        guard let path = ProcessInfo.processInfo.environment["U1_MENU_CROPS"] else {
            throw XCTSkip("Set U1_MENU_CROPS for the source-model assessment")
        }
        let directory = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let delegate = AppDelegate()
        let main = VoiceBarMainMenu.make(appDelegate: delegate)
        let app = try XCTUnwrap(main.items.first?.submenu)
        app.items.first { !$0.isEnabled && !$0.isSeparatorItem }?.title = "VoiceBar 2.3.0"
        let before = try XCTUnwrap(app.copy() as? NSMenu)
        // 2.2.61 VoiceBarMainMenu has About, Settings and Quit, separated by two rules.
        for item in before.items where !["About VoiceBar", "Settings…", "Quit VoiceBar", ""].contains(item.title) {
            before.removeItem(item)
        }
        for index in stride(from: before.items.count - 1, through: 1, by: -1) {
            if before.items[index].isSeparatorItem && before.items[index - 1].isSeparatorItem { before.removeItem(at: index) }
        }
        let controller = PillContextMenuController()
        controller.transcriptProvider = { "A synthetic transcript." }
        for (id, menu) in [("01-app-before", before), ("01-app-after", app),
                           ("02-dock-after", controller.makeDockMenu()),
                           ("03-help-after", try XCTUnwrap(main.item(withTitle: "Help")?.submenu))] {
            for light in [false, true] {
                try crop(menu, light: light, to: directory.appendingPathComponent("\(id)-\(light ? "light" : "dark").png"))
            }
        }
    }

    private func crop(_ menu: NSMenu, light: Bool, to url: URL) throws {
        let view = VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(menu.items.enumerated()), id: \.offset) { _, item in
                if item.isSeparatorItem {
                    Divider().padding(.horizontal, 10).frame(height: 9)
                } else {
                    HStack {
                        Text(item.title)
                        Spacer()
                        if !item.keyEquivalent.isEmpty { Text("⌘\(item.keyEquivalent)") }
                    }
                    .foregroundStyle(item.view != nil ? Color(nsColor: PillContextMenuController.versionTextColor) : item.isEnabled ? .primary : .secondary)
                    .font(.system(size: 13)).padding(.horizontal, 12).frame(height: 25)
                }
            }
            Spacer(minLength: 0)
        }.padding(.vertical, 8).frame(width: 320, height: 310)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, light ? .light : .dark)
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 320, height: 310)
        host.appearance = NSAppearance(named: light ? .aqua : .darkAqua)
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 320, pixelsHigh: 310,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        bitmap.size = host.bounds.size
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url)
        XCTAssertEqual(bitmap.pixelsWide, 320)
        XCTAssertEqual(bitmap.pixelsHigh, 310)
    }
}
