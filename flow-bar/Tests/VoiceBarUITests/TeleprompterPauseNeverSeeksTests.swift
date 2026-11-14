import AppKit
import SwiftUI
@testable import VoiceBarUI
import XCTest

/// Reported 2026-11-08, QA 05:06 collision run: clicking Pause rewound playback
/// (0:12 → 0:00, 0:16 → 0:05) instead of pausing. A click anywhere on the Pause control must only ever pause.
@MainActor
final class TeleprompterPauseNeverSeeksTests: XCTestCase {
    private var windows: [NSWindow] = []

    func testOnlyLinesInsideTheVisibleBandTakeClicks() {
        XCTAssertFalse(TeleprompterA.isVisible(line: 4, scrolledLines: 5, visibleLines: 3), "the mounted line above")
        XCTAssertTrue(TeleprompterA.isVisible(line: 5, scrolledLines: 5, visibleLines: 3))
        XCTAssertTrue(TeleprompterA.isVisible(line: 7, scrolledLines: 5, visibleLines: 3))
        XCTAssertFalse(TeleprompterA.isVisible(line: 8, scrolledLines: 5, visibleLines: 3), "a mounted line below")
    }

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

    private final class Spy: BarCommandRouting {
        var calls: [String] = []
        func handlePrimaryTap() { calls.append("primary") }
        func handleCancel() { calls.append("cancel") }
        func handleStop() { calls.append("stop") }
        func handleReplay() { calls.append("replay") }
        func handleRetranscribeHistoryEntry(recordingPath _: String) {}
    }

    private func event(_ type: NSEvent.EventType, at point: NSPoint, in window: NSWindow) -> NSEvent? {
        NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                           timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                           context: nil, eventNumber: 1, clickCount: 1, pressure: 0)
    }

    /// A read several lines in, so the reader has scrolled and its line above the visible text is mounted (y < 0).
    private func scrolledRead(clockSeconds: TimeInterval, queued: Int = 0) -> (VoiceState, () -> [[String: Any]]) {
        var now = 100.0
        let state = VoiceState(playbackAmplitudeClock: { now })
        state.isConnected = true
        state.isCollapsed = false
        var sent: [[String: Any]] = []
        state.sendCommand = { sent.append($0) }
        let words = (0 ..< 80).map { "word\($0)" }
        state.handleEvent(["type": "state", "state": "speaking", "text": words.joined(separator: " "),
                           "duration_ms": 80 * 300, "playback_id": "p-1", "generation": 1, "request_id": "r-1"])
        // Timed words, so every visible and mounted word is a live seek target.
        state.handleEvent(["type": "subtitle", "words": words.enumerated().map { index, text in
            ["offset_ms": index * 300, "duration_ms": 280, "text": text] as [String: Any]
        }])
        if queued > 0 { state.handleEvent(["type": "read_queue", "count": queued, "current_request_id": "r-1"]) }
        now += clockSeconds // the reader has read this far and scrolled
        XCTAssertEqual(state.playbackElapsedMilliseconds(), Int(clockSeconds * 1000))
        return (state, { sent })
    }

    private func mount(_ state: VoiceState, router: Spy) -> (NSWindow, NSView) {
        let bar = NSHostingView(rootView: BarView(state: state, commandRouter: router, onOpenSettings: {}, onOpenHistory: {}))
        bar.frame = NSRect(origin: .zero, size: bar.fittingSize)
        let window = NSWindow(contentRect: bar.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = bar
        window.setFrameOrigin(NSPoint(x: -100_000, y: -100_000))
        window.orderBack(nil)
        windows.append(window)
        settle(bar)
        return (window, bar)
    }

    private func settle(_ view: NSView, seconds: TimeInterval = 0.6) {
        view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
        view.layoutSubtreeIfNeeded()
    }

    /// A control's hit area: Pause and Next are pill buttons with a 26 pt hit circle; Replay, Stop and the eye are
    /// teleprompter buttons whose 20 pt square frame takes the click.
    private enum HitShape {
        case pillCircle, square
        var reach: CGFloat {
            switch self {
            case .pillCircle: VoiceBarPillControlButton.hitDiameter / 2 - 0.5
            case .square: VoiceBarNotchContract.material.compactControlSize / 2 - 0.5
            }
        }
        func contains(_ dx: CGFloat, _ dy: CGFloat) -> Bool {
            self == .square || dx * dx + dy * dy <= reach * reach
        }
    }

    /// Clicks every `step` pt across a control's hit area, centred at `center`, and hands back what each click did.
    private func sweep(_ center: NSPoint, _ shape: HitShape, in window: NSWindow, step: CGFloat = 2,
                       _ check: (_ dx: CGFloat, _ dy: CGFloat) throws -> Void,
                       click: (NSPoint) -> Void) rethrows {
        let reach = shape.reach
        for dx in stride(from: -reach, through: reach, by: step) {
            for dy in stride(from: -reach, through: reach, by: step) where shape.contains(dx, dy) {
                click(NSPoint(x: center.x + dx, y: center.y + dy))
                try check(dx, dy)
            }
        }
    }

    private func controlCenter(_ label: String, in host: NSView) throws -> NSPoint {
        func descendants(_ view: NSView) -> [NSView] {
            view.subviews + view.subviews.flatMap(descendants)
        }
        let view = try XCTUnwrap(descendants(host).first { $0.toolTip == label && !$0.visibleRect.isEmpty })
        return view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
    }

    private func click(_ point: NSPoint, in window: NSWindow) {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            if let event = event(type, at: point, in: window) { window.sendEvent(event) }
        }
    }

    /// Review P2 (T2+T3): the reader's hidden lines sat under every wing control's lower edge, not only Pause. Each of
    /// Replay, Next (with reads queued), Stop and Show/Hide teleprompter does exactly its own thing and never seeks.
    func testEveryReadingWingControlDoesOnlyItsOwnThingAndNeverSeeks() throws {
        for queued in [0, 2] {
            let (state, sent) = scrolledRead(clockSeconds: 12, queued: queued)
            let router = Spy()
            let (window, bar) = mount(state, router: router)
            let geometry = VoiceBarPresentation.notchPresentation(from: VoiceBarNotchOperationalInput(
                mode: .speaking, hasTeleprompterText: true, readQueueLeadingSlotCount: queued > 0 ? 3 : 1)).geometry
            func center(_ label: String) throws -> NSPoint {
                try controlCenter(label, in: bar)
            }
            let eye = try center("Hide teleprompter")
            for (name, center, expected) in [("Replay", try center("Replay"), "replay"), ("Stop", try center("Stop speaking"), "stop")] {
                try sweep(center, .square, in: window, { dx, dy in
                    let calls = router.calls
                    router.calls.removeAll()
                    let commands = sent().compactMap { $0["cmd"] as? String }
                    XCTAssertFalse(commands.contains("seek") || commands.contains("speech_seek"),
                                   "queued \(queued): \(name) at (\(dx), \(dy)) sent \(commands)")
                    XCTAssertEqual(calls, [expected], "queued \(queued): \(name) at (\(dx), \(dy)) did \(calls)")
                }, click: { click($0, in: window) })
            }
            XCTAssertTrue(sent().isEmpty, "Replay and Stop route through the router, never a socket command: \(sent())")
            if queued > 0 {
                var seen = 0
                try sweep(try center("Next read"), .pillCircle, in: window, { dx, dy in
                    let commands = sent()[seen...].compactMap { $0["cmd"] as? String }
                    seen = sent().count
                    XCTAssertEqual(commands, ["read_next"], "Next at (\(dx), \(dy)) sent \(commands)")
                }, click: { click($0, in: window) })
                XCTAssertTrue(router.calls.isEmpty, "\(router.calls)")
            }
            // The eye hides the panel; show it again after each click so every click starts from the open reader.
            var seen = sent().count
            try sweep(eye, .square, in: window, step: 6, { dx, dy in
                let commands = sent()[seen...].compactMap { $0["cmd"] as? String }
                XCTAssertTrue(commands.isEmpty, "the eye at (\(dx), \(dy)) sent \(commands)")
                XCTAssertTrue(state.isTeleprompterDismissed, "the eye at (\(dx), \(dy)) hid the teleprompter")
                state.showTeleprompter()
                settle(bar, seconds: 0.3)
                seen = sent().count
            }, click: { click($0, in: window) })
            XCTAssertTrue(router.calls.isEmpty, "\(router.calls)")
        }
    }

    func testEveryClickOnTheReadingPauseControlPausesAndNeverSeeks() throws {
        for clock in [12.0, 16.0] {
            let (state, sent) = scrolledRead(clockSeconds: clock)
            let router = Spy()
            let bar = NSHostingView(rootView: BarView(state: state, commandRouter: router,
                                                      onOpenSettings: {}, onOpenHistory: {}))
            bar.frame = NSRect(origin: .zero, size: bar.fittingSize)
            let window = NSWindow(contentRect: bar.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = bar
            window.setFrameOrigin(NSPoint(x: -100_000, y: -100_000))
            window.orderBack(nil)
            windows.append(window)
            bar.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.6))
            bar.layoutSubtreeIfNeeded()

            let presentation = VoiceBarPresentation.notchPresentation(from: VoiceBarNotchOperationalInput(
                mode: .speaking, hasTeleprompterText: true, readQueueLeadingSlotCount: 1))
            XCTAssertEqual(presentation.visualState, .teleprompter)
            let geometry = presentation.geometry
            let size = VoiceBarNotchContract.material.compactControlSize
            let originX = (bar.bounds.width - geometry.totalWidth) / 2
            let pauseCenter = try controlCenter("Pause speech", in: bar)
            let pauseMidX = pauseCenter.x
            let topRowMidY = pauseCenter.y

            // The whole 26 pt hit circle of the control (its 20 pt plate plus the 3 pt overhang on each side). Its lower
            // edge reaches 29 pt below the notch's top, past the 32 pt top row's... and the reader's mounted line above
            // the visible text started at 26 pt.
            let radius = VoiceBarPillControlButton.hitDiameter / 2 - 0.5
            for dx in stride(from: -radius, through: radius, by: 2) {
                for dy in stride(from: -radius, through: radius, by: 2) where dx * dx + dy * dy <= radius * radius {
                    let before = sent().count
                    let point = NSPoint(x: pauseMidX + dx, y: topRowMidY + dy)
                    guard let down = event(.leftMouseDown, at: point, in: window),
                          let up = event(.leftMouseUp, at: point, in: window) else { return XCTFail("events") }
                    window.sendEvent(down)
                    window.sendEvent(up)
                    let commands = sent()[before...].compactMap { $0["cmd"] as? String }
                    XCTAssertFalse(commands.contains("seek") || commands.contains("speech_seek"),
                                   "clock \(clock) s, click at Pause (\(dx), \(dy)) sent \(commands), not only a pause")
                    // Exactly one pause: a click on Pause that does nothing is also a bug (review P3).
                    XCTAssertEqual(commands, ["pause"], "clock \(clock) s, click at Pause (\(dx), \(dy)) sent \(commands)")
                }
            }
            XCTAssertTrue(sent().contains { $0["cmd"] as? String == "pause" }, "clock \(clock) s: Pause dispatched")
            XCTAssertTrue(router.calls.isEmpty, "no neighbouring control took the click: \(router.calls)")

            // The visible text still seeks: a click on its first line jumps to a word on that line, never above it.
            let before = sent().count
            let textPoint = NSPoint(x: bar.bounds.midX - TeleprompterA.columnWidth / 2 + 30, y: bar.bounds.maxY - geometry.topHeight
                - TeleprompterA.bodyTopInset - TeleprompterA.lineHeight / 2)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                window.sendEvent(try XCTUnwrap(event(type, at: textPoint, in: window)))
            }
            let seek = try XCTUnwrap(sent()[before...].last, "clock \(clock) s: a visible word takes the click")
            XCTAssertEqual(seek["cmd"] as? String, "seek")
            // Three lines show with the focus held in the middle, so the first visible line starts at most two lines
            // (~6 words of 300 ms) before the clock; the mounted line above starts ~1.8 s earlier still.
            let offset = try XCTUnwrap(seek["offset_ms"] as? Int)
            XCTAssertLessThanOrEqual(offset, Int(clock * 1000))
            XCTAssertGreaterThan(offset, Int(clock * 1000) - 3500,
                                 "the click lands on the visible first line, not the mounted line above it")
        }
    }
}
