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

    /// Its trailing edge stays within the 5 pt of the core-side inset the hardware notch's glass leaves visible
    /// (13.5 pt compact core inset − 8.5 pt M4 occlusion), for the widest count we draw.
    func testTheBadgeStaysVisibleBesideTheHardwareNotch() {
        let ten = VoiceBarQueueCountBadge.size(for: "10")
        let overhang = VoiceBarQueueCountBadge.centreOffset.width + ten.width / 2
        XCTAssertLessThanOrEqual(overhang, 5.0001, "\"10\" overhangs Forward's trailing edge by \(overhang) pt")
    }

    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }

    // MARK: - M4 defect (lead, 2026-11-11): the badge sat ON Forward's glyph

    /// Forward's glyph must stay fully readable at 1, 3 and 10 queued: every pixel of its ink, rendered exactly as the
    /// notch draws it (12 pt medium in the 20 pt plate) through the badge placement BarView uses, keeps its ink.
    func testForwardGlyphInkIsUntouchedByTheBadge() throws {
        let bare = try pixels(badge: nil)
        let ink = bare.indices.filter { bare[$0].isInk }
        XCTAssertGreaterThan(ink.count, 200, "the Forward glyph rendered")
        for count in ["1", "3", "10"] {
            let badged = try pixels(badge: count)
            let covered = ink.filter { !badged[$0].isInk }
            XCTAssertEqual(covered.count, 0,
                           "badge \(count) covers \(covered.count) of \(ink.count) Forward ink pixels")
        }
    }

    /// The pill grows away from the glyph: wider counts never come closer to the ink than one digit does.
    func testWiderCountsKeepTheirClearance() throws {
        let bare = try pixels(badge: nil)
        let ink = bare.indices.filter { bare[$0].isInk }
        let inkTop = ink.map { $0 / Self.side }.min() ?? 0
        for count in ["1", "3", "10"] {
            let badged = try pixels(badge: count)
            let badge = badged.indices.filter { badged[$0].isBadgeBlue }
            XCTAssertFalse(badge.isEmpty, "badge \(count) drawn")
            let badgeBottom = badge.map { $0 / Self.side }.max() ?? 0
            XCTAssertLessThan(badgeBottom, inkTop, "badge \(count)'s fill ends above the glyph's ink")
        }
    }

    private static let scale: CGFloat = 4
    private static let canvas: CGFloat = 48
    private static var side: Int { Int(canvas * scale) }

    private struct Pixel {
        let r: UInt8, g: UInt8, b: UInt8
        /// The white glyph's solid ink (antialiased edges excluded).
        var isInk: Bool { min(r, g, b) > 200 }
        var isBadgeBlue: Bool { Int(b) - Int(r) > 80 }
    }

    private func pixels(badge: String?) throws -> [Pixel] {
        let control = Image(systemName: "forward.end.fill")
            .font(.system(size: VoiceBarNotchControlOptics.resolve(for: "forward.end.fill").pointSize, weight: .medium))
            .foregroundStyle(Color.white)
            .frame(width: VoiceBarNotchContract.material.compactControlSize,
                   height: VoiceBarNotchContract.material.compactControlSize)
            .queueCountBadge(badge, accessibilityLabel: nil)
            .frame(width: Self.canvas, height: Self.canvas)
            .background(Color.black)
            .environment(\.voiceBarNotchAppearance, .dark)
        let renderer = ImageRenderer(content: control)
        renderer.scale = Self.scale
        let image = try XCTUnwrap(renderer.cgImage)
        if let dir = ProcessInfo.processInfo.environment["VOICEBAR_L3_BADGE_DEBUG_DIR"] {
            let rep = NSBitmapImageRep(cgImage: image)
            try rep.representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: dir).appendingPathComponent("badge-\(badge ?? "none").png"))
        }
        let width = image.width, height = image.height
        XCTAssertEqual(width, Self.side)
        var data = [UInt8](repeating: 0, count: width * height * 4)
        let context = try XCTUnwrap(CGContext(data: &data, width: width, height: height, bitsPerComponent: 8,
                                              bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        // A bitmap context's memory starts at the top row, so index / side is the row from the top.
        return (0 ..< height).flatMap { row in
            (0 ..< width).map { column in
                let at = (row * width + column) * 4
                return Pixel(r: data[at], g: data[at + 1], b: data[at + 2])
            }
        }
    }
}
