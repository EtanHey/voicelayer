import AppKit
import SwiftUI
@testable import VoiceBarUI
import XCTest

/// go-1126 vl-swipe: the History list's vertical scroll must not rebuild its rows on every scrolled frame.
///
/// A real `NotchHistoryPanel` in an offscreen window, twenty rows of long synthetic text, scrolled by phased trackpad
/// scroll events through AppKit's own scroll view, down and back over rows already built. Each row's second line comes from
/// `rowHeader`, which a row build calls, so its call count is how many rows SwiftUI rebuilt while only the scroll
/// offset changed. The per-step main-thread cost is printed as a frame-time probe (`[scroll-cost]`), not asserted.
@MainActor
final class NotchHistoryScrollCostTests: XCTestCase {
    private var windows: [NSWindow] = []

    override func tearDown() {
        MainActor.assumeIsolated {
            for window in windows {
                window.isReleasedWhenClosed = false
                window.orderOut(nil)
                window.close()
            }
            windows.removeAll()
        }
        super.tearDown()
    }

    final class Counter { var builds = 0 }

    func testScrollingTheListDoesNotRebuildItsRows() throws {
        let counter = Counter()
        let long = String(repeating: "Synthetic long dictation words that run well past one line of the row. ", count: 40)
        let entries = (0..<20).map { index in
            RecentTranscriptionEntry(
                text: "\(index) \(long)", recordingPath: "/synthetic/\(index).wav",
                createdAt: Date(timeIntervalSince1970: 1_794_400_000 + Double(index) * 60)
            )
        }
        let panel = NotchHistoryPanel(
            entries: entries, activeRetranscriptionPath: nil, palette: .resolve(for: .dark),
            onCopy: { _ in true }, onPaste: { _ in }, onRetranscribe: { _ in },
            rowHeader: { index in
                counter.builds += 1
                return "\(index) min ago"
            }
        )
        let host = NSHostingView(rootView: panel.frame(width: 404))
        host.frame = NSRect(x: 0, y: 0, width: 404, height: NotchHistoryMorph.listHeight)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        window.orderBack(nil)
        windows.append(window)
        drain(0.2)
        host.layoutSubtreeIfNeeded()
        let scroll = try XCTUnwrap(findScrollView(host), "the list is AppKit's scroll view")

        // Settle any first-layout work (the rows a scroll first brings into view are built once), then count only
        // what scrolling causes: a trackpad gesture scrolls down and back over the same rows.
        try wheel(scroll, host, phase: 1, dy: 0)
        for _ in 0 ..< 30 { try wheel(scroll, host, phase: 2, dy: -4) }
        for _ in 0 ..< 30 { try wheel(scroll, host, phase: 2, dy: 4) }
        try wheel(scroll, host, phase: 4, dy: 0)
        drain(0.2)
        counter.builds = 0
        var costs: [Double] = []
        let steps = 60
        try wheel(scroll, host, phase: 1, dy: 0)
        for index in 0 ..< steps {
            let start = CFAbsoluteTimeGetCurrent()
            try wheel(scroll, host, phase: 2, dy: index < steps / 2 ? -4 : 4)
            costs.append((CFAbsoluteTimeGetCurrent() - start) * 1000)
        }
        try wheel(scroll, host, phase: 4, dy: 0)
        drain(0.05)
        let sorted = costs.sorted()
        let median = sorted[sorted.count / 2]
        let worst = sorted.last ?? 0
        print(String(format: "[scroll-cost] steps=%d rowBuilds=%d perStep=%.2f medianMs=%.3f maxMs=%.3f",
                     steps, counter.builds, Double(counter.builds) / Double(steps), median, worst))
        XCTAssertGreaterThan(maxOffset, 60, "the list really scrolled (\(maxOffset) pt)")
        XCTAssertEqual(counter.builds, 0, "a pure scroll must not rebuild rows (got \(counter.builds) over \(steps) steps)")
    }

    private var maxOffset: CGFloat = 0

    /// One trackpad scroll step through the scroll view's own event path, then SwiftUI's update and draw, as a
    /// display cycle would.
    private func wheel(_ scroll: NSScrollView, _ host: NSView, phase: Int64, dy: Int32) throws {
        let cg = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                                       wheel1: dy, wheel2: 0, wheel3: 0))
        cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
        scroll.scrollWheel(with: try XCTUnwrap(NSEvent(cgEvent: cg)))
        RunLoop.main.run(until: Date().addingTimeInterval(0.008))
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        maxOffset = max(maxOffset, abs(scroll.contentView.bounds.origin.y))
    }

    private func drain(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    private func findScrollView(_ root: NSView) -> NSScrollView? {
        if let scroll = root as? NSScrollView { return scroll }
        for subview in root.subviews {
            if let found = findScrollView(subview) { return found }
        }
        return nil
    }
}
