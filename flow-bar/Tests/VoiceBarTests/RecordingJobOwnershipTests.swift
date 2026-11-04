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
    private func makeState(identity: @escaping () -> (() -> Bool)? = { { true } }) -> VoiceState {
        let state = VoiceState(recentTranscriptionsLoader: { [] }, recentTranscriptionsSaver: { _ in },
            recentTranscriptionEntriesLoader: { [] }, recentTranscriptionEntriesSaver: { _ in })
        state.isConnected = true
        state.dictationTargetIdentityProvider = identity
        state.focusedTargetEligibilityProvider = { [weak state] in
            guard let app = state?.frontmostAppProvider() else { return nil }
            return DictationFocusedTargetEligibility(processIdentifier: app.processIdentifier,
                role: "AXTextArea", isEditable: true, isSecure: false,
                matchesCurrentFocus: identity() ?? { true })
        }
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

    func testOwnedLiveFinalKeepsPolishMetadataWithoutHistoryPartialOrDuplicateOverwrite() {
        let state = makeState()
        state.frontmostAppProvider = { nil }
        state.sendCommand = { _ in }
        func final(_ id: String, extra: [String: Any] = [:]) {
            var event: [String: Any] = ["type": "transcription", "take_id": id,
                "job_kind": "live", "delivery_id": id, "text": "Synthetic owned final"]
            event.merge(extra) { _, new in new }
            state.handleEvent(event)
        }
        // A reconnect final has no original cursor target, but still carries its outcome.
        final("applied", extra: ["polished": true])
        XCTAssertEqual(state.lastTranscriptionPolished, true)
        XCTAssertNil(state.lastTranscriptionPolishReason)

        state.handleEvent(["type": "transcription", "take_id": "history", "job_kind": "history",
            "text": "Synthetic History final", "polished": false, "polish_reason": "history"])
        state.handleEvent(["type": "transcription", "take_id": "partial", "job_kind": "live",
            "partial": true, "text": "Synthetic partial", "polished": false, "polish_reason": "partial"])
        final("applied", extra: ["polished": false, "polish_reason": "duplicate"])
        XCTAssertEqual(state.lastTranscriptionPolished, true)
        XCTAssertNil(state.lastTranscriptionPolishReason)

        final("fallback", extra: ["polished": false, "polish_reason": "Polish budget expired"])
        XCTAssertEqual(state.lastTranscriptionPolished, false)
        XCTAssertEqual(state.lastTranscriptionPolishReason, "Polish budget expired")

        final("applied-again", extra: ["polished": true])
        XCTAssertEqual(state.lastTranscriptionPolished, true)
        XCTAssertNil(state.lastTranscriptionPolishReason)

        final("legacy-without-metadata")
        XCTAssertNil(state.lastTranscriptionPolished)
        XCTAssertNil(state.lastTranscriptionPolishReason)
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

    func testChangedOriginalTargetDeliversToReadyFocusAndLaterTakeStillDelivers() throws {
        let state = makeState()
        let appA = FakeApp("test.editor.A", 11001), appB = FakeApp("test.editor.B", 11002)
        var front: NSRunningApplication? = appA
        var commands: [[String: Any]] = [], scheduled: [() -> Void] = []
        var inserted: [String] = []
        var cursor = "A"
        state.frontmostAppProvider = { front }
        state.targetAppActivator = { front = $0 }
        state.pasteScheduler = { _, work in scheduled.append(work) }
        state.sendCommand = { commands.append($0) }
        state.asyncDictationInsertionHandlerProvider = {
            let owner = cursor
            return { text, completion in
                inserted.append(owner + ":" + text)
                completion(.verified)
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
        XCTAssertEqual(inserted, ["B:" + raw])
        XCTAssertEqual(state.latestDictationInsertionStatus, .insertedAtCursor)
        XCTAssertNil(state.recentTranscriptionEntries.first?.deliveryNote)
        XCTAssertNil(commands.last?["outcome"])
        delivery(a, raw); flush()
        XCTAssertEqual(inserted.count, 1)
        XCTAssertEqual(commands.last?["delivery_id"] as? String, a)
        XCTAssertEqual(state.mode, .recording)
        XCTAssertEqual(state.microphoneTakeID, b)
        delivery(a, raw); flush()
        XCTAssertEqual(inserted.count, 1)
        snapshot(state, jobs: [(b, "live", "processing")])
        delivery(b, "second"); flush()
        XCTAssertEqual(inserted, ["B:" + raw, "B:second"])
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

    func testReadyNativeCursorDeclineFallsBackToSameReadyInput() throws {
        let state = makeState(), app = FakeApp("test.editor.A", 11001)
        var commands: [[String: Any]] = []
        state.sendCommand = { commands.append($0) }
        state.frontmostAppProvider = { app }
        state.targetAppActivator = { _ in }
        state.pasteScheduler = { _, work in work() }
        state.asyncDictationInsertionHandlerProvider = { { _, _ in false } }
        state.ownedTextTypingHandler = { _, _, matches in matches() ? .posted : .focusChanged }
        state.record(pressToTalk: true)
        let id = try XCTUnwrap(commands.last?["take_id"] as? String)
        micOpened(state, id: id, jobs: [(id, "live", "capturing")])
        snapshot(state, jobs: [(id, "live", "processing")])
        state.handleEvent(["type": "transcription", "take_id": id, "job_kind": "live", "delivery_id": id, "text": "Saved instead of misplaced"])
        XCTAssertEqual(state.latestDictationInsertionStatus, .typed)
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

    private func assertNoDrainRefusal(_ state: VoiceState, file: StaticString = #filePath, line: UInt = #line) {
        for phrase in ["Press F5 again", "Finishing previous recording"] {
            XCTAssertFalse((state.confirmationText ?? "").localizedCaseInsensitiveContains(phrase), file: file, line: line)
        }
    }

    func testDrainWindowPressQueuesAndStartsExactlyOnceWhenCaptureReleases() throws {
        let state = makeState()
        var commands: [[String: Any]] = []
        state.sendCommand = { commands.append($0) }
        state.record(pressToTalk: true)
        let a = try XCTUnwrap(commands.last?["take_id"] as? String)
        micOpened(state, id: a, jobs: [(a, "live", "capturing")])
        state.stop()
        VoiceBarCommandRouter(voiceState: state).handleHotkeyHoldStart()
        let b = try XCTUnwrap(state.queuedRecordingTakeID)
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(state.mode, .recording)
        XCTAssertNil(state.confirmationText)
        assertNoDrainRefusal(state)
        XCTAssertEqual(commands.filter { $0["cmd"] as? String == "record" }.count, 1)
        snapshot(state, jobs: [(a, "live", "draining")], mic: a)
        XCTAssertEqual(state.queuedRecordingTakeID, b)
        XCTAssertEqual(state.mode, .recording)
        assertNoDrainRefusal(state)
        snapshot(state, jobs: [(a, "live", "queued")])
        XCTAssertEqual(commands.last?["cmd"] as? String, "record")
        XCTAssertEqual(commands.last?["take_id"] as? String, b)
        state.handleEvent(["type": "ack", "command": "record", "outcome": "accept", "id": try XCTUnwrap(commands.last?["id"] as? String)])
        snapshot(state, jobs: [(a, "live", "processing")])
        micOpened(state, id: b, jobs: [(a, "live", "processing"), (b, "live", "capturing")])
        XCTAssertEqual(state.microphoneTakeID, b)
        XCTAssertEqual(state.mode, .recording)
        XCTAssertNil(state.queuedRecordingTakeID)
        XCTAssertNil(state.confirmationText)
        assertNoDrainRefusal(state)
        XCTAssertEqual(commands.filter { $0["cmd"] as? String == "record" }.count, 2)
        XCTAssertFalse(commands.contains { $0["cmd"] as? String == "cancel" })
    }

    func testDrainAdmissionDoesNotWaitForAsPendingStartAcknowledgement() throws {
        let state = makeState()
        var commands: [[String: Any]] = []
        state.sendCommand = { commands.append($0) }
        state.record(pressToTalk: true)
        let a = try XCTUnwrap(commands.last?["take_id"] as? String)
        XCTAssertNotNil(state.pendingIntent)
        state.stop() // A's stop tail begins before its start ACK reaches the bar.
        VoiceBarCommandRouter(voiceState: state).handleHotkeyHoldStart()
        let b = try XCTUnwrap(state.queuedRecordingTakeID)
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(state.mode, .recording)
        snapshot(state, jobs: [(a, "live", "queued")])
        XCTAssertEqual(commands.last?["cmd"] as? String, "record")
        XCTAssertEqual(commands.last?["take_id"] as? String, b)
        micOpened(state, id: b, jobs: [(a, "live", "processing"), (b, "live", "capturing")])
        XCTAssertEqual(state.microphoneTakeID, b)
        XCTAssertEqual(state.mode, .recording)
        assertNoDrainRefusal(state)
    }

    func testQueuedReleaseStopsBOnlyAfterItsMicrophoneOpens() throws {
        for physical in [false, true] {
            let state = makeState()
            var commands: [[String: Any]] = []
            state.sendCommand = { commands.append($0) }
            state.record(pressToTalk: true)
            let a = try XCTUnwrap(commands.last?["take_id"] as? String)
            micOpened(state, id: a, jobs: [(a, "live", "capturing")])
            state.stop()
            let router = VoiceBarCommandRouter(voiceState: state)
            router.handleHotkeyHoldStart()
            let b = try XCTUnwrap(state.queuedRecordingTakeID)
            if physical { router.handlePhysicalPressStop() } else { router.handleHotkeyHoldEnd(holdDuration: 0.2) }
            XCTAssertEqual(commands.filter { $0["cmd"] as? String == "stop" }.count, 1)
            snapshot(state, jobs: [(a, "live", "processing")])
            XCTAssertEqual(commands.last?["cmd"] as? String, "record")
            // Admission precedes recorder startup and its stop-signal reset. Do not stop yet.
            snapshot(state, jobs: [(a, "live", "processing"), (b, "live", "capturing")], mic: b)
            XCTAssertEqual(commands.last?["cmd"] as? String, "record")
            // A second release in the dispatch/open gap is still B's stop, never A's.
            state.stop(physicalPress: physical)
            XCTAssertEqual(commands.last?["cmd"] as? String, "record")
            micOpened(state, id: b, jobs: [(a, "live", "processing"), (b, "live", "capturing")])
            XCTAssertEqual(commands.last?["cmd"] as? String, "stop")
            XCTAssertEqual(commands.last?["take_id"] as? String, b)
            XCTAssertEqual(commands.last?["physical_press"] as? Bool, physical ? true : nil)
            XCTAssertEqual(commands.filter { $0["cmd"] as? String == "stop" }.count, 2)
            XCTAssertEqual(state.mode, .transcribing)
            assertNoDrainRefusal(state)
        }
    }

    func testF5ParkedReadKeepsQueuedPhysicalReleaseBoundToB() throws {
        for releaseBeforeOpen in [true, false] {
            let state = makeState()
            state.frontmostAppProvider = { nil }
            var commands: [[String: Any]] = []
            state.sendCommand = { commands.append($0) }
            state.handleEvent(["type": "state", "state": "speaking", "text": "one two three",
                "duration_ms": 3000, "playback_id": "read", "generation": 1])
            let router = VoiceBarCommandRouter(voiceState: state)
            router.handleHotkeyHoldStart()
            let a = try XCTUnwrap(commands.last?["take_id"] as? String)
            state.handleEvent(["type": "playback_state", "state": "paused", "playback_id": "read",
                "generation": 2, "offset_ms": 1000, "chunk_offset_ms": 1000, "pause_owner": "f5"])
            micOpened(state, id: a, jobs: [(a, "live", "capturing")])
            router.handleHotkeyHoldEnd(holdDuration: 1)
            router.handleHotkeyHoldStart()
            let b = try XCTUnwrap(state.queuedRecordingTakeID)
            XCTAssertEqual(state.activeCaptureTakeID, b, "The physical key belongs to queued B, not draining A")
            XCTAssertTrue(state.isF5SpeechPausedDuringCapture)
            if releaseBeforeOpen { router.handleHotkeyHoldEnd(holdDuration: 1) }
            snapshot(state, jobs: [(a, "live", "processing")])
            XCTAssertEqual(commands.last?["take_id"] as? String, b)
            micOpened(state, id: b, jobs: [(a, "live", "processing"), (b, "live", "capturing")])
            if !releaseBeforeOpen { router.handleHotkeyHoldEnd(holdDuration: 1) }
            let stops = commands.filter { $0["cmd"] as? String == "stop" }
            XCTAssertEqual(stops.compactMap { $0["take_id"] as? String }, [a, b])
            XCTAssertEqual(stops.last?["physical_press"] as? Bool, true)
            XCTAssertTrue(state.isF5SpeechPausedDuringCapture)
            XCTAssertFalse(commands.contains { ["resume", "cancel"].contains($0["cmd"] as? String ?? "") })
            router.handleHotkeyHoldEnd(holdDuration: 1)
            XCTAssertEqual(commands.filter { $0["cmd"] as? String == "stop" }.count, 2)
            assertNoDrainRefusal(state)
        }
    }

    func testEscapeCancelsQueuedBWithoutCancellingOrRestartingA() throws {
        let state = makeState()
        var commands: [[String: Any]] = []
        state.sendCommand = { commands.append($0) }
        state.record(pressToTalk: true)
        let a = try XCTUnwrap(commands.last?["take_id"] as? String)
        micOpened(state, id: a, jobs: [(a, "live", "capturing")])
        state.stop()
        let router = VoiceBarCommandRouter(voiceState: state)
        router.handleHotkeyHoldStart()
        XCTAssertNotNil(state.queuedRecordingTakeID)
        router.handleEscape()
        XCTAssertNil(state.queuedRecordingTakeID)
        snapshot(state, jobs: [(a, "live", "processing")])
        XCTAssertEqual(commands.filter { $0["cmd"] as? String == "record" }.count, 1)
        XCTAssertFalse(commands.contains { $0["cmd"] as? String == "cancel" })
        XCTAssertEqual(state.processingTakeCount, 1)
        assertNoDrainRefusal(state)
    }

    func testQueuedTargetIsCapturedAtFinalRatherThanAtF5OrDrainCompletion() throws {
        let state = makeState(), app = FakeApp("com.apple.Terminal", 11001)
        var commands: [[String: Any]] = [], typed: [String] = []
        var captures = 0, target = "B"
        state.frontmostAppProvider = { app }
        state.sendCommand = { commands.append($0) }
        state.focusedTargetEligibilityProvider = {
            captures += 1
            let captured = target
            return DictationFocusedTargetEligibility(processIdentifier: app.processIdentifier,
                role: "AXTextArea", isEditable: true, isSecure: false,
                matchesCurrentFocus: { target == captured })
        }
        state.ownedTextTypingHandler = { text, _, matches in
            guard matches() else { return .focusChanged }; typed.append(text); return .posted
        }
        state.pasteScheduler = { _, work in work() }
        state.record(pressToTalk: true)
        let a = try XCTUnwrap(commands.last?["take_id"] as? String)
        micOpened(state, id: a, jobs: [(a, "live", "capturing")])
        state.stop()
        VoiceBarCommandRouter(voiceState: state).handleHotkeyHoldStart()
        let b = try XCTUnwrap(state.queuedRecordingTakeID)
        XCTAssertEqual(captures, 0)
        target = "different element"
        snapshot(state, jobs: [(a, "live", "processing")])
        micOpened(state, id: b, jobs: [(a, "live", "processing"), (b, "live", "capturing")])
        snapshot(state, jobs: [(b, "live", "processing")])
        state.handleEvent(["type": "transcription", "take_id": b, "job_kind": "live", "delivery_id": b, "text": "kept words"])
        XCTAssertEqual(captures, 1)
        XCTAssertEqual(typed, ["kept words"])
        XCTAssertEqual(state.latestDictationInsertionStatus, .typed)
        XCTAssertEqual(state.latestReusableTranscript, "kept words")
    }

    func testQueuedIntentWaitsForExitProofAndSurvivesReconnect() throws {
        let state = makeState()
        var commands: [[String: Any]] = []
        state.sendCommand = { commands.append($0) }
        state.record(pressToTalk: true)
        let a = try XCTUnwrap(commands.last?["take_id"] as? String)
        micOpened(state, id: a, jobs: [(a, "live", "capturing")])
        state.stop()
        VoiceBarCommandRouter(voiceState: state).handleHotkeyHoldStart()
        let b = try XCTUnwrap(state.queuedRecordingTakeID)
        state.handleEvent(["type": "state", "state": "idle", "mic_take_id": NSNull(),
            "capture_error": "Recorder exit unconfirmed", "recording_jobs": [["take_id": a, "kind": "live", "phase": "failed"]]])
        XCTAssertEqual(commands.filter { $0["cmd"] as? String == "record" }.count, 1)
        XCTAssertEqual(state.queuedRecordingTakeID, b)
        state.setConnectionStatus(false)
        state.setConnectionStatus(true)
        snapshot(state, jobs: [(a, "live", "failed")]) // Exit proven by an unblocked snapshot.
        XCTAssertEqual(commands.filter { $0["cmd"] as? String == "record" }.count, 2)
        XCTAssertEqual(commands.last?["take_id"] as? String, b)
        micOpened(state, id: b, jobs: [(a, "live", "failed"), (b, "live", "capturing")])
        XCTAssertEqual(state.recordingMode, "ptt", "Mic-open initializes B even when its UI was already recording")
        XCTAssertEqual(state.microphoneTakeID, b)
        XCTAssertEqual(state.mode, .recording)
        assertNoDrainRefusal(state)
    }

    func testQueuedStartFailureRetiresOpeningIntentAndAllowsRecovery() throws {
        let state = makeState()
        var commands: [[String: Any]] = []
        state.sendCommand = { commands.append($0) }
        snapshot(state, jobs: [("A", "live", "draining")], mic: "A")
        VoiceBarCommandRouter(voiceState: state).handleHotkeyHoldStart()
        snapshot(state, jobs: [("A", "live", "processing")])
        let failedB = try XCTUnwrap(commands.last?["take_id"] as? String)
        state.handleEvent(["type": "ack", "command": "record", "outcome": "reject",
            "id": try XCTUnwrap(commands.last?["id"] as? String), "reason": "mic disabled"])
        XCTAssertEqual(state.mode, .error)
        XCTAssertEqual(state.errorMessage, "mic disabled")
        VoiceBarCommandRouter(voiceState: state).handleHotkeyHoldStart()
        XCTAssertEqual(commands.filter { $0["cmd"] as? String == "record" }.count, 2)
        XCTAssertNotEqual(commands.last?["take_id"] as? String, failedB)
        assertNoDrainRefusal(state)
    }

    func testSourcesCannotProduceDrainRetryConfirmation() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../Sources").standardizedFileURL
        let files = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        var checked = 0
        for case let url as URL in files {
            guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
            let source = try String(contentsOf: url, encoding: .utf8)
            checked += 1
            for phrase in ["Press F5 again", "Finishing previous recording"] {
                XCTAssertFalse(source.localizedCaseInsensitiveContains(phrase), "Forbidden refusal in \(url.path)")
            }
        }
        XCTAssertGreaterThan(checked, 10)
    }

    func testTerminalAndElectronUseReadyWindowAndElementAndStripOneTerminalNewline() throws {
        for bundle in ["com.apple.Terminal", "com.todesktop.230313mzl4w4u92", "test.native"] {
            for changed in [false, true] {
                let state = makeState(), app = FakeApp(bundle, 11001)
                state.chromiumFamilyAppDetector = { _ in bundle != "test.native" && bundle != "com.apple.Terminal" }
                var cursor = "start"
                state.focusedTargetEligibilityProvider = {
                    let readyCursor = cursor
                    return DictationFocusedTargetEligibility(processIdentifier: app.processIdentifier,
                        role: "AXTextArea", isEditable: true, isSecure: false,
                        matchesCurrentFocus: { cursor == readyCursor })
                }
                var commands: [[String: Any]] = [], typed: [String] = [], activations = 0
                state.sendCommand = { commands.append($0) }
                state.frontmostAppProvider = { app }
                state.targetAppActivator = { _ in activations += 1 }
                state.pasteScheduler = { _, work in work() }
                state.guardedTextTypingHandler = { text, _ in typed.append(text); return .posted }
                state.textTypingHandler = { text in typed.append(text); return true }
                state.asyncDictationInsertionHandlerProvider = { { _, done in done(.verified); return true } }
                state.record(pressToTalk: true)
                let id = try XCTUnwrap(commands.last?["take_id"] as? String)
                micOpened(state, id: id, jobs: [(id, "live", "capturing")])
                snapshot(state, jobs: [(id, "live", "processing")])
                if changed { cursor = "ready" }
                state.handleEvent(["type": "transcription", "take_id": id, "job_kind": "live", "delivery_id": id, "text": "full words\n"])
                XCTAssertEqual(activations, 0)
                if bundle == "com.apple.Terminal" { XCTAssertEqual(typed, ["full words"]) }
                else if bundle != "test.native" { XCTAssertEqual(typed, ["full words\n"]) }
                XCTAssertNil(state.recentTranscriptionEntries.first?.deliveryNote)
            }
        }
    }

    private func assertIdentityDelivery(bundle: String, identity: @escaping () -> (() -> Bool)?,
        recordingB: Bool = false, changedProcess: Bool = false, expectTyped: Bool,
        file: StaticString = #filePath, line: UInt = #line) throws {
        let state = makeState(identity: identity), app = FakeApp(bundle, 12001)
        var front: NSRunningApplication = app
        var commands: [[String: Any]] = [], typed: [String] = [], activations = 0
        state.frontmostAppProvider = { front }
        state.sendCommand = { commands.append($0) }
        state.chromiumFamilyAppDetector = { _ in bundle.hasPrefix("com.todesktop") }
        state.targetAppActivator = { _ in activations += 1 }
        state.pasteScheduler = { _, work in work() }
        state.ownedTextTypingHandler = { text, pid, matches in
            guard pid == front.processIdentifier, matches() else { return .focusChanged }
            typed.append(text); return .posted
        }
        state.guardedTextTypingHandler = { _, _ in XCTFail("Owned delivery must recheck its ownership predicate", file: file, line: line); return .failed }
        state.record(pressToTalk: true)
        let a = try XCTUnwrap(commands.last?["take_id"] as? String)
        micOpened(state, id: a, jobs: [(a, "live", "capturing")])
        snapshot(state, jobs: [(a, "live", "processing")])
        if recordingB {
            state.record(pressToTalk: true)
            let b = try XCTUnwrap(commands.last?["take_id"] as? String)
            XCTAssertNotEqual(a, b, file: file, line: line)
            micOpened(state, id: b, jobs: [(a, "live", "processing"), (b, "live", "capturing")])
        }
        if changedProcess { front = FakeApp(bundle, 12002) }
        let event: [String: Any] = ["type": "transcription", "take_id": a, "job_kind": "live", "delivery_id": a, "text": "whole fu… שלום"]
        state.handleEvent(event)
        state.handleEvent(event) // A replay never types twice.
        XCTAssertEqual(typed, expectTyped ? ["whole fu… שלום"] : [], bundle, file: file, line: line)
        XCTAssertEqual(activations, 0, file: file, line: line)
        XCTAssertEqual(state.latestDictationInsertionStatus, expectTyped ? .typed : .notInserted, file: file, line: line)
        XCTAssertEqual(state.latestReusableTranscript, "whole fu… שלום", file: file, line: line)
        XCTAssertEqual(state.recentTranscriptionEntries.first?.deliveryNote, expectTyped ? nil : "Nothing to paste into; copied/kept", file: file, line: line)
    }

    func testUnreadableIdentitySingleElectronTakeTypesExactlyOnce() throws {
        try assertIdentityDelivery(bundle: "com.todesktop.230313mzl4w4u92", identity: { nil }, expectTyped: true)
    }
    func testUnreadableIdentitySingleTerminalTakeTypesExactlyOnce() throws {
        try assertIdentityDelivery(bundle: "com.apple.Terminal", identity: { nil }, expectTyped: true)
    }
    func testUnreadableIdentitySingleGhosttyTakeTypesExactlyOnce() throws {
        try assertIdentityDelivery(bundle: "com.mitchellh.ghostty", identity: { nil }, expectTyped: true)
    }
    func testUnreadableStartIdentityWhileBRecordsUsesReadyInput() throws {
        for bundle in ["com.todesktop.230313mzl4w4u92", "com.apple.Terminal", "com.mitchellh.ghostty"] {
            try assertIdentityDelivery(bundle: bundle, identity: { nil }, recordingB: true, expectTyped: true)
        }
    }
    func testReadableDifferentIdentityIsNotInserted() throws {
        for bundle in ["com.todesktop.230313mzl4w4u92", "com.apple.Terminal", "com.mitchellh.ghostty"] {
            try assertIdentityDelivery(bundle: bundle, identity: { { false } }, expectTyped: false)
        }
    }
    func testChangedProcessBeforeReadyUsesNewProcess() throws {
        try assertIdentityDelivery(bundle: "com.todesktop.230313mzl4w4u92", identity: { nil }, changedProcess: true, expectTyped: true)
    }

    func testPendingBTakeDoesNotInvalidateReadyInput() throws {
        let state = makeState(identity: { nil }), app = FakeApp("com.todesktop.230313mzl4w4u92", 12001)
        var commands: [[String: Any]] = [], attempts = 0
        state.frontmostAppProvider = { app }
        state.chromiumFamilyAppDetector = { _ in true }
        state.sendCommand = { commands.append($0) }
        state.pasteScheduler = { _, work in work() }
        state.targetAppActivator = { _ in XCTFail("Owned fallback must not activate an app") }
        state.ownedTextTypingHandler = { _, _, matches in
            attempts += 1
            state.record(pressToTalk: true) // B is pending; no mic-open snapshot yet.
            XCTAssertTrue(matches(), "A new capture does not change the ready-time input")
            return .posted
        }
        state.record(pressToTalk: true)
        let a = try XCTUnwrap(commands.last?["take_id"] as? String)
        micOpened(state, id: a, jobs: [(a, "live", "capturing")])
        snapshot(state, jobs: [(a, "live", "processing")])
        state.handleEvent(["type": "transcription", "take_id": a, "job_kind": "live", "delivery_id": a, "text": "Keep all these words"])
        XCTAssertEqual(attempts, 1)
        XCTAssertEqual(state.latestDictationInsertionStatus, .typed)
        XCTAssertEqual(state.recentTranscriptionEntries.first?.text, "Keep all these words")
        XCTAssertEqual(commands.filter { $0["cmd"] as? String == "record" }.count, 2)
    }

    @MainActor func testXUsesNewestTakeGuardAndCannotBorrowAnotherTakeGuard() async throws {
        let state = makeState()
        state.processingCancellationTickDuration = .milliseconds(1)
        var commands: [[String: Any]] = []
        state.sendCommand = { commands.append($0) }
        let router = VoiceBarCommandRouter(voiceState: state)
        snapshot(state, jobs: [("A", "live", "processing")])
        router.handleCancel()
        XCTAssertEqual(state.processingCancellationGuard?.takeID, "A")
        let deadline = Date().addingTimeInterval(2)
        while state.processingCancellationGuard?.remainingTicks != 0, Date() < deadline {
            try await Task.sleep(for: .milliseconds(2))
        }
        snapshot(state, jobs: [("A", "live", "processing"), ("B", "live", "queued")])
        router.handleCancel()
        XCTAssertTrue(commands.isEmpty, "A's ready guard cannot cancel B or cancel older A")
        XCTAssertEqual(state.processingCancellationGuard?.takeID, "B")
        XCTAssertFalse(state.commitProcessingCancellation(takeID: "A"), "B's guard cannot cancel A")
        let secondDeadline = Date().addingTimeInterval(2)
        while state.processingCancellationGuard?.remainingTicks != 0, Date() < secondDeadline {
            try await Task.sleep(for: .milliseconds(2))
        }
        router.handleCancel()
        XCTAssertEqual(commands.last?["take_id"] as? String, "B")
        XCTAssertEqual(commands.filter { $0["cmd"] as? String == "cancel" }.count, 1)
    }

    func testReconnectWithoutStartTargetUsesReadyInputAndAcknowledges() {
        let state = makeState()
        var commands: [[String: Any]] = []
        state.sendCommand = { commands.append($0) }
        let app = FakeApp("test.native", 12001)
        state.frontmostAppProvider = { app }
        state.pasteScheduler = { _, work in work() }
        var inserted: [String] = []
        state.asyncDictationInsertionHandlerProvider = { { text, done in
            inserted.append(text); done(.verified); return true
        } }
        state.handleEvent(["type": "transcription", "take_id": "lost-target", "job_kind": "live",
            "delivery_id": "lost-target", "text": "Retain these words"])
        XCTAssertEqual(inserted, ["Retain these words"])
        XCTAssertEqual(state.latestReusableTranscript, "Retain these words")
        XCTAssertEqual(commands.last?["cmd"] as? String, "dictation_delivered")
        XCTAssertEqual(commands.last?["take_id"] as? String, "lost-target")
    }
}
