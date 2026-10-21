import AppKit
import SwiftUI
@testable import VoiceBarUI
import XCTest

final class Pill1GroundworkTests: XCTestCase {
    @MainActor
    func testNonKeyHostingViewAcceptsFirstMouse() throws {
        let host = PillHostingView(rootView: EmptyView())
        host.frame = NSRect(x: 0, y: 0, width: 100, height: 40)
        let panel = FloatingPillPanel(content: host)
        defer { panel.close() }
        XCTAssertFalse(panel.isKeyWindow)
        XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel))
        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown, location: NSPoint(x: 50, y: 20),
            modifierFlags: [], timestamp: 0, windowNumber: panel.windowNumber,
            context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        XCTAssertTrue(host.acceptsFirstMouse(for: event), "PILL1-a: click-through required")
        host.renderedSurfaceHitTestProvider = { _ in false }
        XCTAssertNil(host.hitTest(NSPoint(x: 50, y: 20)))
        XCTAssertFalse(panel.isKeyWindow)
    }
    @MainActor
    func testPanelAllowsExistingHelpWhileApplicationInactive() {
        let panel = FloatingPillPanel(content: PillHostingView(rootView: EmptyView()))
        defer { panel.close() }
        XCTAssertTrue(panel.allowsToolTipsWhenApplicationIsInactive,
                      "PILL1-b: enable native tooltip permission at construction")
        XCTAssertFalse(panel.isKeyWindow)
    }
    @MainActor
    func testNextHiddenWhenNoReadWaits() {
        XCTAssertNil(VoiceBarPresentation.readQueueControl(
            mode: .speaking, isReadback: false, currentRequestID: "A", count: 0))
        XCTAssertNotNil(VoiceBarPresentation.readQueueControl(
            mode: .speaking, isReadback: false, currentRequestID: "A", count: 1))
    }
}
