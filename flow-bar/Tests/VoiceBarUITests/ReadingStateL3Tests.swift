import AppKit
import SwiftUI
@testable import VoiceBarUI
import XCTest

/// C6 lane L3, X1-32/33/34/35 (Etan QA 2026-11-10): pause and hide are independent. "Paused on its own should not hide
/// the teleprompter, but just pause"; the eye stays while paused or playing; the paused square becomes an X; the states
/// are reading playing / reading paused / paused hidden / finished.
@MainActor
final class ReadingStateL3Tests: XCTestCase {
    // MARK: - RED on candidate 5 (existing API, behavioural assertions)

    func testPauseKeepsTheTeleprompterOpenAndReadable() {
        let state = speakingState()
        XCTAssertEqual(presentation(for: state).visualState, .teleprompter)
        state.handleEvent(pausedEvent())
        XCTAssertTrue(state.isPlaybackPaused)
        XCTAssertEqual(presentation(for: state).visualState, .teleprompter,
                       "X1-34: pause alone keeps the teleprompter open")
        XCTAssertEqual(state.teleprompterText, "One two three four five six", "the paused text stays on screen")
    }

    func testHideWhilePausedCollapsesAndShowRestoresWithoutResuming() {
        let state = speakingState()
        state.handleEvent(pausedEvent())
        state.dismissTeleprompter()
        XCTAssertEqual(presentation(for: state).visualState, .compactStatus, "paused hidden collapses to the wing")
        XCTAssertTrue(state.isPlaybackPaused)
        state.showTeleprompter()
        XCTAssertEqual(presentation(for: state).visualState, .teleprompter)
        XCTAssertTrue(state.isPlaybackPaused, "showing the teleprompter never resumes the read")
    }

    func testPausedHiddenWingKeepsTheEye() throws {
        let state = speakingState()
        state.handleEvent(pausedEvent())
        state.dismissTeleprompter()
        let tooltips = try mountedTooltips(state, until: { $0.contains("Show teleprompter") })
        XCTAssertTrue(tooltips.contains("Show teleprompter"), "X1-34: the eye stays when paused hidden: \(tooltips)")
        XCTAssertTrue(tooltips.contains("Resume speech"))
    }

    func testPausedTerminalControlIsCloseXNotTheStopSquare() throws {
        let state = speakingState()
        state.handleEvent(pausedEvent())
        let tooltips = try mountedTooltips(state, until: { $0.contains("Close read") })
        XCTAssertTrue(tooltips.contains("Close read"), "X1-32: paused shows an X: \(tooltips)")
        XCTAssertFalse(tooltips.contains("Stop speaking"), "no Stop square while nothing plays")
        XCTAssertTrue(tooltips.contains("Hide teleprompter"), "the paused teleprompter keeps its eye row")
    }

    func testPlayingKeepsTheRedStop() throws {
        let state = speakingState()
        let tooltips = try mountedTooltips(state, until: { $0.contains("Stop speaking") })
        XCTAssertTrue(tooltips.contains("Stop speaking"))
        XCTAssertFalse(tooltips.contains("Close read"))
    }

    func testPausedXEndsTheReadThroughStop() throws {
        let state = speakingState()
        state.handleEvent(pausedEvent())
        let router = BarViewClickabilityTests.SpyCommandRouter()
        let host = mount(state, router: router)
        defer { host.window?.close() }
        let ready = expectation(for: NSPredicate { [self] _, _ in
            host.layoutSubtreeIfNeeded()
            return descendants(host).contains { $0.toolTip == "Close read" }
        }, evaluatedWith: nil)
        wait(for: [ready], timeout: 3)
        XCTAssertEqual(VoiceBarPresentation.readingTerminalControl(for: .paused).action, .stopSpeech,
                       "Close read is Stop's route: a user Stop retains no readback, so one click closes")
    }

    // MARK: - State naming and controls (new API)

    func testReadingStatesAreNamedAndIndependent() {
        typealias P = VoiceBarPresentation
        XCTAssertEqual(P.readingState(mode: .speaking, isPaused: false, isDismissed: false, isReadback: false), .playing)
        XCTAssertEqual(P.readingState(mode: .speaking, isPaused: true, isDismissed: false, isReadback: false), .paused)
        XCTAssertEqual(P.readingState(mode: .speaking, isPaused: true, isDismissed: true, isReadback: false), .pausedHidden)
        XCTAssertEqual(P.readingState(mode: .speaking, isPaused: false, isDismissed: true, isReadback: false), .playingHidden)
        XCTAssertEqual(P.readingState(mode: .idle, isPaused: false, isDismissed: false, isReadback: true), .finished)
        XCTAssertNil(P.readingState(mode: .idle, isPaused: false, isDismissed: false, isReadback: false))
        XCTAssertNil(P.readingState(mode: .recording, isPaused: false, isDismissed: false, isReadback: false))
        XCTAssertEqual(VoiceBarReadingState.allCases.map(\.rawValue), [
            "reading-playing", "reading-playing-hidden", "reading-paused", "reading-paused-hidden", "reading-finished",
        ])
    }

    func testTerminalControlPerState() {
        typealias P = VoiceBarPresentation
        XCTAssertEqual(P.readingTerminalControl(for: .playing).iconName, "stop.fill")
        XCTAssertTrue(P.readingTerminalControl(for: .playing).isDestructive)
        XCTAssertEqual(P.readingTerminalControl(for: .playingHidden).iconName, "stop.fill")
        for paused in [VoiceBarReadingState.paused, .pausedHidden] {
            let control = P.readingTerminalControl(for: paused)
            XCTAssertEqual(control.iconName, "xmark")
            XCTAssertFalse(control.isDestructive)
            XCTAssertEqual(control.accessibilityLabel, "Close read")
        }
        XCTAssertEqual(P.readingTerminalControl(for: .finished).action, .dismissReadback)
    }

    func testWingRevealOnlyWhenHiddenAndCollapsed() {
        typealias P = VoiceBarPresentation
        XCTAssertTrue(P.showsWingTeleprompterReveal(reading: .pausedHidden, bandState: .compactStatus))
        XCTAssertTrue(P.showsWingTeleprompterReveal(reading: .playingHidden, bandState: .compactStatus))
        XCTAssertFalse(P.showsWingTeleprompterReveal(reading: .paused, bandState: .compactStatus))
        XCTAssertFalse(P.showsWingTeleprompterReveal(reading: .pausedHidden, bandState: .teleprompter))
        XCTAssertFalse(P.showsWingTeleprompterReveal(reading: nil, bandState: .compactStatus))
    }

    func testPauseHintNoLongerPromisesACollapse() {
        let pause = VoiceBarPresentation.playbackPauseControl(mode: .speaking, isPaused: false, isReadback: false)
        XCTAssertEqual(pause?.accessibilityHint, "Pause reading; the teleprompter stays open")
    }

    /// Hunt C5 teleprompter #3: the paused scrubber is on screen now and refuses seeks; it says why.
    func testPausedScrubberNamesPauseNotMissingTiming() {
        let state = speakingState()
        state.handleEvent(pausedEvent())
        let control = TeleprompterPlaybackScrubBar(state: state).control
        XCTAssertFalse(control.allowsSeeking, "the paused-slider gate (9084abdc) is preserved")
        XCTAssertEqual(control.helpText, "Paused. Press Play to seek")
        XCTAssertEqual(TeleprompterPlaybackScrubBar.disabledReason(isPaused: false), nil)
    }

    // MARK: - Helpers

    private var now: TimeInterval = 1_000

    private func speakingState() -> VoiceState {
        let state = VoiceState(recentTranscriptionsLoader: { [] }, recentTranscriptionsSaver: { _ in },
                               recentTranscriptionEntriesLoader: { [] }, recentTranscriptionEntriesSaver: { _ in },
                               playbackAmplitudeClock: { [unowned self] in now })
        state.isConnected = true
        state.isCollapsed = false
        state.sendCommand = { _ in }
        state.handleEvent(["type": "state", "state": "speaking", "text": "One two three four five six",
                           "duration_ms": 6000, "playback_id": "l3-read", "generation": 1])
        return state
    }

    private func pausedEvent() -> [String: Any] {
        ["type": "playback_state", "state": "paused", "playback_id": "l3-read", "generation": 2,
         "offset_ms": 2500, "chunk_offset_ms": 2500, "duration_ms": 6000, "word_index": 2, "word_count": 6]
    }

    private func presentation(for state: VoiceState) -> VoiceBarNotchPresentation {
        VoiceBarPresentation.notchPresentation(from: VoiceBarNotchOperationalInput(
            mode: state.mode,
            hasTeleprompterText: state.teleprompterText != nil,
            isTeleprompterDismissed: state.isTeleprompterDismissed,
            isTeleprompterReadback: state.isTeleprompterReadback,
            isPlaybackPaused: state.isPlaybackPaused,
            readQueueLeadingSlotCount: VoiceBarPresentation.playbackLeadingSlotCount(for: state),
            isCollapsed: state.isCollapsed
        ))
    }

    private func mount(_ state: VoiceState,
                       router: BarViewClickabilityTests.SpyCommandRouter = .init()) -> PillHostingView<AnyView> {
        let host = PillHostingView(rootView: AnyView(BarView(
            state: state, commandRouter: router, onOpenSettings: {}, onOpenHistory: {})))
        host.frame = NSRect(x: 0, y: 0, width: 700, height: 360)
        let panel = FloatingPillPanel(content: host)
        panel.setFrameOrigin(NSPoint(x: -100_000, y: -100_000))
        panel.orderBack(nil)
        return host
    }

    /// The native tooltips the mounted notch registered (every icon control registers its own).
    private func mountedTooltips(_ state: VoiceState, until done: @escaping (Set<String>) -> Bool) throws -> Set<String> {
        let host = mount(state)
        defer { host.window?.close() }
        var seen: Set<String> = []
        let ready = expectation(for: NSPredicate { [self] _, _ in
            host.layoutSubtreeIfNeeded()
            seen = Set(descendants(host).compactMap(\.toolTip))
            return done(seen)
        }, evaluatedWith: nil)
        _ = XCTWaiter().wait(for: [ready], timeout: 3)
        return seen
    }

    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }
}
