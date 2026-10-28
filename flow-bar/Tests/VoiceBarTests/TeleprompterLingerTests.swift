@testable import VoiceBar
@testable import VoiceBarUI
import XCTest

@MainActor
final class TeleprompterLingerTests: XCTestCase {
    private typealias Ticker = AppLifecycleTests.ManualTicker
    private typealias Pointer = AppLifecycleTests.PointerProbe

    private func speakingState() -> VoiceState {
        let state = VoiceState(playbackAmplitudeClock: { 100 })
        state.isConnected = true
        state.isCollapsed = false
        state.sendCommand = { _ in }
        state.handleEvent(["type": "state", "state": "speaking", "text": "Read under test", "duration_ms": 4000,
                           "playback_id": "p", "generation": 1, "readback_id": "rb"])
        return state
    }

    private func presentation(_ state: VoiceState) -> VoiceBarNotchPresentation {
        VoiceBarPresentation.notchPresentation(from: VoiceBarNotchOperationalInput(
            mode: state.mode,
            hasTeleprompterText: state.teleprompterText != nil,
            isTeleprompterDismissed: state.isTeleprompterDismissed,
            isTeleprompterReadback: state.isTeleprompterReadback,
            isCollapsed: state.isCollapsed
        ))
    }

    private func linger(_ coordinator: RetainedReadbackDismissalCoordinator, _ state: VoiceState,
                        _ pointer: Pointer, dismissals: @escaping () -> Void) {
        coordinator.synchronize(
            isReadback: state.isTeleprompterReadback,
            isPointerInsideVisibleSurface: { pointer.isInside }
        ) {
            dismissals()
            state.dismissRetainedTeleprompter()
        }
    }

    func testLingerNeverFiresWhilePaused() async {
        let ticker = Ticker()
        let pointer = Pointer()
        pointer.isInside = false
        var dismissals = 0
        let coordinator = RetainedReadbackDismissalCoordinator(delay: .milliseconds(20), sleep: ticker.sleep)
        let state = speakingState()
        state.handleEvent(["type": "playback_state", "state": "paused", "playback_id": "p", "generation": 2,
                           "offset_ms": 1500, "chunk_offset_ms": 1500])
        XCTAssertTrue(state.isPlaybackPaused)

        linger(coordinator, state, pointer) { dismissals += 1 }
        XCTAssertEqual(ticker.pendingSleepCount, 0, "a paused read is not a finished read: no linger starts")
        XCTAssertEqual(dismissals, 0)
        XCTAssertEqual(state.teleprompterText, "Read under test")
        XCTAssertTrue(state.isPlaybackPaused)
    }

    func testAFinishedReadLingersWhileHoveredAndClosesAfterThePointerLeaves() async {
        let ticker = Ticker()
        let pointer = Pointer()
        var dismissals = 0
        let coordinator = RetainedReadbackDismissalCoordinator(delay: .milliseconds(20), sleep: ticker.sleep)
        let state = speakingState()
        let playing = presentation(state)
        state.handleEvent(["type": "state", "state": "idle", "source": "playback"])
        XCTAssertTrue(state.isTeleprompterReadback)
        let ended = presentation(state)
        XCTAssertEqual(ended.visualState, .teleprompter)
        XCTAssertEqual(ended.geometry.lowerSurfaceHeight, playing.geometry.lowerSurfaceHeight,
                       "the end of a read keeps the open teleprompter's height")
        XCTAssertEqual(ended.geometry.bodyLeadingExtent, playing.geometry.bodyLeadingExtent)
        XCTAssertEqual(ended.geometry.bodyTrailingExtent, playing.geometry.bodyTrailingExtent)

        linger(coordinator, state, pointer) { dismissals += 1 }
        for _ in 0 ..< 5 { await ticker.tick() }
        XCTAssertEqual(dismissals, 0, "hovered: the finished read stays")
        XCTAssertTrue(state.isTeleprompterReadback)

        pointer.isInside = false
        await ticker.tick()
        XCTAssertEqual(dismissals, 0, "the first delay after leaving is the grace")
        await ticker.tick(until: { dismissals == 1 })
        XCTAssertEqual(dismissals, 1)
        XCTAssertFalse(state.isTeleprompterReadback)
        XCTAssertNil(state.teleprompterText)
    }
}
