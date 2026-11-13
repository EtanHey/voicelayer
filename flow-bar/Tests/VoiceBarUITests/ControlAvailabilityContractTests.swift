import XCTest
@testable import VoiceBarUI

/// Named properties of formal/control-availability, asserted directly over every contract cell.
final class ControlAvailabilityContractTests: XCTestCase {
    private typealias A = VoiceControlAvailability
    private let everyFacts = ControlCells.coreFacts + ControlCells.presentationFacts
    private let everyPending: [PendingOperation] = [.recordingHold, .recordingPause, .update, .updateCheck, .clone,
        .recognizerMutation, .speechPreview, .dictionaryCommit, .shortcutCheck]
        + ProcessingKey.allCases.map { .processing($0) } + SpeechSettingKey.allCases.map { .speech($0) }

    private func eval(_ c: VoiceControl, _ f: ControlFacts) -> ControlAvailability {
        A.evaluate(c, f, handlerInstalled: true)
    }

    func testDisabledHasReason() {
        let cells = everyFacts.map { ($0, ControlCells.coreControls + ControlCells.contractOnlyControls) }
            + ControlCells.itemFacts.map { ($0, ControlCells.allControls) }
        for (f, controls) in cells { for c in controls {
            let a = eval(c, f)
            if a.isVisible && !a.isEnabled {
                XCTAssertFalse((a.reason ?? "").isEmpty, "\(c) @ \(f)")
                XCTAssertEqual(a.tooltip, a.reason); XCTAssertEqual(a.accessibilityHint, a.reason)
            }
        } }
    }

    func testStopAlwaysReachableGivenATakeAndSplitFromStopSpeaking() {
        for f0 in everyFacts { for pending in [Set<PendingOperation>(), Set(everyPending)] {
            var f = f0; f.pending = pending
            for c in [VoiceControl.stopRecording, .cancel, .pairedRelease] {
                let a = eval(c, f)
                XCTAssertTrue(a.isVisible, "\(c)")
                if f.hasUnfinishedTake {
                    XCTAssertTrue(a.isEnabled, "\(c) must stay reachable @ \(f)")
                } else {
                    XCTAssertEqual(a.outcome, .unavailable(A.noUnfinishedTake), "\(c) @ \(f)")
                }
            }
            // Bare speech stop follows live speech, never a take (BARE-STOP scoping).
            XCTAssertEqual(eval(.stopSpeaking, f).isEnabled, f.speech, "\(f)")
            if !f.speech { XCTAssertEqual(eval(.stopSpeaking, f).reason, A.nothingSpeaking) }
        } }
    }

    func testHideNeverCancelsATake() {
        for f in everyFacts {
            if eval(.hide, f).isEnabled { XCTAssertFalse(f.hasUnfinishedTake, "\(f)") }
            if f.hasUnfinishedTake, eval(.hide, f).isVisible {
                XCTAssertEqual(eval(.hide, f).reason, "Finish or cancel this take before hiding VoiceBar")
            }
            if f.presentation.hidden { XCTAssertTrue(eval(.show, f).isEnabled, "Show restores presentation only") }
        }
    }

    func testLocalNavigationAvailableWhateverTheTakeGateConnectionOrPending() {
        let navigation = ControlCells.allControls.filter(\.isLocalNavigation)
        XCTAssertGreaterThanOrEqual(navigation.count, 20)
        for f0 in everyFacts {
            var f = f0; f.pending = Set(everyPending)
            for c in navigation {
                let a = eval(c, f)
                if a.isVisible { XCTAssertEqual(a.outcome, .available, "\(c) @ \(f)") }
            }
        }
    }

    func testPendingIsPerOperation() {
        let sample = ControlCells.itemFacts.filter { $0.gate == .open && $0.pending.isEmpty }
        for f in sample { for c in ControlCells.allControls { for op in everyPending
            where op != c.pendingOperation {
            var p = f; p.pending.insert(op)
            XCTAssertEqual(eval(c, p), eval(c, f), "\(op) must not change \(c)")
        } } }
        let live = ControlCells.facts(.connected(canQueueRecording: true), .open, .capturing(.vad),
                                      pending: [.recordingHold])
        XCTAssertEqual(eval(.recordingHold, live).reason, A.waitingForAcknowledgement)
        var idle = live; idle.capture = .none
        XCTAssertTrue(eval(.record, idle).isEnabled, "a pending Lock acknowledgement must not disable Record")
        XCTAssertEqual(eval(.processingToggle(.modelPolish, lockedBy: nil),
                            ControlCells.facts(pending: [.processing(.modelPolish)])).reason, "Saving…")
        XCTAssertTrue(eval(.processingToggle(.outroGate, lockedBy: nil),
                           ControlCells.facts(pending: [.processing(.modelPolish)])).isEnabled)
    }

    func testAgentAskRefusesMediaAndExplainsTheSelectionKey() {
        let asks = [ControlCells.facts(.connected(canQueueRecording: true), .open, .askCapturing),
                    ControlCells.facts(.connected(canQueueRecording: true), .open, .none, [], .askSpeaking),
                    ControlCells.facts(.connected(canQueueRecording: true), .open, .none, .askAnswer)]
        for f in asks {
            for c in [VoiceControl.readClipboard, .preview(.short), .preview(.long), .historyPlay(audio: true)] {
                XCTAssertEqual(eval(c, f).outcome, .unavailable(A.answeringQuestion), "\(c) @ \(f.capture)")
            }
            XCTAssertEqual(eval(.readSelectionKey, f).outcome, .explain(A.answeringQuestion))
            XCTAssertEqual(eval(.record, f).reason, "An agent Ask owns the microphone")
        }
    }

    func testPreviewAndHistoryPlayDisabledDuringPlayback() {
        for b in [PlaybackPhase.preparing, .playing, .paused] {
            let f = ControlCells.facts(.connected(canQueueRecording: true), .open, .none, [], b)
            for c in [VoiceControl.preview(.short), .preview(.long), .historyPlay(audio: true)] {
                XCTAssertEqual(eval(c, f).outcome, .unavailable("Finish the current playback first"), "\(c) @ \(b)")
            }
            XCTAssertTrue(eval(.readClipboard, f).isEnabled, "Read Clipboard replaces the current read")
        }
    }

    func testReservedOpeningBlocksPlaybackEvenWhileModeIsIdle() {
        let reading = Self.reading(mode: .idle, admission: .opening, paused: true)
        let f = ControlAvailabilityAdapter.facts(reading)
        XCTAssertEqual(f.capture, .reservedOpening)
        for c in [VoiceControl.resumePlayback, .previousRead(available: true), .replay, .seek] {
            XCTAssertEqual(eval(c, f).reason, "Finish capture or transcription before playback", "\(c)")
        }
        XCTAssertTrue(eval(.pausePlayback, f).isEnabled, "Pause stays available: it makes speech safe")
        XCTAssertFalse(eval(.hide, f).isEnabled)
    }

    @MainActor
    func testHistoryPlayerAdapterDistinguishesOwnClipFromExternalAdmission() {
        let player = SettingsAudioPlayback(start: { _ in true }, stop: {})
        player.toggle(URL(fileURLWithPath: "/fixture/history.wav"))
        defer { player.stop() }
        XCTAssertNotNil(player.playingURL)
        XCTAssertFalse(player.isVoiceBusy, "Own History playback does not acquire an external voice owner")
        for phase in [PlaybackPhase.preparing, .playing, .paused] {
            var r = Self.reading(mode: .idle, paused: phase == .paused)
            r.isPlaybackPreparing = phase == .preparing
            let f = ControlAvailabilityAdapter.facts(r, historyPlayback: player)
            XCTAssertEqual(f.playback, phase)
            XCTAssertFalse(f.historyVoiceBusy)
            for c in [VoiceControl.preview(.short), .preview(.long), .historyPlay(audio: true)] {
                XCTAssertEqual(eval(c, f).outcome, .unavailable("Finish the current playback first"))
            }
            XCTAssertTrue(eval(.stopSpeaking, f).isEnabled)
            XCTAssertFalse(eval(.update, f).isEnabled)
        }

        player.setVoiceOwner("fixture", busy: true)
        XCTAssertNil(player.playingURL)
        XCTAssertTrue(player.isVoiceBusy)
        let f = ControlAvailabilityAdapter.facts(Self.reading(mode: .idle), historyPlayback: player)
        XCTAssertEqual(f.playback, .none, "An external owner is not the History player's own clip")
        XCTAssertTrue(f.historyVoiceBusy)
        XCTAssertFalse(eval(.stopSpeaking, f).isEnabled)
        XCTAssertEqual(eval(.historyPlay(audio: true), f).reason, SettingsHistoryCopy.playBusy)
    }

    @MainActor
    func testHistoryAdmissionAndOwnPlaybackRemainIndependent() {
        var admitted = true
        let player = SettingsAudioPlayback(start: { _ in true }, stop: {}, canPlay: { admitted })
        defer { player.stop() }
        for ownClip in [false, true] {
            admitted = true
            if ownClip { player.toggle(URL(fileURLWithPath: "/fixture/history.wav")) }
            for externalBusy in [false, true] {
                admitted = !externalBusy
                let f = ControlAvailabilityAdapter.facts(Self.reading(mode: .idle), historyPlayback: player)
                XCTAssertEqual(f.playback, ownClip ? .playing : .none)
                XCTAssertEqual(f.historyVoiceBusy, externalBusy)
                XCTAssertEqual(eval(.historyPlay(audio: true), f).reason,
                               ownClip ? "Finish the current playback first"
                                   : externalBusy ? SettingsHistoryCopy.playBusy : nil)
                XCTAssertEqual(eval(.preview(.short), f).isEnabled, !ownClip,
                               "History's canPlay refusal is not a speech preview owner")
            }
        }
    }

    func testSeekRefusesPausedPlaybackWithExistingExplanation() {
        for processing in ControlCells.processings {
            let f = ControlCells.facts(.connected(canQueueRecording: true), .open, .none, processing, .paused)
            let a = eval(.seek, f)
            XCTAssertTrue(a.isVisible)
            XCTAssertEqual(a.outcome, .unavailable("Paused. Press Play to seek"))
            XCTAssertEqual(a.tooltip, a.reason)
            XCTAssertEqual(a.accessibilityHint, a.reason)
        }
    }

    func testAdapterMapsVoiceStateToPhases() {
        typealias R = VoiceStateReading
        XCTAssertEqual(ControlAvailabilityAdapter.facts(Self.reading(mode: .recording, admission: .capturing,
            recordingMode: "vad")).capture, .capturing(.vad))
        XCTAssertEqual(ControlAvailabilityAdapter.facts(Self.reading(mode: .recording, admission: .capturing,
            recordingPaused: true)).capture, .paused)
        XCTAssertEqual(ControlAvailabilityAdapter.facts(Self.reading(mode: .transcribing, admission: .draining,
            queued: true)).capture, .draining(successorQueued: true))
        XCTAssertEqual(ControlAvailabilityAdapter.facts(Self.reading(mode: .idle, admission: .opening,
            queued: true)).capture, .draining(successorQueued: true), "a queued successor waits behind a drain")
        XCTAssertEqual(ControlAvailabilityAdapter.facts(Self.reading(mode: .recording, admission: .opening,
            askCapture: true)).capture, .askCapturing)
        let ask = ControlAvailabilityAdapter.facts(Self.reading(mode: .speaking, ask: .speaking))
        XCTAssertEqual(ask.playback, .askSpeaking); XCTAssertTrue(ask.agentAsk)
        let answer = ControlAvailabilityAdapter.facts(Self.reading(mode: .transcribing, ask: .answering))
        XCTAssertEqual(answer.processing, .askAnswer)
        let older = ControlAvailabilityAdapter.facts(Self.reading(mode: .idle, processing: 2, history: true))
        XCTAssertEqual(older.processing, [.transcription, .historyRetranscription]); XCTAssertEqual(older.capture, .none)
        XCTAssertEqual(ControlAvailabilityAdapter.facts(Self.reading(mode: .idle, historyAudio: true)).playback, .playing)
        XCTAssertEqual(ControlAvailabilityAdapter.facts(Self.reading(mode: .idle, readback: true)).playback, .readback)
        XCTAssertEqual(ControlAvailabilityAdapter.facts(Self.reading(mode: .disconnected)).connection, .disconnected)
        XCTAssertTrue(ControlAvailabilityAdapter.facts(Self.reading(mode: .idle, hotkey: .holding)).physicalGesture)
        XCTAssertTrue(ControlAvailabilityAdapter.facts(Self.reading(mode: .error)).voiceError)
    }

    func testRecordingHoldAndPauseEnabledOnlyWhereVoiceStateAccepts() {
        // VoiceState.setRecordingHold / setRecordingPaused: mode == .recording, matching recordingMode, no own pending.
        for admission in VoiceStateReading.CaptureAdmission.allCases { for mode in ["vad", "ptt"] {
            for paused in [false, true] { for pending in [false, true] {
                var r = Self.reading(mode: admission == .idle ? .idle : .recording, admission: admission,
                                     recordingMode: mode, recordingPaused: paused)
                if pending { r.pending = [.recordingHold, .recordingPause] }
                let f = ControlAvailabilityAdapter.facts(r)
                let accepts = r.mode == .recording && !pending
                if eval(.recordingHold, f).isEnabled { XCTAssertTrue(accepts && mode == "vad", "hold \(r)") }
                if eval(.recordingPause, f).isEnabled { XCTAssertTrue(accepts && mode == "ptt", "pause \(r)") }
            } }
        } }
    }

    func testRecognizerLoadOnAnotherRowFollowsSelectRules() {
        let other = RecognizerRow(selection: .other, assetsPresent: true, resident: false, downloading: false)
        let selected = RecognizerRow(selection: .selectedHealthy, assetsPresent: true, resident: false, downloading: false)
        XCTAssertTrue(eval(.recognizer(.loadAndSelect, other), ControlCells.facts()).isEnabled)
        XCTAssertEqual(eval(.recognizer(.loadAndSelect, selected), ControlCells.facts()).reason, "Already selected and healthy")
        XCTAssertTrue(eval(.recognizer(.load, selected), ControlCells.facts()).isEnabled)
        XCTAssertEqual(eval(.recognizer(.select, selected), ControlCells.facts()).reason, "Already selected and healthy")
    }

    func testCancelDownloadWorksDisconnectedAndProcessingTogglesExplainLocks() {
        let row = RecognizerRow(selection: .other, assetsPresent: false, resident: false, downloading: true)
        XCTAssertTrue(eval(.recognizer(.cancelDownload, row), ControlCells.facts(.disconnected, .committed)).isEnabled)
        XCTAssertEqual(eval(.processingToggle(.smartChunks, lockedBy: "VOICELAYER_STT_SMART_CHUNKS"), ControlCells.facts()).reason,
                       "Set by VOICELAYER_STT_SMART_CHUNKS")
        var busy = ControlCells.facts(); busy.settingsService = .busy("Voice session in progress")
        XCTAssertEqual(eval(.processingToggle(.modelPolish, lockedBy: nil), busy).reason, "Voice session in progress")
    }

    func testUnwiredControlIsALoudFaultNotAWorkingButton() {
        let a = A.evaluate(.record, ControlCells.facts(), handlerInstalled: false)
        XCTAssertTrue(a.isContractFault); XCTAssertFalse(a.isEnabled); XCTAssertEqual(a.reason, ControlAvailability.unwiredReason)
        XCTAssertFalse(A.evaluate(.show, ControlCells.facts(), handlerInstalled: false).isVisible, "hidden stays hidden")
    }

    func testGateMappingKeepsDrainingAndUnknownOpen() {
        XCTAssertEqual(["OPEN", "DRAINING", "PREPARED", "COMMITTED", nil, "garbage"].map {
            ControlVoiceGate(ledgerKind: $0).admitsNewVoice }, [true, true, false, false, true, true])
        XCTAssertTrue(ControlVoiceGate(permitsNewVoice: true).admitsNewVoice)
        XCTAssertFalse(ControlVoiceGate(permitsNewVoice: false).admitsNewVoice)
    }

    static func reading(mode: VoiceMode, admission: VoiceStateReading.CaptureAdmission = .idle,
                        recordingMode: String? = "ptt", recordingPaused: Bool = false, askCapture: Bool = false,
                        ask: VoiceStateReading.AgentAskSession = .none, queued: Bool = false, processing: Int = 0,
                        history: Bool = false, paused: Bool = false, readback: Bool = false,
                        historyAudio: Bool = false, hotkey: HotkeyPhase = .idle) -> VoiceStateReading {
        VoiceStateReading(mode: mode, isConnected: true, gate: .open, captureAdmission: admission,
                          recordingMode: recordingMode, isRecordingPaused: recordingPaused, isAskCapture: askCapture,
                          agentAskSession: ask, hasQueuedRecording: queued, processingTakeCount: processing,
                          isHistoryRetranscriptionPending: history, supportsRecordingJobs: true,
                          isPlaybackPreparing: false, isPlaybackPaused: paused, isTeleprompterReadback: readback,
                          isHistoryPlaybackActive: historyAudio, isHistoryVoiceBusy: false, isHidden: false, drawer: .none,
                          isModalPresented: false, hotkeyPhase: hotkey, modelsSettings: .ready, pending: [])
    }
}
