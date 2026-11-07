import AppKit
import OffscreenTestSupport
@testable import VoiceBar
import XCTest

@MainActor
final class UIE2EWindowInventoryTests: XCTestCase {
    private func window(title: String) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 80, height: 40),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.title = title
        window.isReleasedWhenClosed = false
        VLOrderTestWindow(window)
        return window
    }

    func testSnoozedInventoryExcludesOnlyTheExactStatusItemWindow() {
        _ = NSApplication.shared
        let status = window(title: "Item-0")
        let sameTitle = window(title: "Item-0")
        let settings = window(title: "VoiceBar QA Settings")
        let pill = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 100, height: 40),
                           styleMask: .borderless, backing: .buffered, defer: false)
        pill.isReleasedWhenClosed = false
        VLOrderTestWindow(pill)
        defer { [status, sameTitle, settings, pill].forEach { $0.close() } }
        let windows = [status, sameTitle, settings, pill]

        XCTAssertEqual(uie2eVisibleContentWindows(windows, statusWindow: status), [sameTitle, settings, pill],
                       "A title, window class, or size must never exempt app content")
        XCTAssertEqual(uie2eVisibleContentWindows(windows, statusWindow: nil), windows,
                       "Missing status-item identity must fail closed")
        [sameTitle, settings, pill].forEach { $0.orderOut(nil) }
        XCTAssertTrue(status.isVisible)
        XCTAssertTrue(uie2eVisibleContentWindows(windows, statusWindow: status).isEmpty,
                      "The permitted menu-bar presence is not a leaked snoozed surface")
    }
}
