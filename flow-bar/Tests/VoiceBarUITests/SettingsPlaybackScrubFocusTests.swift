import AppKit
import SwiftUI
@testable import VoiceBarUI
import XCTest

/// #199: a mouse scrub on the History timeline left the system focus ring around the bar until something else
/// took focus. After a pointer scrub the bar draws no ring, yet ←/→ still step; focus that arrives any other way
/// (Tab, VoiceOver) keeps the ring.
///
/// Hosted: the bar sits under a focusable decoy (as Settings has the search field) in a plain borderless
/// window, where AppKit delivers synthetic drags and keys to SwiftUI. SwiftUI mounts one `_FocusRingView` per
/// focusable view whose focus effect is enabled, so a ring view over the bar's row means the bar would draw a
/// ring when focused. A test process never owns the key window, so Tab cannot move focus here; the Tab path is
/// proven on `SettingsScrubFocusRing` and stays an installed-app check.
@MainActor
final class SettingsPlaybackScrubFocusTests: XCTestCase {
    private let clipURL = URL(fileURLWithPath: "/tmp/fixture/recording/audio.wav")
    private static let size = CGSize(width: 400, height: 80)
    /// The bar's row, from the top of the flipped host: the decoy fills 0..<30, spacing 10, then the bar.
    private static let barRowMinY: CGFloat = 40

    func testAMouseScrubLeavesNoFocusRingButArrowKeysStillStep() throws {
        let seeks = SeekLog()
        let (window, host) = makeHost(seeks: seeks)
        defer { tearDown(window) }
        XCTAssertTrue(barHasFocusRing(host), "before any scrub the bar keeps its focus ring for keyboard users")

        try drag(host, fromX: 150, toX: 250)

        XCTAssertEqual(seeks.times.count, 1, "the drag must reach the bar and seek once on release")
        XCTAssertFalse(barHasFocusRing(host), "a mouse scrub must not leave a focus ring on the bar")

        seeks.times.removeAll()
        try window.sendEvent(arrow(right: true, window: window))
        settle()
        XCTAssertEqual(seeks.times, [25], "→ right after a scrub still steps forward")
        XCTAssertFalse(barHasFocusRing(host), "a key step after a mouse scrub keeps the ring hidden")

        try window.sendEvent(arrow(right: false, window: window))
        settle()
        XCTAssertEqual(seeks.times, [25, 15], "← steps back too")
    }

    func testPointerFocusHidesTheRingUntilFocusLeaves() {
        var ring = SettingsScrubFocusRing()
        XCTAssertFalse(ring.isHidden, "focus that arrives by Tab or VoiceOver shows the ring")

        ring.pointerScrubbed()
        ring.focusChanged(to: true)
        XCTAssertTrue(ring.isHidden, "a mouse scrub focuses the bar without a ring")

        ring.focusChanged(to: true)
        XCTAssertTrue(ring.isHidden, "staying focused (←/→ steps) keeps it hidden")

        ring.focusChanged(to: false)
        XCTAssertFalse(ring.isHidden, "once focus leaves, the next arrival by Tab shows the ring again")
        ring.focusChanged(to: true)
        XCTAssertFalse(ring.isHidden)
    }

    func testAScrubWhileKeyboardFocusedHidesTheRing() {
        var ring = SettingsScrubFocusRing()
        ring.focusChanged(to: true)
        XCTAssertFalse(ring.isHidden, "Tab focus draws the ring")

        ring.pointerScrubbed()
        XCTAssertTrue(ring.isHidden, "a mouse scrub after Tab focus hides it, like a click on a native control")
    }

    func testTheVoiceOverAdjustableActionIsUnchanged() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Sources/VoiceBarUI/SettingsPlaybackScrubBar.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(source.contains("""
                    .accessibilityAdjustableAction { direction in
                        SettingsScrubDrag.step(playback: playback, url: url, by: Self.seekDelta(for: direction))
                    }
        """))
    }

    // MARK: - Helpers

    private struct Harness: View {
        let bar: SettingsPlaybackScrubBar

        var body: some View {
            VStack(alignment: .leading, spacing: 10) {
                Color.gray.frame(width: 360, height: 30).focusable()
                bar.frame(width: 360)
            }
            .padding(.horizontal, 20)
            .frame(width: SettingsPlaybackScrubFocusTests.size.width,
                   height: SettingsPlaybackScrubFocusTests.size.height,
                   alignment: .top)
        }
    }

    private func makeHost(seeks: SeekLog) -> (NSWindow, NSView) {
        let playback = SettingsAudioPlayback(
            start: { _ in true },
            stop: {},
            position: { SettingsAudioPlaybackPosition(currentTime: 20, duration: 100) },
            seek: { seeks.times.append($0) }
        )
        playback.toggle(clipURL)
        let host = NSHostingView(rootView: Harness(
            bar: SettingsPlaybackScrubBar(playback: playback, url: clipURL, accessibilityNoun: "recording audio")
        ))
        host.frame = NSRect(origin: .zero, size: Self.size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        window.orderBack(nil)
        host.layoutSubtreeIfNeeded()
        settle()
        return (window, host)
    }

    private func tearDown(_ window: NSWindow) {
        window.orderOut(nil)
        window.contentView = nil
    }

    private func settle() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
    }

    private func barHasFocusRing(_ host: NSView) -> Bool {
        host.layoutSubtreeIfNeeded()
        return focusRings(in: host).contains { $0.convert($0.bounds, to: host).minY >= Self.barRowMinY }
    }

    private func focusRings(in view: NSView) -> [NSView] {
        (String(describing: type(of: view)).contains("_FocusRingView") ? [view] : [])
            + view.subviews.flatMap { focusRings(in: $0) }
    }

    private func drag(_ host: NSView, fromX startX: CGFloat, toX endX: CGFloat) throws {
        let window = try XCTUnwrap(host.window)
        // Window coordinates are unflipped: the middle of the bar's track row, measured from the bottom.
        let y = Self.size.height - Self.barRowMinY - SettingsPlaybackScrubBar.knobDiameter / 2 - 2
        for (type, x) in [
            (NSEvent.EventType.leftMouseDown, startX),
            (.leftMouseDragged, (startX + endX) / 2),
            (.leftMouseDragged, endX),
            (.leftMouseUp, endX),
        ] {
            try window.sendEvent(XCTUnwrap(NSEvent.mouseEvent(
                with: type, location: NSPoint(x: x, y: y), modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1
            )))
            RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        }
        settle()
    }

    private func arrow(right: Bool, window: NSWindow) throws -> NSEvent {
        let character = right ? "\u{F703}" : "\u{F702}"
        return try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.numericPad, .function], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: character,
            charactersIgnoringModifiers: character, isARepeat: false, keyCode: right ? 124 : 123
        ))
    }
}

private final class SeekLog {
    var times: [TimeInterval] = []
}
