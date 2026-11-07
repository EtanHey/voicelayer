import AppKit
import OffscreenTestSupport
import SwiftUI
@testable import VoiceBarUI
import XCTest

@MainActor
final class NotchHistoryExtendAccessibilityTests: XCTestCase {
    /// Exercise the mounted AppKit adapter, not SwiftUI's lazy/offscreen AX tree.
    private func handles(in view: NSView) -> [NSView] {
        (view.accessibilityIdentifier() == "notch-history-extend-handle" ? [view] : [])
            + view.subviews.flatMap { handles(in: $0) }
    }

    func testNativeAdapterExportsRowsAndAdjustsWithoutTakingPointerOrKeyFocus() throws {
        var adjustments: [Int] = []
        func handle(rows: Int) -> NotchHistoryExtendHandle {
            NotchHistoryExtendHandle(palette: .resolve(for: .dark), rows: rows, maximumRows: 12,
                                     onAdjust: { adjustments.append($0) })
        }
        let host = NSHostingView(rootView: handle(rows: 7))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 100, height: 30),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        VLOrderTestWindow(window)

        for rows in [7, 12, 10] {
            host.rootView = handle(rows: rows)
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            let matches = handles(in: host)
            XCTAssertEqual(matches.count, 1, "one mounted native AX adapter")
            let element = try XCTUnwrap(matches.first)
            XCTAssertTrue(element.isAccessibilityElement())
            XCTAssertEqual(element.accessibilityRole(), .slider)
            XCTAssertEqual(element.accessibilityLabel(), "Show more rows")
            XCTAssertEqual(element.accessibilityValue() as? String, "\(rows) of 12 rows")
            XCTAssertFalse(element.acceptsFirstResponder)
            XCTAssertFalse(element.needsPanelToBecomeKey)
            XCTAssertNil(element.hitTest(CGPoint(x: element.bounds.midX, y: element.bounds.midY)),
                         "the existing canvas gesture owns the pointer")
            adjustments.removeAll()
            XCTAssertEqual(element.accessibilityPerformIncrement(), rows < 12)
            XCTAssertEqual(element.accessibilityPerformDecrement(), rows > 7)
            XCTAssertEqual(adjustments, (rows < 12 ? [1] : []) + (rows > 7 ? [-1] : []))
        }
    }
}
