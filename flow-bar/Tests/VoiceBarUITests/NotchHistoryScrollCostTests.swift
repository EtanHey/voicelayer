import AppKit
import SwiftUI
@testable import VoiceBarUI
import XCTest

/// go-1126 vl-swipe: the History list's vertical scroll must not rebuild its rows on every scrolled frame.
///
/// A real `NotchHistoryPanel` in an offscreen window, twenty rows of long synthetic text, scrolled through AppKit's
/// own scroll view one small step at a time (as a trackpad scroll arrives). Each row's second line comes from
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

        // Settle any first-layout work, then count only what scrolling causes.
        step(scroll, host, to: 1)
        drain(0.1)
        counter.builds = 0
        var costs: [Double] = []
        let steps = 60
        for index in 1...steps {
            let start = CFAbsoluteTimeGetCurrent()
            step(scroll, host, to: CGFloat(index) * 4)
            costs.append((CFAbsoluteTimeGetCurrent() - start) * 1000)
        }
        drain(0.05)
        let sorted = costs.sorted()
        let median = sorted[sorted.count / 2]
        let worst = sorted.last ?? 0
        print(String(format: "[scroll-cost] steps=%d rowBuilds=%d perStep=%.2f medianMs=%.3f maxMs=%.3f",
                     steps, counter.builds, Double(counter.builds) / Double(steps), median, worst))
        XCTAssertGreaterThan(scroll.contentView.bounds.origin.y, 100, "the list really scrolled")
        XCTAssertEqual(counter.builds, 0, "a pure scroll must not rebuild rows (got \(counter.builds) over \(steps) steps)")
    }

    /// One scrolled frame: move the clip view, then let SwiftUI run its update and draw, as a display cycle would.
    private func step(_ scroll: NSScrollView, _ host: NSView, to y: CGFloat) {
        scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
        scroll.reflectScrolledClipView(scroll.contentView)
        RunLoop.main.run(until: Date())
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        RunLoop.main.run(until: Date())
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
