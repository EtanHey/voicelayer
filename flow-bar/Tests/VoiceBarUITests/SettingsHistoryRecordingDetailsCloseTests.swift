import AppKit
import SwiftUI
@testable import VoiceBarUI
import XCTest

/// Etan, 2026-11-05 (01:44Z recording): he "can't close" the open Recording details. The open section now draws a
/// close button (×) and Esc, its keyboard shortcut, closes it. Driven offscreen with a key event sent to this test's
/// own window: no pointer, no system-wide event. (The native click is the UIE2E History flow, run on the M1 rig.)
@MainActor
final class SettingsHistoryRecordingDetailsCloseTests: XCTestCase {
    func testEscClosesTheOpenDetails() throws {
        var reported: [Bool] = []
        let (window, _) = makeHost(expanded: true) { reported.append($0) }
        defer { window.contentView = nil }
        let escape = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
            context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53
        ))
        XCTAssertTrue(window.performKeyEquivalent(with: escape), "Esc reaches the close button's shortcut")
        XCTAssertTrue(settle { reported.last == false }, "Esc closes the details (reported \(reported))")
    }

    func testClosedDetailsLeaveEscToTheRestOfTheWindow() throws {
        let (window, _) = makeHost(expanded: false) { _ in }
        defer { window.contentView = nil }
        let escape = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
            context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53
        ))
        XCTAssertFalse(window.performKeyEquivalent(with: escape), "no close button, no Esc shortcut")
    }

    /// The × is drawn at the header's trailing edge only while the details are open.
    func testTheCloseButtonIsDrawnOnlyWhileOpen() throws {
        let open = try trailingHeaderInk(expanded: true)
        let closed = try trailingHeaderInk(expanded: false)
        XCTAssertGreaterThan(open, 20, "an open section shows the × (\(open) glyph pixels)")
        XCTAssertLessThan(closed, 3, "a closed section shows none (\(closed))")
    }

    // MARK: - Helpers

    private static let size = CGSize(width: 560, height: 420)

    private func makeHost(expanded: Bool, onExpandedChange: @escaping (Bool) -> Void) -> (NSWindow, NSView) {
        let snapshot = SettingsHistoryDiagnostics(
            archiveState: .transcribed, savedTextState: .present, selection: "2026-11-05/recording",
            summary: "Synthetic", savedResult: "Synthetic", capturedAt: Date(timeIntervalSince1970: 1_793_000_000),
            backend: nil, model: nil, detail: nil, warnings: [], languageSetting: "English", inputDeviceName: "Synthetic mic",
            transcriptWrittenAt: nil
        )
        // No recording ID: the header's trailing edge holds only the × (or nothing).
        let panel = SettingsHistoryDiagnosticsPanel(
            snapshot: snapshot, runs: [], initiallyExpanded: expanded, onExpandedChange: onExpandedChange
        ).frame(width: 520).padding(20).frame(width: Self.size.width, height: Self.size.height, alignment: .top)
            .background(Color.white)
        let host = NSHostingView(rootView: panel)
        host.appearance = NSAppearance(named: .aqua)
        host.frame = NSRect(origin: .zero, size: Self.size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        host.layoutSubtreeIfNeeded()
        return (window, host)
    }

    /// Dark pixels in a 40 × 30 pt box at the header's trailing edge (inside the 12 pt card padding).
    private func trailingHeaderInk(expanded: Bool) throws -> Int {
        let (window, host) = makeHost(expanded: expanded) { _ in }
        defer { window.contentView = nil }
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let scale = CGFloat(bitmap.pixelsWide) / Self.size.width
        // The card spans x 20...540 pt; its header row is ~y 20...56 pt.
        var ink = 0
        for y in Int(22 * scale) ..< Int(52 * scale) {
            for x in Int(492 * scale) ..< Int(532 * scale) {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                if color.brightnessComponent < 0.75 { ink += 1 }
            }
        }
        return ink
    }

    private func settle(timeout: TimeInterval = 3, until condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        return condition()
    }
}
