import AppKit
import SwiftUI
import OffscreenTestSupport
@testable import VoiceBarUI
import XCTest

@MainActor private final class HistoryResizeFixtureControl {
    var toggle: (() -> Void)?
    var expanded = false
    var token = ""
}
@MainActor private struct HistoryResizeStatefulTranscript: View {
    let control: HistoryResizeFixtureControl
    @State private var expanded = false
    @State private var token = UUID().uuidString
    var body: some View {
        VStack {
            Text(Array(repeating: "Synthetic transcript paragraph", count: 500).joined(separator: "\n"))
                .fixedSize(horizontal: false, vertical: true)
            SettingsDisclosureRow("Recording details", isExpanded: $expanded) { Text("Synthetic metadata") }
        }
        .onAppear {
            control.toggle = { expanded.toggle() }
            control.expanded = expanded
            control.token = token
        }
        .onChange(of: expanded) { _, value in control.expanded = value }
    }
}
@MainActor final class HistoryResizeContinuityTests: XCTestCase {
    func testSameEntryStateAndScrollSurviveAxisChanges() throws {
        XCTAssertTrue(VLOffscreenPolicyInstalled())
        let control = HistoryResizeFixtureControl()
        let root = SettingsHistoryWorkspace {
            ScrollView { Text("Synthetic selected entry") }
        } detail: {
            SettingsHistoryDetailPane { Text("Selected synthetic entry") } content: {
                HistoryResizeStatefulTranscript(control: control)
            } actions: { Text("Inert actions") }.id("same-entry")
        }
        let host = NSHostingView(rootView: root)
        host.frame = NSRect(x: 0, y: 0, width: 780, height: 540)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: true)
        window.contentView = host
        defer { window.contentView = nil }
        func settle() {
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            host.layoutSubtreeIfNeeded()
        }
        func scrollViews(_ view: NSView) -> [NSScrollView] {
            (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrollViews)
        }
        settle()
        control.toggle?()
        settle()
        XCTAssertTrue(control.expanded)
        let token = control.token
        let scroll = try XCTUnwrap(scrollViews(host).last)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 1000))
        scroll.reflectScrolledClipView(scroll.contentView)
        settle()
        XCTAssertEqual(scroll.contentView.bounds.minY, 1000, accuracy: 0.5)
        for width: CGFloat in [800, 1100, 780, 1280, 580] {
            window.setContentSize(NSSize(width: width, height: 540))
            host.setFrameSize(NSSize(width: width, height: 540))
            settle()
            XCTAssertEqual(control.token, token, "same entry must keep its State identity at width \(width)")
            XCTAssertTrue(control.expanded, "resize must preserve expanded details at width \(width)")
            let current = try XCTUnwrap(scrollViews(host).last)
            XCTAssertTrue(current === scroll, "the selected transcript scroll view stays mounted")
            XCTAssertEqual(current.contentView.bounds.minY, 1000, accuracy: 0.5, "resize must preserve scroll offset")
            XCTAssertFalse(window.isVisible)
        }
    }
}
