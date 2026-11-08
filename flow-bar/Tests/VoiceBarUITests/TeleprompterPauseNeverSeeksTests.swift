import AppKit
import SwiftUI
@testable import VoiceBarUI
import XCTest

/// QA 2026-11-08 05:06 collision run, c07 X1 (Etan's R3): clicking the pill's Pause while "Reading · 1×" seeked back
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
    private func scrolledRead(clockSeconds: TimeInterval) -> (VoiceState, () -> [[String: Any]]) {
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
        now += clockSeconds // the reader has read this far and scrolled
        XCTAssertEqual(state.playbackElapsedMilliseconds(), Int(clockSeconds * 1000))
        return (state, { sent })
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
            let pitch = size + VoiceBarNotchContract.readingControlSpacing
            // T3's left wing from the core outward: Replay, Pause, Stop. Pause is the second slot.
            let originX = (bar.bounds.width - geometry.totalWidth) / 2
            let pauseMidX = originX + geometry.coreOriginX - VoiceBarNotchContract.compactCoreContentInset
                - size / 2 - pitch
            let topRowMidY = bar.bounds.maxY - geometry.topHeight / 2

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
            let textPoint = NSPoint(x: originX + 70, y: bar.bounds.maxY - geometry.topHeight
                - VoiceBarNotchContract.teleprompterTopInset - TeleprompterA.lineHeight / 2)
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
