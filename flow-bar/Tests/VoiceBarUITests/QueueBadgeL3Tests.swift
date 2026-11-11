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

    /// R892 P3: with Reduce Motion the badge only fades in and out; it never grows or shrinks.
    func testTheBadgeArrivesWithoutScaleUnderReduceMotion() {
        XCTAssertEqual(VoiceBarQueueCountBadge.insertionScale(reduceMotion: true), 1)
        XCTAssertEqual(VoiceBarQueueCountBadge.insertionScale(reduceMotion: false), 0.6)
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


    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }

    // MARK: - M4 defects (lead, 2026-11-11): the badge sat ON Forward's glyph, then was clipped by the screen top

    /// Forward's glyph must stay fully readable at 1, 3 and 10 queued: every pixel of its ink, rendered exactly as the
    /// notch draws it (12 pt medium in the 20 pt plate, centred in the 32 pt top row) through the badge placement
    /// BarView uses, keeps its ink.
    func testForwardGlyphInkIsUntouchedByTheBadge() throws {
        let bare = try row(badge: nil)
        let ink = bare.indices.filter { bare[$0].isInk }
        XCTAssertGreaterThan(ink.count, 200, "the Forward glyph rendered")
        for count in ["1", "3", "10"] {
            let badged = try row(badge: count)
            let covered = ink.filter { !badged[$0].isInk }
            XCTAssertEqual(covered.count, 0, "badge \(count) covers \(covered.count) of \(ink.count) Forward ink pixels")
        }
    }

    /// The badge is drawn whole inside the wing's top row: the row starts at the screen's top edge (inset 0) and the
    /// shell clips there, so a badge too close to either edge loses its rounding ("not rounded properly").
    func testTheBadgeIsWholeAndRoundedInsideTheTopRow() throws {
        let clearance = 1.5 * Self.scale
        for count in ["1", "3", "10"] {
            let badged = try row(badge: count)
            let blue = badged.indices.filter { badged[$0].isBadgeBlue }
            XCTAssertFalse(blue.isEmpty, "badge \(count) drawn")
            let rows = blue.map { $0 / Self.width }, columns = blue.map { $0 % Self.width }
            let top = CGFloat(rows.min()!), bottom = CGFloat(rows.max()! + 1)
            let measured = CGSize(width: CGFloat(columns.max()! - columns.min()! + 1), height: bottom - top)
            let expected = VoiceBarQueueCountBadge.size(for: count)
            XCTAssertGreaterThanOrEqual(top, clearance, "badge \(count) starts \(top / Self.scale) pt below the top edge")
            XCTAssertLessThanOrEqual(bottom, CGFloat(Self.height) - clearance,
                                     "badge \(count) ends \((CGFloat(Self.height) - bottom) / Self.scale) pt above the row's bottom")
            // Whole: the drawn fill is the badge's full size (antialiased rim aside), never a shaved or flattened one.
            XCTAssertEqual(measured.height, expected.height * Self.scale, accuracy: Self.scale,
                           "badge \(count) drawn \(measured.height / Self.scale) pt tall of \(expected.height)")
            XCTAssertEqual(measured.width, expected.width * Self.scale, accuracy: Self.scale,
                           "badge \(count) drawn \(measured.width / Self.scale) pt wide of \(expected.width)")
        }
    }

    /// Wider counts keep clear of the ink and inside the 5 pt beside Forward that the hardware notch's glass leaves
    /// visible (13.5 pt compact core inset − 8.5 pt M4 occlusion).
    func testWiderCountsKeepTheirClearance() throws {
        let bare = try row(badge: nil)
        let ink = bare.indices.filter { bare[$0].isInk }
        let inkBottom = ink.map { $0 / Self.width }.max() ?? 0
        let trailing = Int((Self.controlOrigin.x + VoiceBarNotchContract.material.compactControlSize) * Self.scale)
        for count in ["1", "3", "10"] {
            let badged = try row(badge: count)
            let blue = badged.indices.filter { badged[$0].isBadgeBlue }
            XCTAssertGreaterThan(blue.map { $0 / Self.width }.min() ?? 0, inkBottom, "badge \(count) starts below the ink")
            let overhang = CGFloat((blue.map { $0 % Self.width }.max() ?? 0) + 1 - trailing) / Self.scale
            XCTAssertLessThanOrEqual(overhang, 5.0001, "badge \(count) overhangs Forward by \(overhang) pt")
        }
    }

    private static let scale: CGFloat = 8
    private static let rowSize = CGSize(width: 48, height: VoiceBarNotchContract.topHeight)
    /// Forward's plate in the row: centred vertically, with room on its trailing side for the badge's overhang.
    private static let controlOrigin = CGPoint(x: 14, y: (VoiceBarNotchContract.topHeight -
                                                          VoiceBarNotchContract.material.compactControlSize) / 2)
    private static var width: Int { Int(rowSize.width * scale) }
    private static var height: Int { Int(rowSize.height * scale) }

    private struct Pixel {
        let r: UInt8, g: UInt8, b: UInt8
        /// The white glyph's solid ink (antialiased edges excluded).
        var isInk: Bool { min(r, g, b) > 200 }
        var isBadgeBlue: Bool { Int(b) - Int(r) > 80 }
    }

    /// The wing's top row as the shell clips it: 32 pt tall, top edge at the screen top (inset 0).
    private func row(badge: String?) throws -> [Pixel] {
        let size = VoiceBarNotchContract.material.compactControlSize
        let control = Image(systemName: "forward.end.fill")
            .font(.system(size: VoiceBarNotchControlOptics.resolve(for: "forward.end.fill").pointSize, weight: .medium))
            .foregroundStyle(Color.white)
            .frame(width: size, height: size)
            .queueCountBadge(badge, accessibilityLabel: nil)
            .offset(x: Self.controlOrigin.x, y: Self.controlOrigin.y)
            .frame(width: Self.rowSize.width, height: Self.rowSize.height, alignment: .topLeading)
            .background(Color.black)
            .clipped()
            .environment(\.voiceBarNotchAppearance, .dark)
        let renderer = ImageRenderer(content: control)
        renderer.scale = Self.scale
        let image = try XCTUnwrap(renderer.cgImage)
        let width = image.width, height = image.height
        XCTAssertEqual(width, Self.width)
        XCTAssertEqual(height, Self.height)
        if let dir = ProcessInfo.processInfo.environment["VOICEBAR_L3_BADGE_DEBUG_DIR"] {
            try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: dir).appendingPathComponent("row-badge-\(badge ?? "none").png"))
        }
        var data = [UInt8](repeating: 0, count: width * height * 4)
        let context = try XCTUnwrap(CGContext(data: &data, width: width, height: height, bitsPerComponent: 8,
                                              bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        // A bitmap context's memory starts at the top row, so index / width is the row from the top.
        return (0 ..< height).flatMap { row in
            (0 ..< width).map { column in
                let at = (row * width + column) * 4
                return Pixel(r: data[at], g: data[at + 1], b: data[at + 2])
            }
        }
    }
}
