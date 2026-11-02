import XCTest
@testable import VoiceBarUI

@MainActor
final class RecognizerBindingTests: XCTestCase {
    static func voice() -> VoiceState {
        let state = VoiceState(recentTranscriptionsLoader: { [] }, recentTranscriptionsSaver: { _ in },
                   recentTranscriptionEntriesLoader: { [] }, recentTranscriptionEntriesSaver: { _ in },
                   transcriptionVocabularyLoader: { [] }, transcriptionVocabularyAliasLoader: { [] })
        // This fixture represents the visible Transcription page; events are two seconds apart.
        state.recognizerSettingsIsVisible = { true }
        var clock: TimeInterval = 0
        state.recognizerStatusReadClock = { clock += 2; return clock }
        return state
    }
    static func event(_ revision: Int = 1, desired: String = "whisper", effective: String? = "whisper",
                      phase: String = "ready", parakeet: String = "sleeping", whisper: String = "ready",
                      fallback: String? = nil, allowed: Bool = true, refusal: String? = nil,
                      parakeetAvailable: Bool? = true, assetsPresent: Bool = true) -> [String: Any] {
        ["type": "recognizer_status", "recognizer_status": [
            "revision": revision, "desired": desired, "effective": effective as Any? ?? NSNull(), "phase": phase,
            "engines": ["parakeet": ["phase": parakeet, "assets_present": assetsPresent, "available": parakeetAvailable as Any? ?? NSNull(), "error": NSNull()],
                        "whisper": ["phase": whisper, "assets_present": true, "available": true, "error": NSNull()]],
            "fallback_reason": fallback as Any? ?? NSNull(), "switch_allowed": allowed,
            "switch_refusal_reason": refusal as Any? ?? NSNull(), "idle_unload_seconds": 600, "source": "settings"]]
    }
    func testStrictParserPreservesNullAvailabilitySourceAndIdlePolicy() throws {
        let s = try XCTUnwrap(RecognizerStatusSnapshot(payload: Self.event(parakeetAvailable: nil, assetsPresent: false)["recognizer_status"] as! [String: Any]))
        XCTAssertNil(s.parakeet.available); XCTAssertEqual(s.whisper.available, true)
        XCTAssertEqual(s.idleUnloadSeconds, 600); XCTAssertEqual(s.source, "settings")
        XCTAssertEqual(s.desired, .whisper); XCTAssertEqual(s.effective, .whisper)
    }
    func testUnprovisionedParakeetShowsExactSetupCopyAndKeepsWhisperSelectable() throws {
        let payload = Self.event(desired: "parakeet", effective: nil, phase: "sleeping", parakeetAvailable: nil, assetsPresent: false)["recognizer_status"] as! [String: Any]
        let state = RecognizerPickerState(snapshot: try XCTUnwrap(RecognizerStatusSnapshot(payload: payload)))
        XCTAssertTrue(state.parakeetNotSetUp)
        XCTAssertEqual(state.statusText(for: .parakeet), "Not set up")
        XCTAssertEqual(state.parakeetSetupReason, "Needs a one-time setup")
        XCTAssertEqual(state.statusText(for: .whisper), "Ready")
        XCTAssertFalse(state.canSelect(.parakeet))
        XCTAssertNil(state.retryEngine)
        var sent: [RecognizerPickerEngine] = []
        XCTAssertFalse(state.select(.parakeet, send: { sent.append($0) }))
        XCTAssertTrue(sent.isEmpty, "There is no setup action or provider load disguised as setup")
        XCTAssertTrue(state.select(.whisper, send: { sent.append($0) }))
        XCTAssertEqual(sent, [.whisper])
        let defaultPayload = Self.event(parakeetAvailable: nil, assetsPresent: false)["recognizer_status"] as! [String: Any]
        XCTAssertEqual(RecognizerPickerState(snapshot: try XCTUnwrap(RecognizerStatusSnapshot(payload: defaultPayload))).statusText(for: .parakeet), "Not set up")
    }
    func testFailedLoadAndRuntimeErrorAreNotRelabeledAsUnprovisioned() throws {
        for available in [nil, false] as [Bool?] {
            var payload = Self.event(desired: "parakeet", effective: "whisper", parakeet: "error", fallback: "parakeet-startup-failed", parakeetAvailable: available)["recognizer_status"] as! [String: Any]
            var engines = payload["engines"] as! [String: Any]
            engines["parakeet"] = ["phase": "error", "assets_present": true, "available": available as Any? ?? NSNull(), "error": "parakeet-startup-failed"]
            payload["engines"] = engines
            let state = RecognizerPickerState(snapshot: try XCTUnwrap(RecognizerStatusSnapshot(payload: payload)))
            XCTAssertFalse(state.parakeetNotSetUp)
            XCTAssertNil(state.parakeetSetupReason)
            XCTAssertEqual(state.statusText(for: .parakeet), "Error")
            XCTAssertEqual(state.explanation, "Using Whisper: Parakeet failed to load")
            XCTAssertTrue(state.canSelect(.whisper))
            XCTAssertEqual(state.retryEngine, .parakeet, "An actual provider failure retains retry semantics")
        }
    }
    func testOnlyKnownAvailableParakeetShowsReadyAndSleepingIsDistinctFromSetup() throws {
        for (phase, title) in [("sleeping", "Sleeping (loads when you dictate)"), ("ready", "Ready")] {
            let payload = Self.event(parakeet: phase, parakeetAvailable: true)["recognizer_status"] as! [String: Any]
            let state = RecognizerPickerState(snapshot: try XCTUnwrap(RecognizerStatusSnapshot(payload: payload)))
            XCTAssertFalse(state.parakeetNotSetUp)
            XCTAssertNil(state.parakeetSetupReason)
            XCTAssertEqual(state.statusText(for: .parakeet), title)
            XCTAssertTrue(state.canSelect(.parakeet))
        }
        let unverifiedReady = Self.event(parakeet: "ready", parakeetAvailable: nil, assetsPresent: true)["recognizer_status"] as! [String: Any]
        let state = RecognizerPickerState(snapshot: try XCTUnwrap(RecognizerStatusSnapshot(payload: unverifiedReady)))
        XCTAssertEqual(state.statusText(for: .parakeet), "Unknown")
        XCTAssertFalse(state.parakeetNotSetUp)
    }

    func testProvisionedNeverLoadedParakeetIsSelectable() throws {
        let payload = Self.event(parakeetAvailable: nil, assetsPresent: true)["recognizer_status"] as! [String: Any]
        let state = RecognizerPickerState(snapshot: try XCTUnwrap(RecognizerStatusSnapshot(payload: payload)))
        XCTAssertTrue(state.canSelect(.parakeet))
        XCTAssertFalse(state.parakeetNotSetUp)
        XCTAssertEqual(state.statusText(for: .parakeet), "Sleeping (loads when you dictate)")
    }
    func testInvalidAndUnknownPayloadsFailClosed() {
        let base = Self.event()["recognizer_status"] as! [String: Any]
        let invalid: [(String, Any)] = [("revision", true), ("revision", -1), ("revision", 1.5),
            ("desired", "future"), ("effective", "future"), ("phase", "loaded"),
            ("source", "future"), ("switch_allowed", 1), ("idle_unload_seconds", "600"), ("fallback_reason", 12)]
        for (key, value) in invalid {
            var p = base; p[key] = value; XCTAssertNil(RecognizerStatusSnapshot(payload: p), key)
        }
        for key in base.keys { var p = base; p.removeValue(forKey: key); XCTAssertNil(RecognizerStatusSnapshot(payload: p), key) }
    }
    func testResidencyComesFromEnginePhasesAndAvailabilityRemainsUnknown() throws {
        var p = Self.event(effective: "whisper", phase: "sleeping", whisper: "sleeping")["recognizer_status"] as! [String: Any]
        var snapshot = try XCTUnwrap(RecognizerStatusSnapshot(payload: p))
        XCTAssertEqual(snapshot.effective, .whisper)
        XCTAssertEqual(RecognizerPickerState(snapshot: snapshot).whisper, .unloaded)
        p = Self.event()["recognizer_status"] as! [String: Any]
        p["engines"] = ["parakeet": ["phase": "sleeping", "available": NSNull(), "error": NSNull()],
                        "whisper": ["phase": "ready", "available": NSNull(), "error": NSNull()]]
        snapshot = try XCTUnwrap(RecognizerStatusSnapshot(payload: p))
        XCTAssertNil(snapshot.whisper.available)
        XCTAssertEqual(RecognizerPickerState(snapshot: snapshot).whisper, .loaded)
    }
    func testOneShotWhisperFallbackEndsSleepingWithProvenanceAndNoSmartChunking() throws {
        let p = Self.event(desired: "parakeet", effective: "whisper", phase: "sleeping", parakeet: "error", whisper: "sleeping", fallback: "parakeet-startup-failed")["recognizer_status"] as! [String: Any]
        let state = RecognizerPickerState(snapshot: try XCTUnwrap(RecognizerStatusSnapshot(payload: p)))
        XCTAssertEqual(state.selected, .parakeet); XCTAssertEqual(state.effective, .whisper)
        XCTAssertEqual(state.whisper, .unloaded); XCTAssertFalse(state.smartChunkingApplicable)
        XCTAssertEqual(state.explanation, "Using Whisper: Parakeet failed to load")
    }
    func testVADNoSpeechKeepsParakeetProvenanceWithoutClaimingWhisperRan() throws {
        let p = Self.event(desired: "parakeet", effective: "parakeet", phase: "sleeping", whisper: "sleeping", fallback: "vad-no-speech")["recognizer_status"] as! [String: Any]
        let state = RecognizerPickerState(snapshot: try XCTUnwrap(RecognizerStatusSnapshot(payload: p)))
        XCTAssertEqual(state.effective, .parakeet); XCTAssertEqual(state.whisper, .unloaded)
        XCTAssertEqual(state.explanation, "No speech detected.")
    }
    func testCorrelatedEqualRevisionRefreshUpdatesBusyPermissionInBothDirections() throws {
        let v = Self.voice(); var commands: [[String: Any]] = []; v.sendCommand = { commands.append($0) }
        v.setConnectionStatus(true); v.handleEvent(Self.event(7, allowed: false, refusal: "voice-busy"))
        XCTAssertTrue(v.recognizerPickerState.isSelectionDisabled)
        for allowed in [true, false, true] {
            v.refreshRecognizerStatus()
            var current = Self.event(7, allowed: allowed, refusal: allowed ? nil : "voice-busy")
            current["id"] = try XCTUnwrap(commands.last?["id"])
            v.handleEvent(current)
            XCTAssertEqual(v.recognizerPickerState.isSelectionDisabled, !allowed)
            XCTAssertEqual(v.recognizerSnapshot?.revision, 7)
            XCTAssertEqual(v.recognizerPickerState.selected, .whisper)
            XCTAssertEqual(v.recognizerPickerState.effective, .whisper)
        }
        XCTAssertFalse(commands.contains { $0["cmd"] as? String == "set_recognizer" })
    }

    func testEqualRevisionReadUpdatesOnlyPermissionAndOldIDsCannotWin() throws {
        let v = Self.voice(); var commands: [[String: Any]] = []; v.sendCommand = { commands.append($0) }
        v.setConnectionStatus(true); v.handleEvent(Self.event(7, allowed: false, refusal: "voice-busy"))
        v.refreshRecognizerStatus(); let oldID = try XCTUnwrap(commands.last?["id"])
        v.refreshRecognizerStatus(); let currentID = try XCTUnwrap(commands.last?["id"])
        var old = Self.event(7); old["id"] = oldID; v.handleEvent(old)
        XCTAssertTrue(v.recognizerPickerState.isSelectionDisabled)
        var current = Self.event(7, desired: "parakeet", effective: "parakeet", phase: "error",
                                 parakeet: "error", whisper: "sleeping", fallback: "whisper-startup-failed")
        current["id"] = currentID; v.handleEvent(current)
        XCTAssertFalse(v.recognizerPickerState.isSelectionDisabled)
        XCTAssertEqual(v.recognizerSnapshot?.desired, .whisper)
        XCTAssertEqual(v.recognizerSnapshot?.effective, .whisper)
        XCTAssertEqual(v.recognizerSnapshot?.phase, .loaded)
        XCTAssertEqual(v.recognizerSnapshot?.parakeet.phase, .unloaded)
        XCTAssertEqual(v.recognizerSnapshot?.whisper.phase, .loaded)
        XCTAssertNil(v.recognizerSnapshot?.fallbackReason)
        var stale = Self.event(6, allowed: false, refusal: "voice-busy")
        stale["id"] = currentID; v.handleEvent(stale)
        XCTAssertFalse(v.recognizerPickerState.isSelectionDisabled)
        v.handleEvent(Self.event(7, allowed: false, refusal: "voice-busy"))
        XCTAssertFalse(v.recognizerPickerState.isSelectionDisabled, "Uncorrelated equal-revision duplicates cannot change live permission")
    }

    func testSpeakingSettlementRefreshesVisibleSettingsAtTheSameRevision() throws {
        let v = Self.voice(); var commands: [[String: Any]] = []; v.sendCommand = { commands.append($0) }
        v.setConnectionStatus(true); v.handleEvent(Self.event(7, allowed: false, refusal: "voice-busy"))
        commands.removeAll(); v.mode = .speaking
        XCTAssertEqual(commands.count, 1)
        var busy = Self.event(7, allowed: false, refusal: "voice-busy")
        busy["id"] = try XCTUnwrap(commands.last?["id"]); v.handleEvent(busy)
        commands.removeAll(); v.mode = .idle
        XCTAssertEqual(commands.count, 1)
        var settled = Self.event(7); settled["id"] = try XCTUnwrap(commands.last?["id"])
        v.handleEvent(settled)
        XCTAssertFalse(v.recognizerPickerState.isSelectionDisabled)
        XCTAssertTrue(commands.allSatisfy { $0["cmd"] as? String == "get_recognizer_status" })
        v.recognizerSettingsIsVisible = { false }; commands.removeAll()
        v.mode = .speaking; v.mode = .idle
        XCTAssertTrue(commands.isEmpty, "Hidden Settings cannot poll after speech settlement")
    }

    func testFractionalIdlePolicyPreservesSnapshotAndUsableSelection() throws {
        for seconds in [12.5, 0.125, 2_147_483.0] {
            var payload = Self.event()["recognizer_status"] as! [String: Any]
            payload["idle_unload_seconds"] = seconds
            let snapshot = try XCTUnwrap(RecognizerStatusSnapshot(payload: payload))
            XCTAssertEqual(Double(snapshot.idleUnloadSeconds), seconds)
            XCTAssertEqual(snapshot.revision, 1)
            XCTAssertEqual(snapshot.desired, .whisper)
            XCTAssertFalse(RecognizerPickerState(snapshot: snapshot).isSelectionDisabled)
        }
    }

    func testIdlePolicyRejectsInvalidNumbersWithoutRelaxingRevisionParsing() {
        let invalid: [Any] = [0, -0.5, Double.infinity, -Double.infinity, Double.nan, true, "12.5", NSNull(), 2_147_484]
        for value in invalid {
            var payload = Self.event()["recognizer_status"] as! [String: Any]
            payload["idle_unload_seconds"] = value
            XCTAssertNil(RecognizerStatusSnapshot(payload: payload), String(describing: value))
        }
        let invalidRevisions: [Any] = [12.5, true]
        for revision in invalidRevisions {
            var payload = Self.event()["recognizer_status"] as! [String: Any]
            payload["revision"] = revision
            XCTAssertNil(RecognizerStatusSnapshot(payload: payload))
        }
    }

    func testCaptureTransitionsDisableStaleAllowedSnapshotAndRefreshOncePerTransition() {
        let v = Self.voice(); var commands: [[String: Any]] = []; v.sendCommand = { commands.append($0) }
        v.setConnectionStatus(true); v.handleEvent(Self.event()); commands.removeAll()
        for mode in [VoiceMode.recording, .transcribing] {
            v.mode = mode
            XCTAssertTrue(v.recognizerPickerState.isSelectionDisabled)
            v.selectRecognizer(.parakeet)
        }
        v.mode = .idle
        XCTAssertFalse(v.recognizerPickerState.isSelectionDisabled)
        XCTAssertEqual(commands.filter { $0["cmd"] as? String == "get_recognizer_status" }.count, 3)
        XCTAssertFalse(commands.contains { $0["cmd"] as? String == "set_recognizer" })
    }
    func testConnectReconnectAndExplicitRefreshEachSendOneUniqueRead() {
        let v = Self.voice(); var commands: [[String: Any]] = []; v.sendCommand = { commands.append($0) }
        v.setConnectionStatus(true); v.setConnectionStatus(true); v.refreshRecognizerStatus()
        v.setConnectionStatus(false); v.refreshRecognizerStatus(); v.setConnectionStatus(true)
        XCTAssertEqual(commands.count, 3)
        XCTAssertTrue(commands.allSatisfy { Set($0.keys) == ["cmd", "id"] && $0["cmd"] as? String == "get_recognizer_status" })
        XCTAssertEqual(Set(commands.compactMap { $0["id"] as? String }).count, 3)
    }
    func testClickSendsExactDictionaryOnceWithoutOptimisticSelectionOrReady() throws {
        let v = Self.voice(); var commands: [[String: Any]] = []; v.sendCommand = { commands.append($0) }
        v.setConnectionStatus(true); v.handleEvent(Self.event()); commands.removeAll()
        v.selectRecognizer(.parakeet); v.selectRecognizer(.parakeet)
        XCTAssertEqual(commands.count, 1)
        XCTAssertEqual(Set(commands[0].keys), ["cmd", "recognizer", "id"])
        XCTAssertEqual(commands[0]["cmd"] as? String, "set_recognizer")
        XCTAssertEqual(commands[0]["recognizer"] as? String, "parakeet")
        XCTAssertNotNil(UUID(uuidString: try XCTUnwrap(commands[0]["id"] as? String)))
        XCTAssertEqual(v.recognizerPickerState.selected, .whisper)
        XCTAssertEqual(v.recognizerPickerState.parakeet, .unloaded)
        XCTAssertTrue(v.recognizerPickerState.isSelectionDisabled)
        var ack = Self.event(2, desired: "parakeet", effective: nil, phase: "loading", parakeet: "loading", whisper: "sleeping", allowed: false, refusal: "transition-active")
        ack["type"] = "ack"; ack["command"] = "set_recognizer"; ack["outcome"] = "accept"; ack["id"] = commands[0]["id"]
        v.handleEvent(ack)
        XCTAssertEqual(v.recognizerPickerState.selected, .parakeet); XCTAssertEqual(v.recognizerPickerState.parakeet, .loading)
        XCTAssertNil(v.recognizerPickerState.effective); XCTAssertEqual(commands.count, 1)
    }
    func testBroadcastReadyAndSwitchBackNeverSendUnloadOrPoll() {
        let v = Self.voice(); var commands: [[String: Any]] = []; v.sendCommand = { commands.append($0) }
        v.setConnectionStatus(true)
        var e = Self.event(2, desired: "parakeet", effective: "parakeet", parakeet: "ready", whisper: "sleeping")
        var p = e["recognizer_status"] as! [String: Any]; var engines = p["engines"] as! [String: Any]
        engines["parakeet"] = ["phase": "ready", "assets_present": true, "available": true, "error": NSNull()]; p["engines"] = engines; e["recognizer_status"] = p
        v.handleEvent(e); commands.removeAll(); v.selectRecognizer(.whisper)
        XCTAssertEqual(commands.count, 1); XCTAssertEqual(commands[0]["recognizer"] as? String, "whisper")
        RunLoop.main.run(until: Date().addingTimeInterval(0.05)); XCTAssertEqual(commands.count, 1)
    }
    func testBusySnapshotAndRejectDoNotQueueOrChangeDesired() throws {
        let v = Self.voice(); var commands: [[String: Any]] = []; v.sendCommand = { commands.append($0) }
        v.setConnectionStatus(true); v.handleEvent(Self.event(1, allowed: false, refusal: "capture-active")); commands.removeAll()
        v.selectRecognizer(.parakeet); XCTAssertTrue(commands.isEmpty)
        v.handleEvent(Self.event(2)); v.selectRecognizer(.parakeet)
        var reject = Self.event(3, allowed: false, refusal: "request-active")
        reject["type"] = "ack"; reject["command"] = "set_recognizer"; reject["id"] = try XCTUnwrap(commands.last?["id"])
        reject["outcome"] = "reject"; reject["reason"] = "request-active"; v.handleEvent(reject)
        XCTAssertEqual(v.recognizerPickerState.selected, .whisper)
        XCTAssertEqual(v.recognizerPickerState.explanation, "Wait for transcription before switching recognizers.")
        v.handleEvent(Self.event(4)); XCTAssertFalse(v.recognizerPickerState.isSelectionDisabled)
        XCTAssertEqual(commands.count, 1)
    }
    func testStaleRevisionsAckIDsAndRefreshIDsCannotWin() throws {
        let v = Self.voice(); var commands: [[String: Any]] = []; v.sendCommand = { commands.append($0) }
        v.setConnectionStatus(true); let oldRead = try XCTUnwrap(commands.last?["id"])
        v.refreshRecognizerStatus(); let newRead = try XCTUnwrap(commands.last?["id"])
        var old = Self.event(99); old["id"] = oldRead; v.handleEvent(old); XCTAssertNil(v.recognizerSnapshot)
        var current = Self.event(10); current["id"] = newRead; v.handleEvent(current)
        v.handleEvent(["type": "recognizer_status", "recognizer_status": ["revision": 9]])
        XCTAssertEqual(v.recognizerSnapshot?.revision, 10)
        v.handleEvent(Self.event(9, desired: "parakeet")); XCTAssertEqual(v.recognizerSnapshot?.revision, 10)
        v.handleEvent(Self.event(10, desired: "parakeet")); XCTAssertEqual(v.recognizerSnapshot?.desired, .whisper)
        v.selectRecognizer(.parakeet)
        var ack = Self.event(99, desired: "parakeet"); ack["type"] = "ack"; ack["command"] = "set_recognizer"
        ack["outcome"] = "accept"; ack["id"] = "unknown"; v.handleEvent(ack)
        XCTAssertEqual(v.recognizerSnapshot?.desired, .whisper)
        ack["id"] = commands.last?["id"]; ack["recognizer_status"] = Self.event(8, desired: "parakeet")["recognizer_status"]
        v.handleEvent(ack); XCTAssertEqual(v.recognizerSnapshot?.revision, 10)
        // The terminal ID settles; the stale payload cannot change desired or grant readiness.
        XCTAssertEqual(v.recognizerPickerState.selected, .whisper)
        XCTAssertFalse(v.recognizerPickerState.isSelectionDisabled)
    }
    func testDisconnectClearsReadyAndOldConnectionRepliesCannotReviveIt() throws {
        let v = Self.voice(); var commands: [[String: Any]] = []; v.sendCommand = { commands.append($0) }
        v.setConnectionStatus(true); let oldID = try XCTUnwrap(commands.last?["id"])
        v.handleEvent(Self.event(100)); v.setConnectionStatus(false)
        XCTAssertEqual(v.recognizerPickerState.whisper, .unknown); XCTAssertNil(v.recognizerPickerState.effective)
        v.handleEvent(Self.event(101)); XCTAssertNil(v.recognizerSnapshot)
        v.setConnectionStatus(true); var old = Self.event(102); old["id"] = oldID; v.handleEvent(old)
        XCTAssertNil(v.recognizerSnapshot); v.handleEvent(Self.event(1)); XCTAssertEqual(v.recognizerSnapshot?.revision, 1)
    }
    func testMalformedCurrentEventClearsReadiness() {
        let v = Self.voice(); v.setConnectionStatus(true); v.handleEvent(Self.event())
        v.handleEvent(["type": "recognizer_status", "recognizer_status": ["revision": 2]])
        XCTAssertNil(v.recognizerPickerState.effective); XCTAssertEqual(v.recognizerPickerState.whisper, .unknown)
    }
    func testFallbackKeepsDesiredAndOnlyStartupFailureUsesExactStartupCopy() throws {
        let startup = try XCTUnwrap(RecognizerStatusSnapshot(payload: Self.event(desired: "parakeet", parakeet: "error", fallback: "parakeet-startup-failed")["recognizer_status"] as? [String: Any] ?? [:]))
        let state = RecognizerPickerState(snapshot: startup)
        XCTAssertEqual(state.selected, .parakeet); XCTAssertEqual(state.effective, .whisper)
        XCTAssertEqual(state.explanation, "Using Whisper: Parakeet failed to load")
        // Product decision: desired Parakeet keeps this disabled even during Whisper fallback.
        XCTAssertFalse(state.smartChunkingApplicable)
        for reason in ["language", "prompt", "provider-error", "empty-response", "incomplete-response", "invalid-timing", "sparse-response", "uncovered-tail", "input-format", "input-identity", "vad-no-speech", "future-error"] {
            let p = Self.event(desired: "parakeet", fallback: reason)["recognizer_status"] as! [String: Any]
            let s = RecognizerPickerState(snapshot: try XCTUnwrap(RecognizerStatusSnapshot(payload: p)))
            XCTAssertFalse(s.explanation!.contains("failed to load")); if reason.contains("-") { XCTAssertFalse(s.explanation!.contains(reason)) }
        }
    }
    func testWhisperStartupFailureNamesRestoredParakeetAndKeepsDesiredWhisper() throws {
        let payload = Self.event(desired: "whisper", effective: "parakeet", parakeet: "ready", whisper: "error", fallback: "whisper-startup-failed")["recognizer_status"] as! [String: Any]
        let state = RecognizerPickerState(snapshot: try XCTUnwrap(RecognizerStatusSnapshot(payload: payload)))
        XCTAssertEqual(state.selected, .whisper)
        XCTAssertEqual(state.effective, .parakeet)
        XCTAssertEqual(state.explanation, "Using Parakeet — Whisper failed to load")
        XCTAssertTrue(state.smartChunkingApplicable, "The desired-engine product rule is symmetric during recovery")
    }

    func testSmartChunkingApplicabilityPreservesOtherProcessingRowsAndStoredSetting() throws {
        let health: [String: Any] = ["type": "health", "polish_controls": [
            "model_polish": ["source": "default", "raw": NSNull(), "effective": "on"],
            "outro_gate": ["source": "default", "raw": NSNull(), "effective": true],
            "smart_chunks": ["source": "settings", "raw": NSNull(), "effective": true]]]
        let controls = try XCTUnwrap(PolishControlsState(healthEvent: health))
        let whisper = RecognizerPickerState(selected: .whisper, effective: nil, parakeet: .unloaded, whisper: .unloaded)
        let parakeet = RecognizerPickerState(selected: .parakeet, effective: .parakeet, parakeet: .loaded, whisper: .unloaded)
        let a = ModelsSettingsView.processingRows(for: controls, recognizer: whisper)
        let b = ModelsSettingsView.processingRows(for: controls, recognizer: parakeet)
        XCTAssertEqual(a.count, 3); XCTAssertEqual(Array(a.prefix(2)), Array(b.prefix(2)))
        let enabled = try XCTUnwrap(a.first { $0.key == .smartChunks })
        let disabled = try XCTUnwrap(b.first { $0.key == .smartChunks })
        XCTAssertNil(enabled.lockedReason); XCTAssertEqual(disabled.lockedReason, "Only used with Whisper")
        XCTAssertEqual(disabled.line, "Splits long Whisper recordings at pauses.")
        XCTAssertTrue(enabled.isOn && disabled.isOn && controls.smartChunks.effective)
        // Desired-engine UI applicability does not overwrite the saved backend value.
        let fallback = RecognizerPickerState(selected: .parakeet, effective: .whisper, parakeet: .error, whisper: .loaded)
        let fallbackRow = try XCTUnwrap(ModelsSettingsView.processingRows(for: controls, recognizer: fallback).first { $0.key == .smartChunks })
        XCTAssertEqual(fallbackRow.lockedReason, "Only used with Whisper")
        XCTAssertEqual(controls.smartChunks.source, .settings)
        XCTAssertTrue(fallbackRow.isOn && controls.smartChunks.effective, "Whisper fallback retains the saved chunking value")
    }

    func testSleepingKeepsDesiredAndNoUITimerChangesIt() throws {
        let v = Self.voice(); var commands: [[String: Any]] = []; v.sendCommand = { commands.append($0) }
        v.setConnectionStatus(true); commands.removeAll()
        v.handleEvent(Self.event(2, desired: "parakeet", effective: nil, phase: "sleeping", whisper: "sleeping"))
        XCTAssertEqual(v.recognizerPickerState.selected, .parakeet); XCTAssertEqual(v.recognizerPickerState.parakeet.title, "Sleeping (loads when you dictate)")
        XCTAssertEqual(v.recognizerSnapshot?.idleUnloadSeconds, 600); XCTAssertTrue(commands.isEmpty)
        XCTAssertFalse(v.recognizerPickerState.smartChunkingApplicable)
        let whisper = RecognizerPickerState(selected: .whisper, effective: nil, parakeet: .unloaded, whisper: .unloaded)
        XCTAssertTrue(whisper.smartChunkingApplicable); XCTAssertFalse(RecognizerPickerState.unavailable.smartChunkingApplicable)
    }
}
