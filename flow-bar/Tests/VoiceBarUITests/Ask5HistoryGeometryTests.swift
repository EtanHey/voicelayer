import AppKit
import SwiftUI
import OffscreenTestSupport
@testable import VoiceBarUI
import XCTest

private struct Ask5Bounds: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}
private extension View {
    func ask5Bounds(_ name: String) -> some View {
        background(GeometryReader { geometry in
            Color.clear.preference(key: Ask5Bounds.self, value: [name: geometry.frame(in: .named("ask5"))])
        })
    }
}

@MainActor
final class Ask5HistoryGeometryTests: XCTestCase {
    func testStandardStackedListKeepsFourRowsAndADateHeader() {
        let regions = SettingsHistoryLayout.regions(size: CGSize(width: 580, height: 500))
        XCTAssertFalse(regions.sideBySide)
        XCTAssertGreaterThanOrEqual(regions.list.height, 4 * 48 + 40)
        XCTAssertGreaterThanOrEqual(regions.detail.height, 160)
    }

    func testDividerTranslationStartsAtActualMinimumAndMovesImmediately() {
        let size = CGSize(width: 580, height: 500)
        let before = SettingsHistoryLayout.regions(size: size, listFraction: 0.2)
        let usable = size.height - before.divider.height
        let start = before.list.height / usable
        let after = SettingsHistoryLayout.regions(size: size, listFraction: start + 30 / usable)
        XCTAssertEqual(after.list.height - before.list.height, 30, accuracy: 0.001)
    }

    func testRegionPartitionAcrossResizeAndDividerPositions() {
        for width: CGFloat in [0, 120, 320, 600, 819, 820, 1100, 1800] {
            for height: CGFloat in [0, 4, 100, 300, 540, 900] {
                for fraction: CGFloat in [-1, 0.2, 0.32, 0.6, 2, .nan] {
                    let size = CGSize(width: width, height: height)
                    let r = SettingsHistoryLayout.regions(size: size, listFraction: fraction)
                    let axisTotal = r.sideBySide ? r.list.width + r.divider.width + r.detail.width : r.list.height + r.divider.height + r.detail.height
                    XCTAssertEqual(axisTotal, r.sideBySide ? width : height, accuracy: 0.001)
                    XCTAssertGreaterThanOrEqual(r.list.width, 0)
                    XCTAssertGreaterThanOrEqual(r.detail.height, 0)
                    XCTAssertEqual(r.sideBySide, width >= 600)
                    let intersection = r.list.intersection(r.detail)
                    XCTAssertTrue(intersection.isNull || intersection.width * intersection.height == 0,
                                  "positive-area intersection at \(size), fraction \(fraction)")
                }
            }
        }
    }

    func testRenderedPanesStaySeparateAndActionsStayPinnedWhileLongTextScrolls() throws {
        XCTAssertTrue(VLOffscreenPolicyInstalled())
        var allMeasurements: [[String: Any]] = []
        for width: CGFloat in [580, 780, 1100] {
            var bounds: [String: CGRect] = [:]
            let root = SettingsHistoryWorkspace {
                ScrollView { VStack { ForEach(0..<30) { Text("Synthetic list row \($0)").padding(8) } } }
                    .ask5Bounds("list")
            } detail: {
                SettingsHistoryDetailPane {
                    Text("Selected synthetic dictation").ask5Bounds("identity")
                } content: {
                    VStack(alignment: .leading) {
                        Text("START").ask5Bounds("start")
                        Text(Array(repeating: "Synthetic long transcript with fu… and retractions.", count: 700).joined(separator: "\n"))
                            .fixedSize(horizontal: false, vertical: true)
                        Text("END").ask5Bounds("end")
                    }
                } actions: {
                    Text("Copy · Paste · Re-transcribe · Reveal").ask5Bounds("actions")
                }.ask5Bounds("detail")
            }
            .coordinateSpace(name: "ask5")
            .onPreferenceChange(Ask5Bounds.self) { bounds = $0 }
            .frame(width: width, height: 540)
            let host = NSHostingView(rootView: root)
            host.frame = NSRect(x: 0, y: 0, width: width, height: 540)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: true)
            window.contentView = host
            settle(host)
            let list = try XCTUnwrap(bounds["list"])
            let detail = try XCTUnwrap(bounds["detail"])
            let identity = try XCTUnwrap(bounds["identity"])
            let actions = try XCTUnwrap(bounds["actions"])
            XCTAssertFalse(list.intersects(detail))
            XCTAssertTrue(detail.contains(identity))
            XCTAssertTrue(detail.contains(actions))
            let scrolls = Self.scrollViews(host)
            XCTAssertEqual(scrolls.count, 2)
            let scroll = try XCTUnwrap(scrolls.last)
            let document = try XCTUnwrap(scroll.documentView)
            XCTAssertGreaterThan(document.frame.height, scroll.contentView.bounds.height * 2)
            let bottom = max(0, document.frame.height - scroll.contentView.bounds.height)
            scroll.contentView.scroll(to: NSPoint(x: 0, y: bottom))
            scroll.reflectScrolledClipView(scroll.contentView)
            settle(host)
            XCTAssertEqual(bounds["identity"], identity)
            XCTAssertEqual(bounds["actions"], actions)
            XCTAssertGreaterThan(scroll.contentView.bounds.minY, 0)
            let visibleEnd = try XCTUnwrap(bounds["end"])
            XCTAssertTrue(detail.intersects(visibleEnd), "last words remain reachable")
            XCTAssertFalse(window.isVisible)
            allMeasurements.append(["width": width, "list": NSStringFromRect(list), "detail": NSStringFromRect(detail), "identity": NSStringFromRect(identity), "actions": NSStringFromRect(actions), "scrollOffset": scroll.contentView.bounds.minY, "documentHeight": document.frame.height, "lastWords": NSStringFromRect(visibleEnd)])
            window.contentView = nil
        }
        if let report = ProcessInfo.processInfo.environment["ASK5_REPORT"] {
            let data = try JSONSerialization.data(withJSONObject: allMeasurements, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: URL(fileURLWithPath: report).appendingPathComponent("geometry.json"))
        }
    }

    func testMountedWorkspaceReflowsWhenTheSameHostResizes() throws {
        var bounds: [String: CGRect] = [:]
        let view = SettingsHistoryWorkspace {
            Color.blue.ask5Bounds("list")
        } detail: {
            Color.green.ask5Bounds("detail")
        }
        .coordinateSpace(name: "ask5")
        .onPreferenceChange(Ask5Bounds.self) { bounds = $0 }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 580, height: 540)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: true)
        window.contentView = host
        for width: CGFloat in [580, 1100, 780, 1280, 580] {
            window.setContentSize(NSSize(width: width, height: 540))
            host.setFrameSize(NSSize(width: width, height: 540))
            settle(host)
            let list = try XCTUnwrap(bounds["list"])
            let detail = try XCTUnwrap(bounds["detail"])
            XCTAssertFalse(list.intersects(detail))
            if width >= 600 {
                XCTAssertGreaterThan(detail.minX, list.maxX)
                XCTAssertEqual(detail.minY, list.minY, accuracy: 0.001)
            } else {
                XCTAssertGreaterThan(detail.minY, list.maxY)
                XCTAssertEqual(detail.minX, list.minX, accuracy: 0.001)
            }
            XCTAssertFalse(window.isVisible)
        }
        window.contentView = nil
    }

    private func settle(_ view: NSView) {
        view.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        view.layoutSubtreeIfNeeded()
    }
    private static func scrollViews(_ view: NSView) -> [NSScrollView] {
        (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrollViews)
    }
}
