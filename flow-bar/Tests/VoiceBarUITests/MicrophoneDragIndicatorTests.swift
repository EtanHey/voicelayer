import AppKit
import SwiftUI
@testable import VoiceBarUI
import XCTest

/// C12 (QA recording 2026-09-25): dragging a microphone in Settings › General › Microphone priority showed nothing
/// until the drop. While a drag hovers a row, the row now draws an insertion line exactly where the dragged mic
/// will land: below the row when dragged down, above it when dragged up (the same rule the drop uses).
@MainActor
final class MicrophoneDragIndicatorTests: XCTestCase {
    private let rows: [MicrophonePriorityRow] = [
        .init(uid: "mic-a", deviceID: "1", label: "Mic A", isConnected: true),
        .init(uid: "mic-b", deviceID: "2", label: "Mic B", isConnected: true),
        .init(uid: "mic-off", deviceID: nil, label: "Mic Off", isConnected: false),
        .init(uid: "CADefaultDeviceAggregate-1", deviceID: "9", label: "Virtual", isConnected: true),
    ]

    private var snapshot: MicrophonePrioritySnapshot {
        MicrophonePrioritySnapshot(rows: rows, nextDeviceName: "Mic A")
    }

    // MARK: - Where the line goes is where the drop lands

    func testTheLineSitsOnTheEdgeTheDropLandsOn() {
        XCTAssertEqual(snapshot.dropEdge(dragging: "mic-a", onto: 1), .bottom, "dragged down: lands below")
        XCTAssertEqual(snapshot.dropEdge(dragging: "mic-a", onto: 2), .bottom)
        XCTAssertEqual(snapshot.dropEdge(dragging: "mic-off", onto: 0), .top, "dragged up: lands above")
        XCTAssertEqual(snapshot.dropEdge(dragging: "mic-off", onto: 1), .top)
    }

    func testNoLineWhereTheDropWouldChangeNothing() {
        XCTAssertNil(snapshot.dropEdge(dragging: "mic-b", onto: 1), "over its own row")
        XCTAssertNil(snapshot.dropEdge(dragging: nil, onto: 1), "a drag that did not start in this list")
        XCTAssertNil(snapshot.dropEdge(dragging: "some text", onto: 1), "text dragged in from elsewhere")
        XCTAssertNil(snapshot.dropEdge(dragging: "CADefaultDeviceAggregate-1", onto: 0), "a hidden device")
    }

    func testTheDropUsesTheSameLandingAsTheLine() {
        // Down onto Mic Off: Mic A lands below it; the disconnected mic keeps its place relative to the others.
        XCTAssertEqual(snapshot.droppingVisibleUIDs("mic-a", onto: 2),
                       ["mic-b", "mic-off", "mic-a", "CADefaultDeviceAggregate-1"])
        // Up onto Mic A: Mic Off lands above it.
        XCTAssertEqual(snapshot.droppingVisibleUIDs("mic-off", onto: 0),
                       ["mic-off", "mic-a", "mic-b", "CADefaultDeviceAggregate-1"])
        XCTAssertNil(snapshot.droppingVisibleUIDs("mic-b", onto: 1))
        XCTAssertNil(snapshot.droppingVisibleUIDs("some text", onto: 1))
    }

    // MARK: - The line is drawn, live, in the real Settings view

    func testAHoveredRowDrawsTheLineBelowWhenDraggingDownAndAboveWhenDraggingUp() throws {
        XCTAssertNil(try accentLineY(drag: MicrophoneDragState()), "no drag, no line")
        XCTAssertNil(try accentLineY(drag: MicrophoneDragState(sourceUID: "mic-b", targetIndex: 1)),
                     "hovering its own row draws nothing")

        let down = try XCTUnwrap(accentLineY(drag: MicrophoneDragState(sourceUID: "mic-a", targetIndex: 1)),
                                 "Mic A dragged over Mic B draws a line")
        let up = try XCTUnwrap(accentLineY(drag: MicrophoneDragState(sourceUID: "mic-off", targetIndex: 1)),
                               "Mic Off dragged over Mic B draws a line")
        // Both lines bracket the same row (Mic B): below it for the downward drag, above it for the upward one,
        // one row height apart.
        XCTAssertGreaterThan(down - up, 24, "down \(down) pt vs up \(up) pt")
        XCTAssertLessThan(down - up, 60, "down \(down) pt vs up \(up) pt")
    }

    // MARK: - Helpers

    private let size = CGSize(width: 780, height: 1000)

    /// The y (pt, top-down) of the widest run of accent-blue pixels in the content pane, if it spans a row.
    private func accentLineY(drag: MicrophoneDragState) throws -> CGFloat? {
        let image = try render(drag: drag)
        let scale = CGFloat(image.width) / size.width
        let columns = Int(200 * scale) ..< image.width
        var best: (y: Int, count: Int)?
        for y in 0 ..< image.height {
            let count = columns.reduce(0) { total, x in
                let p = image.pixel(x: x, y: y)
                return total + (p.b > 180 && p.r < 90 && p.g > 90 && p.g < 170 ? 1 : 0)
            }
            if count > (best?.count ?? 0) { best = (y, count) }
        }
        guard let best, CGFloat(best.count) > 300 * scale else { return nil }
        return CGFloat(best.y) / scale
    }

    private func render(drag: MicrophoneDragState) throws -> RenderedImage {
        let rows = rows
        let view = SettingsView(
            hotkeyEnabled: true,
            missingPermissions: [],
            availableDevices: { [] },
            selectedDeviceID: { nil },
            prioritySnapshot: { MicrophonePrioritySnapshot(rows: rows, nextDeviceName: "Mic A") },
            modelsStatus: { .loading },
            onRefreshModelsStatus: {},
            vocabularyPreview: { STTVocabularyPreview(updatedAt: nil, promptTerms: [], aliases: []) },
            vocabularyRevision: { 0 },
            initialTab: .general,
            initialMicrophoneDrag: drag
        )
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height, alignment: .topLeading))
        host.appearance = NSAppearance(named: .aqua)
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled, .resizable],
                              backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        window.orderFront(nil)
        defer {
            window.orderOut(nil)
            window.contentView = nil
        }
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        return try RenderedImage(XCTUnwrap(bitmap.cgImage))
    }
}
