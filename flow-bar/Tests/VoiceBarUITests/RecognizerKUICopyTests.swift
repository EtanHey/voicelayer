import XCTest
@testable import VoiceBarUI

/// Lane K-ui (2.2.61, lead rulings 00:17Z + 00:32Z): the recognizer notice names the engine that really wrote the text,
/// the keep-warm "Unload when idle" switch (lane K2's contract), and the "loads when you dictate" hint on a Sleeping
/// selected engine.
@MainActor
final class RecognizerKUICopyTests: XCTestCase {
    /// The exact backend chain from the live recording that prompted row 1 (lane K's final format).
    static let liveBackend = "parakeet-resident+fallback-uncovered-tail->whisper.cpp+qualified-fallback"

    /// Real `recognizer_status` events printed by lane K2's `readRecognizerStatus()` (b77367da, M1, isolated state dir):
    /// default, `VOICELAYER_MODEL_UNLOAD_WHEN_IDLE=1`, and the legacy `VOICELAYER_MODEL_IDLE_UNLOAD_SECONDS=300`.
    static let k2Default = #"{"type":"recognizer_status","recognizer_status":{"revision":0,"desired":"whisper","effective":null,"phase":"sleeping","engines":{"parakeet":{"phase":"sleeping","available":null,"error":null,"download":{"state":"idle","received_bytes":0,"total_bytes":0,"error":null},"assets_present":false,"disk_bytes":0},"whisper":{"phase":"sleeping","available":null,"error":null,"download":{"state":"idle","received_bytes":0,"total_bytes":0,"error":null},"assets_present":true,"disk_bytes":1624555275}},"fallback_reason":null,"switch_allowed":true,"switch_refusal_reason":null,"idle_unload_seconds":600,"unload_when_idle":false,"unload_when_idle_locked":false,"unload_when_idle_env_var":null,"source":"default"}}"#
    static let k2Locked = #"{"type":"recognizer_status","recognizer_status":{"revision":0,"desired":"whisper","effective":null,"phase":"sleeping","engines":{"parakeet":{"phase":"sleeping","available":null,"error":null,"download":{"state":"idle","received_bytes":0,"total_bytes":0,"error":null},"assets_present":false,"disk_bytes":0},"whisper":{"phase":"sleeping","available":null,"error":null,"download":{"state":"idle","received_bytes":0,"total_bytes":0,"error":null},"assets_present":true,"disk_bytes":1624555275}},"fallback_reason":null,"switch_allowed":true,"switch_refusal_reason":null,"idle_unload_seconds":600,"unload_when_idle":true,"unload_when_idle_locked":true,"unload_when_idle_env_var":"VOICELAYER_MODEL_UNLOAD_WHEN_IDLE","source":"default"}}"#
    static let k2Legacy = #"{"type":"recognizer_status","recognizer_status":{"revision":0,"desired":"whisper","effective":null,"phase":"sleeping","engines":{"parakeet":{"phase":"sleeping","available":null,"error":null,"download":{"state":"idle","received_bytes":0,"total_bytes":0,"error":null},"assets_present":false,"disk_bytes":0},"whisper":{"phase":"sleeping","available":null,"error":null,"download":{"state":"idle","received_bytes":0,"total_bytes":0,"error":null},"assets_present":true,"disk_bytes":1624555275}},"fallback_reason":null,"switch_allowed":true,"switch_refusal_reason":null,"idle_unload_seconds":300,"unload_when_idle":true,"unload_when_idle_locked":true,"unload_when_idle_env_var":"VOICELAYER_MODEL_IDLE_UNLOAD_SECONDS","source":"default"}}"#

    private static func decode(_ line: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
    }

    private static func payload(_ revision: Int = 1, desired: String = "parakeet", effective: String? = "parakeet",
                                parakeet: String = "ready", whisper: String = "sleeping", fallback: String? = nil,
                                unloadWhenIdle: Bool? = nil, locked: Bool = false, envVar: String? = nil,
                                parakeetBytes: Int = 2_509_000_000) -> [String: Any] {
        var event = RecognizerBindingTests.event(revision, desired: desired, effective: effective,
                                                 parakeet: parakeet, whisper: whisper, fallback: fallback)
        var p = event["recognizer_status"] as! [String: Any]
        var engines = p["engines"] as! [String: Any]
        var pk = engines["parakeet"] as! [String: Any]; pk["disk_bytes"] = parakeetBytes; engines["parakeet"] = pk
        p["engines"] = engines
        if let unloadWhenIdle {
            p["unload_when_idle"] = unloadWhenIdle; p["unload_when_idle_locked"] = locked
            p["unload_when_idle_env_var"] = envVar as Any? ?? NSNull()
        }
        event["recognizer_status"] = p
        return event
    }
    private static func state(_ event: [String: Any]) throws -> RecognizerPickerState {
        RecognizerPickerState(snapshot: try XCTUnwrap(RecognizerStatusSnapshot(payload: event["recognizer_status"] as! [String: Any])))
    }

    // MARK: Row 1: the notice says what really happened

    func testLiveBackendNamesWhisperAsTheWriterAndNeverSaysParakeetCouldNotTranscribe() throws {
        let p = try XCTUnwrap(RecognizerProvenance(backend: Self.liveBackend))
        XCTAssertEqual(p.firstEngine, .parakeet)
        XCTAssertEqual(p.writer, .whisper, "the engine after the last -> wrote the text")
        XCTAssertEqual(p.fallbackReason, "uncovered-tail")
        XCTAssertEqual(p.notice, "Whisper transcribed this recording: Parakeet's text stopped before the ending.")
        XCTAssertFalse(p.notice!.contains("couldn't"))
        // The same chain through the resident server, with suffixes after the writer.
        XCTAssertEqual(RecognizerProvenance(backend: "parakeet-resident+fallback-uncovered-tail->whisper-server+outro+qualified-fallback")?.notice,
                       p.notice)
    }

    func testReasonsWhereParakeetReturnedTextNeverClaimItCouldNotTranscribe() {
        for reason in ["uncovered-tail", "sparse-response", "invalid-timing", "incomplete-response", "provider-partial",
                       "empty-response", "zero-pcm-response", "unsupported-language", "timeout", "language", "prompt",
                       "parakeet-startup-failed", "some-future-reason"] {
            let notice = RecognizerProvenance(backend: "parakeet-resident+fallback-\(reason)->whisper.cpp+qualified-fallback")?.notice
            XCTAssertNotNil(notice, reason)
            XCTAssertFalse(notice!.contains("couldn't"), "\(reason): \(notice!)")
            XCTAssertFalse(notice!.contains(reason) && reason.contains("-"), "\(reason) leaks a reason code")
            XCTAssertTrue(notice!.contains("Whisper"), "\(reason): the writer is named")
        }
        // A real provider failure may say so.
        XCTAssertEqual(RecognizerProvenance(backend: "parakeet-resident+fallback-provider-error->whisper.cpp+qualified-fallback")?.notice,
                       "Whisper transcribed this recording because Parakeet couldn't transcribe it.")
    }

    func testNoHandOffHasNoNoticeAndOtherDirectionsNameTheirWriter() {
        for plain in ["parakeet-resident", "whisper-server+outro", "whisper.cpp", "wispr-flow",
                      "whisper-server+fallback-timeout->whisper.cpp"] {
            XCTAssertNil(RecognizerProvenance(backend: plain)?.notice, plain)
        }
        XCTAssertEqual(RecognizerProvenance(backend: "whisper-server+fallback-whisper-startup-failed->parakeet-resident")?.notice,
                       "Parakeet transcribed this recording: Whisper failed to load.")
        for junk in [nil, "", "   ", "fake-stt"] { XCTAssertNil(RecognizerProvenance(backend: junk), junk ?? "nil") }
    }

    func testHistoryEngineFactNamesTheWriterAndExplainsTheHandOff() {
        XCTAssertEqual(SettingsHistoryDiagnosticsCopy.engineName(Self.liveBackend), "Whisper", "was \"Parakeet\" before K-ui")
        let facts = SettingsHistoryDiagnosticsCopy.engineFacts(Self.liveBackend)
        XCTAssertEqual(facts.map(\.title), ["Engine", "Transcription error"])
        XCTAssertEqual(facts.map(\.value), ["Whisper", "Parakeet missed the ending, so Whisper transcribed this recording."])
        XCTAssertEqual(SettingsHistoryDiagnosticsCopy.engineFacts("parakeet-resident").map(\.title), ["Engine"])
        XCTAssertEqual(SettingsHistoryDiagnosticsCopy.engineFacts("fake-stt"), [])
    }

    func testPickerNoticeFromTheSnapshotReasonNamesWhisperAndDoesNotBlameParakeetForWhisperAlone() throws {
        let tail = try Self.state(Self.payload(effective: "whisper", parakeet: "sleeping", whisper: "ready", fallback: "uncovered-tail"))
        XCTAssertEqual(tail.explanation, "Whisper transcribed your last recording: Parakeet's text stopped before the ending.")
        // Whisper selected, server -> CLI fallback: Parakeet was never involved (the old copy blamed it).
        let whisperOnly = try Self.state(Self.payload(desired: "whisper", effective: "whisper", parakeet: "sleeping",
                                                      whisper: "ready", fallback: "timeout"))
        XCTAssertNil(whisperOnly.explanation)
    }

    // MARK: Row 1, review round 2: status fields alone never prove a delivered transcript

    /// parakeet-backend.ts publishes effective=whisper + the reason BEFORE awaiting Whisper (Codex probe, adapted).
    func testLoadingFallbackMustNotClaimACompletedTranscript() throws {
        let event = RecognizerBindingTests.event(2, desired: "parakeet", effective: "whisper", phase: "loading",
            parakeet: "sleeping", whisper: "loading", fallback: "uncovered-tail", allowed: false, refusal: "request-active")
        let voice = RecognizerBindingTests.voice(); voice.setConnectionStatus(true); voice.handleEvent(event)
        let state = voice.recognizerPickerState
        let line = try XCTUnwrap(state.explanation)
        XCTAssertFalse(line.contains("transcribed your last recording"), "Whisper has not returned any transcript")
        XCTAssertFalse(line.contains("last recording"), "the current operation is never pinned on the previous recording")
        XCTAssertEqual(line, "Transcribing this recording with Whisper…")
        XCTAssertFalse(state.explanationIsWarning, "work in progress is a normal status line")
    }

    /// observeRecognizerBackend (stt.ts) marks the effective engine error after the fallback throws; effective and the
    /// reason remain (Codex probe, adapted).
    func testFailedFallbackMustNotClaimACompletedTranscript() throws {
        let event = RecognizerBindingTests.event(3, desired: "parakeet", effective: "whisper", phase: "error",
            parakeet: "sleeping", whisper: "error", fallback: "uncovered-tail")
        let voice = RecognizerBindingTests.voice(); voice.setConnectionStatus(true); voice.handleEvent(event)
        let state = voice.recognizerPickerState
        let line = try XCTUnwrap(state.explanation)
        XCTAssertFalse(line.contains("transcribed your last recording"), "Whisper failed without delivering a transcript")
        XCTAssertFalse(line.contains("last recording"), "the failure is never pinned on the previous recording")
        XCTAssertEqual(line, "Whisper couldn't finish this recording.")
        XCTAssertTrue(state.explanationIsWarning)
    }

    /// The whole sequence the daemon publishes: fallback starts, fails, the next take's fallback is delivered by the
    /// server (ready) or the CLI (sleeping). Only the delivered states claim a transcript.
    func testCompletedClaimAppearsOnlyAfterTheFallbackDelivered() throws {
        let voice = RecognizerBindingTests.voice(); voice.setConnectionStatus(true)
        let completed = "Whisper transcribed your last recording: Parakeet's text stopped before the ending."
        let sequence: [(Int, String, String?)] = [
            (1, "loading", "Transcribing this recording with Whisper…"),
            (2, "error", "Whisper couldn't finish this recording."),
            (3, "loading", "Transcribing this recording with Whisper…"),
            (4, "ready", completed),
            (5, "sleeping", completed),
        ]
        for (revision, whisper, expected) in sequence {
            voice.handleEvent(RecognizerBindingTests.event(revision, desired: "parakeet", effective: "whisper",
                                                           phase: whisper, parakeet: "sleeping", whisper: whisper,
                                                           fallback: "uncovered-tail"))
            XCTAssertEqual(voice.recognizerPickerState.explanation, expected, "whisper=\(whisper)")
        }
        // A later Parakeet success clears it.
        voice.handleEvent(RecognizerBindingTests.event(6, desired: "parakeet", effective: "parakeet", parakeet: "ready", whisper: "sleeping"))
        XCTAssertNil(voice.recognizerPickerState.explanation)
        // Whisper selected and loading through its own server -> CLI step: no hand-off, so no Parakeet wording.
        let own = try Self.state(Self.payload(desired: "whisper", effective: "whisper", parakeet: "sleeping",
                                              whisper: "loading", fallback: "timeout"))
        XCTAssertFalse(own.explanation?.contains("Parakeet") ?? false)
        XCTAssertFalse(own.explanation?.contains("Transcribing this recording") ?? false)
    }

    // MARK: Row 2: Unload when idle (K2 contract), OFF by default

    func testRealK2DefaultStatusDecodesToAnOffUnlockedRow() throws {
        let event = try Self.decode(Self.k2Default)
        let snapshot = try XCTUnwrap(RecognizerStatusSnapshot(payload: event["recognizer_status"] as! [String: Any]))
        XCTAssertEqual(snapshot.unloadWhenIdle, RecognizerUnloadWhenIdle(effective: false, locked: false, environmentVariable: nil))
        let row = try XCTUnwrap(ModelsSettingsView.unloadWhenIdleRow(for: RecognizerPickerState(snapshot: snapshot)))
        XCTAssertFalse(row.isOn, "Etan ruling: Parakeet stays resident; the switch is off by default")
        XCTAssertNil(row.lockedReason)
        XCTAssertFalse(row.disabled)
        XCTAssertEqual(row.title, "Unload when idle", "Parakeet is not set up in this status, so no size is claimed")
        // Through the socket path too.
        let voice = RecognizerBindingTests.voice(); voice.setConnectionStatus(true); voice.handleEvent(event)
        XCTAssertEqual(voice.recognizerPickerState.unloadWhenIdle?.effective, false)
    }

    func testRealK2LockedStatusesShowTheDaemonsVariableVerbatim() throws {
        for (line, variable) in [(Self.k2Locked, "VOICELAYER_MODEL_UNLOAD_WHEN_IDLE"),
                                 (Self.k2Legacy, "VOICELAYER_MODEL_IDLE_UNLOAD_SECONDS")] {
            let event = try Self.decode(line)
            let s = try Self.state(event)
            XCTAssertEqual(s.unloadWhenIdle?.locked, true)
            let row = try XCTUnwrap(ModelsSettingsView.unloadWhenIdleRow(for: s))
            XCTAssertTrue(row.isOn, "\(variable) enables idle eviction")
            XCTAssertTrue(row.disabled)
            XCTAssertEqual(row.lockedReason, "Set by \(variable)")
            XCTAssertEqual(row.captionLines.count, 2, "the explanation stays; the lock adds its reason below")
            // A locked switch sends nothing.
            let voice = RecognizerBindingTests.voice(); var sent: [[String: Any]] = []; voice.sendCommand = { sent.append($0) }
            voice.setConnectionStatus(true); voice.handleEvent(event); sent.removeAll()
            voice.setRecognizerUnloadWhenIdle(false)
            XCTAssertTrue(sent.isEmpty, variable)
        }
    }

    func testOlderDaemonWithoutTheFieldGetsNoRowAndMalformedFieldsAreIgnored() throws {
        var event = try Self.decode(Self.k2Default)
        var status = event["recognizer_status"] as! [String: Any]
        for key in ["unload_when_idle", "unload_when_idle_locked", "unload_when_idle_env_var"] { status[key] = nil }
        event["recognizer_status"] = status
        let s = try Self.state(event)
        XCTAssertNil(s.unloadWhenIdle)
        XCTAssertNil(ModelsSettingsView.unloadWhenIdleRow(for: s))
        let malformed: [(String, Any)] = [("unload_when_idle", 1), ("unload_when_idle", "false"), ("unload_when_idle_locked", "yes"),
                                          ("unload_when_idle_env_var", 3)]
        for (key, bad) in malformed {
            var p = try Self.decode(Self.k2Default)["recognizer_status"] as! [String: Any]
            p[key] = bad
            XCTAssertNil(try XCTUnwrap(RecognizerStatusSnapshot(payload: p)).unloadWhenIdle, "\(key)=\(bad)")
        }
        let unnamed = RecognizerUnloadWhenIdle(effective: true, locked: true, environmentVariable: nil)
        XCTAssertEqual(unnamed.lockedReason, "Set by the environment", "no variable name is ever invented")
    }

    func testRowMeasuresParakeetsReportedSizeWhicheverEngineIsSelected() throws {
        let s = try Self.state(Self.payload(unloadWhenIdle: false))
        let row = try XCTUnwrap(ModelsSettingsView.unloadWhenIdleRow(for: s))
        // U3a (SPEC 2.3): the title is plain; the saving moves into the description.
        XCTAssertEqual(row.title, "Unload when idle")
        XCTAssertEqual(row.captionLines, ["Frees ~2.5 GB after 10 min idle. Next dictation reloads Parakeet (few seconds)."], "from the reported 2.51 GB")
        let bigger = try Self.state(Self.payload(unloadWhenIdle: false, parakeetBytes: 3_100_000_000))
        XCTAssertTrue(try XCTUnwrap(ModelsSettingsView.unloadWhenIdleRow(for: bigger)).line.hasPrefix("Frees ~3 GB "),
                      "the size follows the model")
        let whisperSelected = try Self.state(Self.payload(desired: "whisper", effective: "whisper", parakeet: "sleeping",
                                                          whisper: "ready", unloadWhenIdle: false))
        XCTAssertTrue(try XCTUnwrap(ModelsSettingsView.unloadWhenIdleRow(for: whisperSelected)).line.hasPrefix("Frees ~2.5 GB "))
        XCTAssertEqual(ModelsSettingsView.approximateSize(640_000_000), "640 MB")
        XCTAssertNil(ModelsSettingsView.approximateSize(0))
        XCTAssertEqual(ModelsSettingsView.unloadWhenIdleRow(for: try Self.state(Self.payload(unloadWhenIdle: false, parakeetBytes: 0)))?.title,
                       "Unload when idle")
        XCTAssertEqual(ModelsSettingsView.unloadWhenIdleRow(for: s, canChange: false)?.disabled, true)
    }

    func testParakeetLineFollowsTheSwitch() throws {
        XCTAssertEqual(try Self.state(Self.payload(unloadWhenIdle: false)).autoLoadLine(for: .parakeet), "Stays loaded between takes.")
        XCTAssertEqual(try Self.state(Self.payload(unloadWhenIdle: true)).autoLoadLine(for: .parakeet), "Unloads after 10 min idle to free memory.")
        XCTAssertNil(try Self.state(Self.payload(parakeet: "sleeping", unloadWhenIdle: false)).autoLoadLine(for: .parakeet),
                     "Sleeping already says it loads when you dictate")
        XCTAssertEqual(try Self.state(Self.payload()).autoLoadLine(for: .parakeet),
                       "Loads automatically when selected; unloads after 10 min idle.", "older daemons keep the old line")
        XCTAssertEqual(try Self.state(Self.payload(desired: "whisper", effective: "whisper", parakeet: "sleeping", whisper: "ready",
                                                   unloadWhenIdle: false)).autoLoadLine(for: .whisper),
                       "Loads automatically when selected; unloads after 10 min idle.", "the switch governs Parakeet only")
    }

    func testVoiceStateSendsK2CommandAndSettlesOnTheHigherRevisionAck() throws {
        let voice = RecognizerBindingTests.voice(); var sent: [[String: Any]] = []; voice.sendCommand = { sent.append($0) }
        voice.setConnectionStatus(true)
        voice.handleEvent(Self.payload(1, unloadWhenIdle: false)); sent.removeAll()
        voice.setRecognizerUnloadWhenIdle(false)
        XCTAssertTrue(sent.isEmpty, "already off")
        voice.setRecognizerUnloadWhenIdle(true)
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent.last?["cmd"] as? String, "set_model_unload_when_idle")
        XCTAssertEqual(sent.last?["value"] as? Bool, true)
        let id = try XCTUnwrap(sent.last?["id"] as? String)
        XCTAssertEqual(voice.recognizerPickerState.unloadWhenIdlePending, true)
        XCTAssertEqual(ModelsSettingsView.unloadWhenIdleRow(for: voice.recognizerPickerState)?.isOn, true, "shows the choice while pending")
        XCTAssertEqual(ModelsSettingsView.unloadWhenIdleRow(for: voice.recognizerPickerState)?.disabled, true)
        voice.setRecognizerUnloadWhenIdle(false)
        XCTAssertEqual(sent.count, 1, "one write at a time")
        // K2: an accepted write increments the revision and acks with the fresh status.
        var ack = Self.payload(2, unloadWhenIdle: true)
        ack["type"] = "ack"; ack["command"] = "set_model_unload_when_idle"; ack["id"] = id; ack["outcome"] = "accept"
        voice.handleEvent(ack)
        XCTAssertNil(voice.recognizerPickerState.unloadWhenIdlePending)
        XCTAssertEqual(voice.recognizerPickerState.unloadWhenIdle?.effective, true)
        XCTAssertEqual(voice.recognizerSnapshot?.revision, 2)
        XCTAssertNil(voice.recognizerPickerState.explanation)
    }

    func testRejectShowsTheDaemonsReasonAndABareAckKeepsThePicker() throws {
        let voice = RecognizerBindingTests.voice(); var sent: [[String: Any]] = []; voice.sendCommand = { sent.append($0) }
        voice.setConnectionStatus(true)
        voice.handleEvent(Self.payload(1, unloadWhenIdle: false)); sent.removeAll()
        voice.setRecognizerUnloadWhenIdle(true)
        var reject = Self.payload(1, unloadWhenIdle: false)
        reject["type"] = "ack"; reject["command"] = "set_model_unload_when_idle"; reject["id"] = sent.last?["id"]
        reject["outcome"] = "reject"; reject["reason"] = "set by VOICELAYER_MODEL_UNLOAD_WHEN_IDLE"
        voice.handleEvent(reject)
        XCTAssertEqual(voice.recognizerPickerState.explanation, "Couldn't change Unload when idle: set by VOICELAYER_MODEL_UNLOAD_WHEN_IDLE.")
        XCTAssertNil(voice.recognizerPickerState.unloadWhenIdlePending)
        XCTAssertEqual(voice.recognizerPickerState.unloadWhenIdle?.effective, false)

        voice.setRecognizerUnloadWhenIdle(true)
        let id = try XCTUnwrap(sent.last?["id"] as? String)
        voice.handleEvent(["type": "ack", "command": "set_model_unload_when_idle", "id": id, "outcome": "reject"])
        XCTAssertNotNil(voice.recognizerSnapshot, "a bare ack must not erase the picker")
        XCTAssertEqual(voice.recognizerPickerState.explanation, "Couldn't change Unload when idle.")
        XCTAssertEqual(sent.last?["cmd"] as? String, "get_recognizer_status")
    }

    // MARK: Row 3: Sleeping on the selected engine loads when you dictate

    func testSleepingSelectedEngineSaysItLoadsWhenYouDictate() throws {
        let sleeping = try Self.state(Self.payload(parakeet: "sleeping", unloadWhenIdle: false))
        XCTAssertTrue(sleeping.showsSleepingHint(for: .parakeet))
        XCTAssertEqual(sleeping.statusText(for: .parakeet), "Sleeping (loads when you dictate)")
        XCTAssertTrue(RecognizerPickerView.subtitle(sleeping, .parakeet).hasPrefix("On disk (loads when you dictate) · "))
        // The other engine is also Sleeping, but dictating would not load it.
        XCTAssertFalse(sleeping.showsSleepingHint(for: .whisper))
        XCTAssertEqual(RecognizerPickerView.subtitle(sleeping, .whisper), "On disk", "no size reported for Whisper in this fixture")
        XCTAssertEqual(sleeping.statusText(for: .whisper), "Sleeping")
        // After a dictation it reads Ready, with no leftover hint.
        let ready = try Self.state(Self.payload(2, parakeet: "ready", unloadWhenIdle: false))
        XCTAssertFalse(ready.showsSleepingHint(for: .parakeet))
        XCTAssertTrue(RecognizerPickerView.subtitle(ready, .parakeet).hasPrefix("Loaded · "))
    }

    func testNoHintWhenTheSelectedEngineCannotLoad() {
        let notSetUp = RecognizerPickerState(selected: .parakeet, effective: nil, parakeet: .unloaded, whisper: .loaded,
                                             parakeetAvailable: nil, parakeetAssetsPresent: false)
        XCTAssertFalse(notSetUp.showsSleepingHint(for: .parakeet))
        XCTAssertEqual(notSetUp.statusText(for: .parakeet), "Not set up")
        let unavailable = RecognizerPickerState(selected: .parakeet, effective: nil, parakeet: .unloaded, whisper: .loaded,
                                                parakeetAvailable: false, parakeetAssetsPresent: true)
        XCTAssertFalse(unavailable.showsSleepingHint(for: .parakeet))
    }
}
