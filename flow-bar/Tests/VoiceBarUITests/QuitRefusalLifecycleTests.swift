@testable import VoiceBarUI
import XCTest

/// formal/notch-presentation `NoteHasCause` (OldQuitCause counterexample): the quit refusal stayed for its
/// full six seconds after the voice/update work that refused the quit had already stopped. It now clears at
/// the first recheck after the cause ends, and at the display limit at the latest. No real timers or audio.
@MainActor
final class QuitRefusalLifecycleTests: XCTestCase {
    /// A recheck clock the test advances by hand. Each `sleep` waits for one `release()`.
    private final class Gate {
        var count = 0
        private var waiters: [CheckedContinuation<Void, Never>] = []
        func sleep() async {
            count += 1
            await withCheckedContinuation { waiters.append($0) }
        }
        func yield() {
            guard !waiters.isEmpty else { return }
            waiters.removeFirst().resume()
        }
        func finish() { while !waiters.isEmpty { yield() } }
    }

    private func steppedState() -> (VoiceState, Gate, Gate) {
        let state = VoiceState()
        let gate = Gate()
        state.quitRefusalSleep = { _ in await gate.sleep() }
        return (state, gate, gate)
    }

    private func settle(_ condition: () -> Bool) async -> Bool {
        for _ in 0 ..< 200 where !condition() { try? await Task.sleep(for: .milliseconds(5)) }
        return condition()
    }

    func testTheRefusalClearsWhenItsCauseStops() async {
        let (state, release, ticks) = steppedState()
        var blocked = true
        state.reportQuitRefusal(gateBlocked: true, isGateStillBlocked: { blocked })
        XCTAssertNotNil(state.quitRefusalMessage)
        XCTAssertEqual(state.selectionFeedbackNote, state.quitRefusalMessage, "it is the note the notch shows")

        // Still blocked: the recheck keeps it.
        _ = await settle { ticks.count == 1 }
        release.yield()
        _ = await settle { ticks.count == 2 }
        XCTAssertNotNil(state.quitRefusalMessage, "the work is still running")

        // The update finishes: the very next recheck clears the note, long before the six-second limit.
        blocked = false
        release.yield()
        let cleared = await settle { state.quitRefusalMessage == nil }
        XCTAssertTrue(cleared, "the refusal outlived its cause")
        XCTAssertEqual(ticks.count, 2, "cleared at the first recheck after the cause ended")
        XCTAssertNil(state.selectionFeedbackNote)
        release.finish()
    }

    /// Voice work is read live: the note goes in the same update that ends the work, with no recheck
    /// (formal/notch-presentation Fixed `Normalize`; the replay's cause-ending graph edge).
    func testAVoiceCausedRefusalGoesInTheSameUpdateTheWorkEnds() async {
        let (state, release, ticks) = steppedState()
        state.mode = .recording
        state.reportQuitRefusal()
        XCTAssertEqual(state.selectionFeedbackNote, state.quitRefusalMessage, "shown while recording")
        state.mode = .idle
        XCTAssertNil(state.selectionFeedbackNote, "the cause ended; the note must not wait for a recheck")
        XCTAssertFalse(state.showsQuitRefusal)
        // The next recheck then drops the message itself.
        _ = await settle { ticks.count == 1 }
        release.yield()
        let dropped = await settle { state.quitRefusalMessage == nil }
        XCTAssertTrue(dropped)
        release.finish()
    }

    func testAStillBlockedRefusalExpiresAtTheDisplayLimit() async {
        let (state, release, ticks) = steppedState()
        state.reportQuitRefusal(gateBlocked: true, isGateStillBlocked: { true })
        let rechecks = Int(VoiceState.quitRefusalDisplayLimit / VoiceState.quitRefusalRecheckInterval)
        XCTAssertEqual(rechecks, 24)
        for tick in 1 ..< rechecks {
            _ = await settle { ticks.count == tick }
            XCTAssertNotNil(state.quitRefusalMessage, "tick \(tick)")
            release.yield()
        }
        _ = await settle { ticks.count == rechecks }
        release.yield()
        let expired = await settle { state.quitRefusalMessage == nil }
        XCTAssertTrue(expired, "a refusal never sticks past its limit")
        release.finish()
    }

    func testANewRefusalSupersedesTheOldOnesTimer() async {
        let (state, release, ticks) = steppedState()
        var firstBlocked = true
        state.reportQuitRefusal(gateBlocked: true, isGateStillBlocked: { firstBlocked })
        _ = await settle { ticks.count == 1 }
        state.reportQuitRefusal(gateBlocked: true, isGateStillBlocked: { true })
        firstBlocked = false
        release.yield()
        release.yield()
        _ = await settle { ticks.count >= 2 }
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertNotNil(state.quitRefusalMessage, "the cancelled first check must not clear the second refusal")
        release.finish()
    }
}
