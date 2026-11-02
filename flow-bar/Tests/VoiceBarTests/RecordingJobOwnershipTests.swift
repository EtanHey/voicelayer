import AppKit
@testable import VoiceBar
@testable import VoiceBarUI
import XCTest

final class RecordingJobOwnershipTests: XCTestCase {
    private final class FakeApp: NSRunningApplication, @unchecked Sendable {
        let identifier: String
        let pid: pid_t
        init(_ identifier: String, _ pid: pid_t) { self.identifier = identifier; self.pid = pid; super.init() }
        override var bundleIdentifier: String? { identifier }
        override var processIdentifier: pid_t { pid }
    }
    private func makeState() -> VoiceState {
        let state = VoiceState(recentTranscriptionsLoader: { [] }, recentTranscriptionsSaver: { _ in },
            recentTranscriptionEntriesLoader: { [] }, recentTranscriptionEntriesSaver: { _ in })
        state.isConnected = true
        state.dictationTargetIdentityProvider = { { true } }
        state.pasteboardWriter = { _ in XCTFail("Dictation must never write the clipboard") }
        state.textTypingHandler = { _ in XCTFail("Fixture must use its captured cursor"); return false }
        return state
    }
    private func snapshot(_ state: VoiceState, jobs: [(String, String, String)], mic: String? = nil) {
        state.handleEvent(["type": "state", "state": mic != nil ? "recording" : jobs.isEmpty ? "idle" : "transcribing",
            "mic_take_id": mic as Any, "recording_jobs": jobs.map { ["take_id": $0.0, "kind": $0.1, "phase": $0.2] }])
    }
    private func micOpened(_ state: VoiceState, id: String, jobs: [(String, String, String)]) {
        state.handleEvent(["type": "state", "state": "recording", "mode": "ptt", "bar_owned": true,
            "take_id": id, "job_kind": "live", "mic_take_id": id,
            "recording_jobs": jobs.map { ["take_id": $0.0, "kind": $0.1, "phase": $0.2] }])
    }

    func testF5StartsNewCaptureDuringHistoryAndNeverSendsHistoryCancel() throws {
        let state = makeState()
        var commands: [[String: Any]] = []
        state.sendCommand = { commands.append($0) }
        state.frontmostAppProvider = { nil }
        state.retranscribeHistoryEntry(recordingPath: "/synthetic/3m03/audio.wav")
        let historyID = try XCTUnwrap(commands.first?["id"] as? String)
        snapshot(state, jobs: [(historyID, "history", "processing")])
        let router = VoiceBarCommandRouter(voiceState: state)
        router.handleHotkeyHoldStart()
        XCTAssertEqual(commands.last?["cmd"] as? String, "record")
        let takeID = try XCTUnwrap(commands.last?["take_id"] as? String)
        micOpened(state, id: takeID, jobs: [(historyID, "history", "processing"), (takeID, "live", "capturing")])
        XCTAssertEqual(state.processingTakeCount, 1)
        state.handleEvent(["type": "transcription", "take_id": historyID, "job_kind": "history",
            "text": "Recovered the whole History take", "recording_path": "/synthetic/3m03/audio.wav"])
        snapshot(state, jobs: [(takeID, "live", "capturing")], mic: takeID)
        XCTAssertEqual(state.mode, .recording)
        XCTAssertEqual(state.processingTakeCount, 0)
        XCTAssertFalse(commands.contains { $0["cmd"] as? String == "cancel" })
        state.cancel()
        XCTAssertEqual(commands.last?["take_id"] as? String, takeID)
    }

    func testChangedOriginalTargetIsRetainedWithoutFocusStealAndLaterTakeStillDelivers() throws {
        let state = makeState()
        let appA = FakeApp("test.editor.A", 11001), appB = FakeApp("test.editor.B", 11002)
        var front: NSRunningApplication? = appA
        var commands: [[String: Any]] = [], scheduled: [() -> Void] = []
        var inserted: [String] = [], completionA: ((DictationInsertionResult) -> Void)?
        var cursor = "A"
        state.frontmostAppProvider = { front }
        state.targetAppActivator = { front = $0 }
        state.pasteScheduler = { _, work in scheduled.append(work) }
        state.sendCommand = { commands.append($0) }
        state.asyncDictationInsertionHandlerProvider = {
            let owner = cursor
            return { text, completion in
                inserted.append(owner + ":" + text)
                if owner == "A" { completionA = completion } else { completion(.verified) }
                return true
            }
        }
        func flush() { while !scheduled.isEmpty { scheduled.removeFirst()() } }
        func delivery(_ id: String, _ text: String) {
            state.handleEvent(["type": "transcription", "take_id": id, "job_kind": "live", "delivery_id": id, "text": text])
        }
        state.record(pressToTalk: true)
        let a = try XCTUnwrap(commands.last?["take_id"] as? String)
        micOpened(state, id: a, jobs: [(a, "live", "capturing")])
        snapshot(state, jobs: [(a, "live", "processing")])
        cursor = "B"; front = appB
        state.record(pressToTalk: true)
        let b = try XCTUnwrap(commands.last?["take_id"] as? String)
        XCTAssertNotEqual(a, b)
        micOpened(state, id: b, jobs: [(a, "live", "processing"), (b, "live", "capturing")])
        let raw = "first\r\nשלום fu…\n"
        delivery(a, raw); flush()
        XCTAssertTrue(inserted.isEmpty)
        XCTAssertEqual(state.latestDictationInsertionStatus, .notInserted)
        XCTAssertEqual(state.recentTranscriptionEntries.first?.deliveryNote, "Not pasted: target changed")
        XCTAssertEqual(commands.last?["outcome"] as? String, "not_inserted")
        delivery(a, raw); flush()
        XCTAssertEqual(inserted.count, 0)
        XCTAssertEqual(commands.last?["delivery_id"] as? String, a)
        XCTAssertEqual(state.mode, .recording)
        XCTAssertEqual(state.microphoneTakeID, b)
        delivery(a, raw); flush()
        XCTAssertEqual(inserted.count, 0)
        snapshot(state, jobs: [(b, "live", "processing")])
        delivery(b, "second"); flush()
        XCTAssertEqual(inserted, ["B:second"])
        XCTAssertEqual(commands.last?["delivery_id"] as? String, b)
    }

    func testOwnedAXWatchdogReportsUnverifiedAndLateCompletionDoesNotRepeatAck() throws {
        let state = makeState(), app = FakeApp("test.editor.A", 11001)
        var commands: [[String: Any]] = []
        var completion: ((DictationInsertionResult) -> Void)?
        state.sendCommand = { commands.append($0) }
        state.frontmostAppProvider = { app }
        state.targetAppActivator = { _ in }
        state.pasteScheduler = { _, work in work() }
        state.axInsertionCompletionTimeout = 0.001
        state.asyncDictationInsertionHandlerProvider = { { _, done in completion = done; return true } }
        state.record(pressToTalk: true)
        let id = try XCTUnwrap(commands.last?["take_id"] as? String)
        micOpened(state, id: id, jobs: [(id, "live", "capturing")])
        snapshot(state, jobs: [(id, "live", "processing")])
        state.handleEvent(["type": "transcription", "take_id": id, "job_kind": "live", "delivery_id": id, "text": "keep order"])
        RunLoop.current.run(until: Date().addingTimeInterval(0.025))
        XCTAssertEqual(commands.last?["outcome"] as? String, "unverified")
        let ackCount = commands.filter { $0["cmd"] as? String == "dictation_delivered" }.count
        try XCTUnwrap(completion)(.verified)
        XCTAssertEqual(commands.filter { $0["cmd"] as? String == "dictation_delivered" }.count, ackCount)
        XCTAssertEqual(state.latestDictationInsertionStatus, .unverified)
    }

    func testAnUnavailableOriginalNativeCursorCannotRetargetTypingWithinTheSameApp() throws {
        let state = makeState(), app = FakeApp("test.editor.A", 11001)
        var commands: [[String: Any]] = []
        state.sendCommand = { commands.append($0) }
        state.frontmostAppProvider = { app }
        state.targetAppActivator = { _ in }
        state.pasteScheduler = { _, work in work() }
        state.asyncDictationInsertionHandlerProvider = { { _, _ in false } }
        state.record(pressToTalk: true)
        let id = try XCTUnwrap(commands.last?["take_id"] as? String)
        micOpened(state, id: id, jobs: [(id, "live", "capturing")])
        snapshot(state, jobs: [(id, "live", "processing")])
        state.handleEvent(["type": "transcription", "take_id": id, "job_kind": "live", "delivery_id": id, "text": "Saved instead of misplaced"])
        XCTAssertEqual(state.latestDictationInsertionStatus, .notInserted)
        XCTAssertEqual(state.latestReusableTranscript, "Saved instead of misplaced")
        XCTAssertEqual(commands.last?["delivery_id"] as? String, id)
    }

    @MainActor func testEscapeChoosesNewestQueuedTakeAndGuardsWhenAnotherTakeIsShown() async throws {
        let state = makeState()
        state.processingCancellationTickDuration = .milliseconds(1)
        var commands: [[String: Any]] = []
        state.sendCommand = { commands.append($0) }
        snapshot(state, jobs: [("A", "live", "processing"), ("B", "live", "queued")])
        let router = VoiceBarCommandRouter(voiceState: state)
        router.handleEscape()
        XCTAssertTrue(commands.isEmpty)
        XCTAssertEqual(state.processingCancellationGuard?.takeID, "B")
        let deadline = Date().addingTimeInterval(2)
        while state.processingCancellationGuard?.remainingTicks != 0, Date() < deadline { try await Task.sleep(for: .milliseconds(2)) }
        router.handleEscape()
        XCTAssertEqual(commands.last?["take_id"] as? String, "B")
        XCTAssertFalse(commands.contains { $0["take_id"] as? String == "A" })
    }

    func testLegacyAskCancelStillWorksAfterJobCapabilitySnapshotAndDisconnectResetsOwners() {
        let state = makeState()
        var commands: [[String: Any]] = []
        state.sendCommand = { commands.append($0) }
        snapshot(state, jobs: [])
        state.handleEvent(["type": "state", "state": "recording", "bar_owned": false])
        VoiceBarCommandRouter(voiceState: state).handleEscape()
        XCTAssertEqual(commands.last?["cmd"] as? String, "cancel")
        XCTAssertNil(commands.last?["take_id"])
        snapshot(state, jobs: [("dead", "live", "capturing")], mic: "dead")
        state.prepareForCommandOwner()
        XCTAssertFalse(state.supportsRecordingJobs)
        XCTAssertNil(state.microphoneTakeID)
        snapshot(state, jobs: [("dead", "live", "capturing")], mic: "dead")
        state.setConnectionStatus(false)
        XCTAssertFalse(state.supportsRecordingJobs)
        XCTAssertNil(state.microphoneTakeID)
        XCTAssertEqual(state.processingTakeCount, 0)
        state.setConnectionStatus(true)
        state.handleEvent(["type": "state", "state": "recording", "bar_owned": false])
        state.cancel()
        XCTAssertEqual(commands.last?["cmd"] as? String, "cancel")
        XCTAssertNil(commands.last?["take_id"])
    }

    func testDrainWindowPressIsRejectedVisibly() throws {
        let state = makeState()
        var commands: [[String: Any]] = []
        state.sendCommand = { commands.append($0) }
        state.record(pressToTalk: true)
        let id = try XCTUnwrap(commands.last?["take_id"] as? String)
        micOpened(state, id: id, jobs: [(id, "live", "capturing")])
        state.stop()
        VoiceBarCommandRouter(voiceState: state).handleHotkeyHoldStart()
        XCTAssertEqual(commands.filter { $0["cmd"] as? String == "record" }.count, 1)
        XCTAssertEqual(state.confirmationText, "Finishing previous recording. Press F5 again when ready.")
    }

    func testTerminalAndElectronRequireCapturedWindowAndElementAndStripOneTerminalNewline() throws {
        for bundle in ["com.apple.Terminal", "com.todesktop.230313mzl4w4u92", "test.native"] {
            for changed in [false, true] {
                let state = makeState(), app = FakeApp(bundle, 11001)
                state.chromiumFamilyAppDetector = { _ in bundle != "test.native" && bundle != "com.apple.Terminal" }
                var valid = true, commands: [[String: Any]] = [], typed: [String] = [], activations = 0
                state.sendCommand = { commands.append($0) }
                state.frontmostAppProvider = { app }
                state.dictationTargetIdentityProvider = { { valid } }
                state.targetAppActivator = { _ in activations += 1 }
                state.pasteScheduler = { _, work in work() }
                state.guardedTextTypingHandler = { text, _ in typed.append(text); return .posted }
                state.textTypingHandler = { text in typed.append(text); return true }
                state.asyncDictationInsertionHandlerProvider = { { _, done in done(.verified); return true } }
                state.record(pressToTalk: true)
                let id = try XCTUnwrap(commands.last?["take_id"] as? String)
                micOpened(state, id: id, jobs: [(id, "live", "capturing")])
                snapshot(state, jobs: [(id, "live", "processing")])
                valid = !changed
                state.handleEvent(["type": "transcription", "take_id": id, "job_kind": "live", "delivery_id": id, "text": "full words\n"])
                XCTAssertEqual(activations, 0)
                if changed {
                    XCTAssertTrue(typed.isEmpty)
                    XCTAssertEqual(state.latestDictationInsertionStatus, .notInserted)
                    XCTAssertEqual(state.recentTranscriptionEntries.first?.deliveryNote, "Not pasted: target changed")
                } else if bundle == "com.apple.Terminal" { XCTAssertEqual(typed, ["full words"]) }
            }
        }
    }

    func testReconnectWithoutOriginalTargetStoresWordsAndAcknowledgesWithoutPasting() {
        let state = makeState()
        var commands: [[String: Any]] = []
        state.sendCommand = { commands.append($0) }
        state.pasteHandler = { _ in XCTFail("A reconnect cannot invent the original target"); return true }
        state.handleEvent(["type": "transcription", "take_id": "lost-target", "job_kind": "live",
            "delivery_id": "lost-target", "text": "Retain these words"])
        XCTAssertEqual(state.latestReusableTranscript, "Retain these words")
        XCTAssertEqual(commands.last?["cmd"] as? String, "dictation_delivered")
        XCTAssertEqual(commands.last?["take_id"] as? String, "lost-target")
    }
}
