import XCTest
@testable import VoiceBarUI

@MainActor final class NativeFixReadCadenceTests: XCTestCase {
    func testStatusReadsAreVisibleOnlyAtMostOncePerSecondAndNeverScheduled() {
        let scheduler = ReadScheduler()
        let state = makeState(scheduler)
        var visible = false
        var commands: [[String: Any]] = []
        state.recognizerSettingsIsVisible = { visible }
        state.sendCommand = { commands.append($0) }
        state.setConnectionStatus(true)
        for _ in 0..<20 { state.refreshRecognizerStatus() }
        XCTAssertTrue(commands.isEmpty, "Connect and refresh must be silent while the page is hidden")
        XCTAssertEqual(scheduler.pendingCount, 0)

        visible = true
        state.refreshRecognizerStatus()
        XCTAssertEqual(commands.count, 1)
        for i in 0..<100 {
            scheduler.now = 10 + Double(i) / 100
            state.refreshRecognizerStatus()
        }
        XCTAssertEqual(commands.count, 1, "Burst of visible lifecycle events is limited to one read per second")
        XCTAssertEqual(scheduler.pendingCount, 1)
        scheduler.now = 11
        state.refreshRecognizerStatus()
        XCTAssertEqual(commands.count, 2)
        XCTAssertEqual(scheduler.pendingCount, 0, "An immediate read cancels the pending trailing read")
        scheduler.deliverDue()
        XCTAssertEqual(commands.count, 2)

        visible = false
        scheduler.now = 30
        state.mode = .recording
        state.mode = .transcribing
        state.mode = .speaking
        state.mode = .idle
        state.refreshRecognizerStatus()
        XCTAssertEqual(commands.count, 2, "Hidden capture transitions cannot poll")
        XCTAssertEqual(scheduler.pendingCount, 0)
        visible = true
        state.refreshRecognizerStatus()
        XCTAssertEqual(commands.count, 3)
        XCTAssertTrue(commands.allSatisfy {
            Set($0.keys) == ["cmd", "id"] && $0["cmd"] as? String == "get_recognizer_status"
        })
    }

    func testEventBurstCoalescesOnceAndHiddenPageCancelsTheSend() {
        let scheduler = ReadScheduler()
        let state = makeState(scheduler)
        var visible = true
        var times: [TimeInterval] = []
        state.recognizerSettingsIsVisible = { visible }
        state.sendCommand = { _ in times.append(scheduler.now) }
        state.setConnectionStatus(true)
        for _ in 0..<20 { state.refreshRecognizerStatus() }
        XCTAssertEqual(scheduler.pendingCount, 1)
        XCTAssertEqual(scheduler.nextDeadline, 11)
        visible = false
        scheduler.now = 11.25
        scheduler.deliverDue()
        XCTAssertEqual(times.count, 1, "Hidden trailing event cannot send")
        XCTAssertEqual(scheduler.pendingCount, 0)

        visible = true
        state.refreshRecognizerStatus()
        for _ in 0..<20 { state.refreshRecognizerStatus() }
        XCTAssertEqual(scheduler.pendingCount, 1)
        XCTAssertEqual(scheduler.nextDeadline, 12.25)
        scheduler.now = 12.5
        // Force the hosted interleaving: time has elapsed but the actor has not delivered the read.
        XCTAssertEqual(times.count, 2, "Elapsed time alone does not guarantee actor delivery")
        scheduler.deliverDue()
        XCTAssertEqual(times.count, 3, "One coalesced read for the visible burst")
        XCTAssertEqual(scheduler.pendingCount, 0)
        scheduler.now = 100
        scheduler.deliverDue()
        XCTAssertEqual(times.count, 3, "No periodic poll after the coalesced read")
        XCTAssertTrue(zip(times.dropFirst(), times).allSatisfy { $0.0 - $0.1 >= 1 })
    }

    func testDelayedReadIsCancelledWhenANewerEventAlreadySent() {
        let scheduler = ReadScheduler()
        let state = makeState(scheduler)
        var reads = 0
        state.recognizerSettingsIsVisible = { true }
        state.sendCommand = { _ in reads += 1 }
        state.setConnectionStatus(true)
        state.refreshRecognizerStatus()
        scheduler.now = 20
        state.refreshRecognizerStatus()
        XCTAssertEqual(reads, 2)
        XCTAssertEqual(scheduler.pendingCount, 0)
        scheduler.deliverDue()
        XCTAssertEqual(reads, 2, "A cancelled late callback cannot duplicate the newer read")
        state.refreshRecognizerStatus()
        XCTAssertEqual(scheduler.pendingCount, 1)
        state.setConnectionStatus(false)
        scheduler.now = 21
        scheduler.deliverDue()
        XCTAssertEqual(reads, 2, "A disconnected trailing event cannot send")
        XCTAssertEqual(scheduler.pendingCount, 0)
    }

    private func makeState(_ scheduler: ReadScheduler) -> VoiceState {
        let state = VoiceState(
            recentTranscriptionsLoader: { [] }, recentTranscriptionsSaver: { _ in },
            recentTranscriptionEntriesLoader: { [] }, recentTranscriptionEntriesSaver: { _ in },
            transcriptionVocabularyLoader: { [] }, transcriptionVocabularyAliasLoader: { [] }
        )
        state.recognizerStatusReadClock = { scheduler.now }
        state.scheduleRecognizerStatusRead = { scheduler.schedule(after: $0, read: $1) }
        return state
    }
}

/// Advancing time does not deliver work; tests choose when the main actor can run it.
@MainActor private final class ReadScheduler {
    private final class Job {
        let deadline: TimeInterval
        let read: @MainActor () -> Void
        var cancelled = false
        init(deadline: TimeInterval, read: @escaping @MainActor () -> Void) {
            self.deadline = deadline
            self.read = read
        }
    }
    var now: TimeInterval = 10
    private var jobs: [Job] = []
    var pendingCount: Int { jobs.filter { !$0.cancelled }.count }
    var nextDeadline: TimeInterval? { jobs.filter { !$0.cancelled }.map(\.deadline).min() }

    func schedule(after delay: TimeInterval, read: @escaping @MainActor () -> Void) -> () -> Void {
        let job = Job(deadline: now + delay, read: read)
        jobs.append(job)
        return { job.cancelled = true }
    }

    func deliverDue() {
        let due = jobs.filter { $0.deadline <= now }
        jobs.removeAll { $0.deadline <= now }
        for job in due where !job.cancelled { job.read() }
    }
}
