import AppKit
import SwiftUI
@testable import VoiceBarUI
import XCTest

/// C6 lane L3, X1-30 (Etan QA 2026-11-10: "not rounded properly" / "when there is 1 in the queue, it is actually
/// rounded"): the queued count on Forward's corner is a circle for 1-9 and an evenly rounded pill beyond, at one height,
/// and it never moves Forward or the wing.
@MainActor
final class QueueBadgeL3Tests: XCTestCase {
    func testCountsOneToThreeAreTrueCirclesAndTenIsAnEvenPill() {
        for count in 1 ... 3 {
            let size = VoiceBarQueueCountBadge.size(for: "\(count)")
            XCTAssertEqual(size.width, size.height, "\(count) is a circle")
            XCTAssertEqual(size.height, VoiceBarQueueCountBadge.height)
        }
        let ten = VoiceBarQueueCountBadge.size(for: "10")
        XCTAssertEqual(ten.height, VoiceBarQueueCountBadge.height, "multi-digit keeps the same height")
        XCTAssertGreaterThan(ten.width, ten.height)
        XCTAssertLessThanOrEqual(ten.width, 2 * ten.height, "a short pill, not a slab")
        XCTAssertEqual(VoiceBarQueueCountBadge.size(for: "2"), VoiceBarQueueCountBadge.size(for: "3"),
                       "tabular digits: no size jump between counts")
    }

    func testTheBadgeSitsOnForwardsCornerWithoutMovingIt() throws {
        func forwardFrame(count: Int) throws -> (forward: CGRect, badge: CGRect?) {
            let state = VoiceState()
            state.isConnected = true
            state.isCollapsed = false
            state.handleEvent(["type": "state", "state": "speaking", "text": "Badge fixture", "playback_id": "qb",
                               "generation": 1])
            if count > 0 { state.handleEvent(["type": "read_queue", "count": count, "current_request_id": "qb"]) }
            let host = PillHostingView(rootView: BarView(state: state,
                commandRouter: BarViewClickabilityTests.SpyCommandRouter(), onOpenSettings: {}, onOpenHistory: {}))
            host.frame = NSRect(x: 0, y: 0, width: 700, height: 300)
            let panel = FloatingPillPanel(content: host)
            defer { panel.close() }
            panel.setFrameOrigin(NSPoint(x: -100_000, y: -100_000))
            panel.orderBack(nil)
            let ready = expectation(for: NSPredicate { [self] _, _ in
                host.layoutSubtreeIfNeeded()
                return descendants(host).contains { $0.toolTip == "Next read" }
            }, evaluatedWith: nil)
            wait(for: [ready], timeout: 3)
            let forward = try XCTUnwrap(descendants(host).first { $0.toolTip == "Next read" })
            return (forward.convert(forward.bounds, to: nil), nil)
        }
        let none = try forwardFrame(count: 0).forward
        for count in [1, 2, 3, 10] {
            XCTAssertEqual(try forwardFrame(count: count).forward, none, "Forward stays put with \(count) queued")
        }
    }

    func testTheBadgeCentreIsInsideTheControlCorner() {
        let offset = VoiceBarQueueCountBadge.centreOffset
        XCTAssertLessThan(offset.width, 0, "inside the trailing edge")
        XCTAssertGreaterThan(offset.height, 0, "below the top edge")
        // Its outer edge overhangs Forward's corner by at most half a badge minus the inset: less than the old 5 pt.
        XCTAssertLessThanOrEqual(VoiceBarQueueCountBadge.height / 2 + offset.width, 3.0001)
    }

    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
}
