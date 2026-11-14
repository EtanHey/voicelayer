import AppKit
import SwiftUI
@testable import VoiceBarUI
import XCTest

/// Revised 2026-11-10 (X1-32–35): Pause retains text; Hide is independent; a paused read uses X.
/// Keep the eye available for hidden reads, whether playing or paused; distinguish ended reads.
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

    /// R883: the X is clicked for real (mouse down/up at its drawn centre) and reaches Stop's route. Like the eye-row
    /// Stop's own first-click test (WingsU2HostTests), it is clicked in a plain borderless window, which never becomes
    /// key, so key status cannot mask the dispatch.
    func testPausedXEndsTheReadThroughStop() throws {
        let state = speakingState()
        state.handleEvent(pausedEvent())
        let router = BarViewClickabilityTests.SpyCommandRouter()
        let bar = NSHostingView(rootView: BarView(state: state, commandRouter: router, onOpenSettings: {}, onOpenHistory: {}))
        bar.frame = NSRect(x: 0, y: 0, width: 700, height: 360)
        let window = NSWindow(contentRect: bar.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = bar
        window.setFrameOrigin(NSPoint(x: -100_000, y: -100_000))
        window.orderBack(nil)
        plainWindows.append(window)
        let close = try drawnView(in: bar, tooltip: "Close read")
        XCTAssertEqual(router.stopCount, 0)
        click(bar, at: close.convert(NSPoint(x: close.bounds.midX, y: close.bounds.midY), to: nil))
        XCTAssertEqual(router.stopCount, 1, "Close read is Stop's route: a user Stop retains no readback")
        XCTAssertFalse(state.mode == .idle && state.isTeleprompterReadback, "no finished readback is left behind by the X")
    }

    /// R883 P2: the paused scrubber's reason is drawn in the notch, without hover (the frozen slider is disabled and a
    /// SwiftUI `.help` never shows in the non-activating panel).
    func testPausedReasonIsDrawnInTheNotch() throws {
        let state = speakingState()
        state.handleEvent(pausedEvent())
        let host = mount(state)
        defer { host.window?.close() }
        let notice = try drawnView(in: host, tooltip: TeleprompterPlaybackScrubBar.pausedReason)
        XCTAssertFalse(notice.visibleRect.isEmpty, "the pause reason is on screen")
        let eye = try drawnView(in: host, tooltip: "Hide teleprompter")
        XCTAssertEqual(notice.convert(notice.bounds, to: nil).midY, eye.convert(eye.bounds, to: nil).midY, accuracy: 2,
                       "drawn in the eye row, where the timing notice sits")
        // Playing again, the pause reason leaves.
        state.handleEvent(["type": "state", "state": "speaking", "text": "One two three four five six",
                           "duration_ms": 6000, "playback_id": "l3-read", "generation": 3, "playback_offset_ms": 2500])
        state.handleEvent(["type": "playback_state", "state": "resumed", "playback_id": "l3-read", "generation": 3,
                           "offset_ms": 2500, "chunk_offset_ms": 2500])
        XCTAssertFalse(state.isPlaybackPaused)
        let gone = expectation(for: NSPredicate { [self] _, _ in
            host.layoutSubtreeIfNeeded()
            return !descendants(host).contains { $0.toolTip == TeleprompterPlaybackScrubBar.pausedReason }
        }, evaluatedWith: nil)
        wait(for: [gone], timeout: 3)
    }

    /// R893 P2: the read identity the teleprompter's browse state is keyed to.
    func testReadIdentityChangesForANewReadOfTheSameTextOnly() {
        let state = speakingState()
        state.handleEvent(["type": "state", "state": "speaking", "text": "One two three four five six",
                           "duration_ms": 6000, "playback_id": "l3-read", "generation": 1, "utteranceId": "u-1"])
        let first = state.teleprompterReadIdentity
        state.handleEvent(pausedEvent())
        XCTAssertEqual(state.teleprompterReadIdentity, first, "pause keeps the read")
        state.handleEvent(["type": "state", "state": "speaking", "text": "One two three four five six",
                           "duration_ms": 6000, "playback_id": "l3-read", "generation": 3, "utteranceId": "u-1",
                           "playback_offset_ms": 2500])
        XCTAssertEqual(state.teleprompterReadIdentity, first, "resume keeps the read")
        state.handleEvent(["type": "state", "state": "speaking", "text": "One two three four five six",
                           "duration_ms": 6000, "playback_id": "other-read", "generation": 1, "utteranceId": "u-2"])
        XCTAssertNotEqual(state.teleprompterReadIdentity, first, "same text, new utterance: a new read")
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
        XCTAssertEqual(control.helpText, TeleprompterPlaybackScrubBar.pausedReason)
        XCTAssertEqual(TeleprompterPlaybackScrubBar(state: state).notice, TeleprompterPlaybackScrubBar.pausedReason)
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
        panel.isReleasedWhenClosed = false
        panel.setFrameOrigin(NSPoint(x: -100_000, y: -100_000))
        panel.orderBack(nil)
        panels.append(panel) // the test owns its panels; closing never frees one still in use
        return host
    }

    private var panels: [FloatingPillPanel] = []
    private var plainWindows: [NSWindow] = []

    override func tearDown() {
        panels.forEach { $0.close() }
        plainWindows.forEach { $0.close() }
        panels = []
        plainWindows = []
        super.tearDown()
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

    private func drawnView(in host: NSView, tooltip: String) throws -> NSView {
        var found: NSView?
        let ready = expectation(for: NSPredicate { [self] _, _ in
            host.layoutSubtreeIfNeeded()
            found = descendants(host).first { $0.toolTip == tooltip && !$0.visibleRect.isEmpty }
            return found != nil
        }, evaluatedWith: nil)
        _ = XCTWaiter().wait(for: [ready], timeout: 3)
        return try XCTUnwrap(found, "nothing drawn with tooltip \(tooltip): \(Set(descendants(host).compactMap(\.toolTip)).sorted())")
    }

    /// The same synthetic first click BarViewClickabilityTests sends.
    private func click(_ host: NSView, at point: NSPoint) {
        guard let window = host.window else { return XCTFail("no window") }
        XCTAssertNotNil(host.hitTest(host.convert(point, from: nil)), "a hit-test target at the X")
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                                 timestamp: ProcessInfo.processInfo.systemUptime,
                                                 windowNumber: window.windowNumber, context: nil, eventNumber: 1,
                                                 clickCount: 1, pressure: 0) else { return XCTFail("no event") }
            window.sendEvent(event)
        }
    }

    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }
}
