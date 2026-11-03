import XCTest
@testable import VoiceBarUI

/// Lane K-ui (2.2.61, lead rulings 00:17Z + 00:32Z): the recognizer notice names the engine that really wrote the text,
/// the keep-warm "Unload when idle" switch, and the "loads when you dictate" hint on a Sleeping selected engine.
@MainActor
final class RecognizerKUICopyTests: XCTestCase {
    /// The exact backend chain from the live recording that prompted row 1.
    static let liveBackend = "parakeet-resident+fallback-uncovered-tail->whisper.cpp+qualified-fallback"

    private static func payload(_ revision: Int = 1, desired: String = "parakeet", effective: String? = "parakeet",
                                parakeet: String = "ready", whisper: String = "sleeping", fallback: String? = nil,
                                unloadWhenIdle: [String: Any]? = nil, lastBackend: String? = nil,
                                parakeetBytes: Int = 2_509_000_000) -> [String: Any] {
        var event = RecognizerBindingTests.event(revision, desired: desired, effective: effective,
                                                 parakeet: parakeet, whisper: whisper, fallback: fallback)
        var p = event["recognizer_status"] as! [String: Any]
        var engines = p["engines"] as! [String: Any]
        var pk = engines["parakeet"] as! [String: Any]; pk["disk_bytes"] = parakeetBytes; engines["parakeet"] = pk
        p["engines"] = engines
        if let unloadWhenIdle { p["unload_when_idle"] = unloadWhenIdle }
        if let lastBackend { p["last_backend"] = lastBackend }
        event["recognizer_status"] = p
        return event
    }
    private static func state(_ event: [String: Any]) throws -> RecognizerPickerState {
        RecognizerPickerState(snapshot: try XCTUnwrap(RecognizerStatusSnapshot(payload: event["recognizer_status"] as! [String: Any])))
    }
    private static let off: [String: Any] = ["effective": false, "source": "default", "raw": NSNull()]

    // MARK: Row 1: the notice says what really happened

    func testLiveBackendNamesWhisperAsTheWriterAndNeverSaysParakeetCouldNotTranscribe() throws {
        let p = try XCTUnwrap(RecognizerProvenance(backend: Self.liveBackend))
        XCTAssertEqual(p.firstEngine, .parakeet)
        XCTAssertEqual(p.writer, .whisper, "the engine after the last -> wrote the text")
        XCTAssertEqual(p.fallbackReason, "uncovered-tail")
        XCTAssertNil(p.endingRecheckedBy, "today's uncovered-tail path re-transcribes the whole recording")
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

    func testTailRecheckNamesBothEnginesAndKeepsTheTranscriberAsWriter() throws {
        let p = try XCTUnwrap(RecognizerProvenance(backend: "parakeet-resident+tail-recheck-whisper"))
        XCTAssertEqual(p.writer, .parakeet)
        XCTAssertEqual(p.endingRecheckedBy, .whisper)
        XCTAssertEqual(p.notice, "Parakeet transcribed; Whisper re-checked the ending.")
        XCTAssertEqual(RecognizerProvenance(backend: "parakeet-resident+tail-verified")?.notice,
                       "Parakeet transcribed; Whisper re-checked the ending.", "an unnamed checker is the other engine")
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
        XCTAssertEqual(facts.map(\.title), ["Engine", "How it was transcribed"])
        XCTAssertEqual(facts.map(\.value), ["Whisper", "Whisper transcribed this recording: Parakeet's text stopped before the ending."])
        XCTAssertEqual(SettingsHistoryDiagnosticsCopy.engineFacts("parakeet-resident").map(\.title), ["Engine"])
        XCTAssertEqual(SettingsHistoryDiagnosticsCopy.engineFacts("fake-stt"), [])
    }

    func testPickerNoticeFromTheSnapshotReasonNamesWhisperAndDoesNotBlameParakeetForWhisperAlone() throws {
        let tail = try Self.state(Self.payload(effective: "whisper", parakeet: "sleeping", whisper: "ready", fallback: "uncovered-tail"))
        XCTAssertEqual(tail.explanation, "Whisper transcribed your last recording: Parakeet's text stopped before the ending.")
        XCTAssertTrue(tail.explanationIsWarning)
        // Whisper selected, server -> CLI fallback: Parakeet was never involved (the old copy blamed it).
        let whisperOnly = try Self.state(Self.payload(desired: "whisper", effective: "whisper", parakeet: "sleeping",
                                                      whisper: "ready", fallback: "timeout"))
        XCTAssertNil(whisperOnly.explanation)
        // The exact backend chain, when reported, wins over the reason code.
        let exact = try Self.state(Self.payload(effective: "whisper", parakeet: "sleeping", whisper: "ready",
                                                fallback: "uncovered-tail", lastBackend: Self.liveBackend))
        XCTAssertEqual(exact.explanation, tail.explanation)
        let rechecked = try Self.state(Self.payload(lastBackend: "parakeet-resident+tail-recheck-whisper"))
        XCTAssertEqual(rechecked.explanation, "Parakeet transcribed; Whisper re-checked the ending.")
        XCTAssertFalse(rechecked.explanationIsWarning, "a re-checked ending is normal operation")
    }

    // MARK: Row 2: Unload when idle, OFF by default

    func testSwitchRowIsAbsentUntilTheDaemonReportsIt() throws {
        let s = try Self.state(Self.payload())
        XCTAssertNil(s.unloadWhenIdle)
        XCTAssertNil(ModelsSettingsView.unloadWhenIdleRow(for: s))
    }

    func testSwitchRowDefaultsOffAndShowsTheModelSize() throws {
        let s = try Self.state(Self.payload(unloadWhenIdle: Self.off))
        let row = try XCTUnwrap(ModelsSettingsView.unloadWhenIdleRow(for: s))
        XCTAssertFalse(row.isOn, "Etan ruling: Parakeet stays resident; the switch is off by default")
        XCTAssertNil(row.lockedReason)
        XCTAssertFalse(row.disabled)
        XCTAssertEqual(row.title, "Unload when idle (saves ~2.5 GB)")
        XCTAssertEqual(row.captionLines, ["Off keeps Parakeet loaded so dictation starts right away. On frees its memory after 10 min idle."])
        XCTAssertEqual(ModelsSettingsView.approximateSize(3_100_000_000), "3 GB")
        XCTAssertEqual(ModelsSettingsView.approximateSize(640_000_000), "640 MB")
        XCTAssertNil(ModelsSettingsView.approximateSize(0))
        let sizeless = try Self.state(Self.payload(unloadWhenIdle: Self.off, parakeetBytes: 0))
        XCTAssertEqual(ModelsSettingsView.unloadWhenIdleRow(for: sizeless)?.title, "Unload when idle")
        XCTAssertEqual(ModelsSettingsView.unloadWhenIdleRow(for: s, canChange: false)?.disabled, true)
    }

    func testSwitchRowIsLockedWithSetByVarWhenTheEnvironmentDecides() throws {
        let env: [String: Any] = ["effective": true, "source": "environment", "raw": "1", "env_var": "VOICELAYER_PARAKEET_KEEP_WARM"]
        let row = try XCTUnwrap(ModelsSettingsView.unloadWhenIdleRow(for: Self.state(Self.payload(unloadWhenIdle: env))))
        XCTAssertTrue(row.isOn)
        XCTAssertTrue(row.disabled)
        XCTAssertEqual(row.lockedReason, "Set by VOICELAYER_PARAKEET_KEEP_WARM")
        XCTAssertEqual(row.captionLines.count, 2, "the explanation stays; the lock adds its reason below")
        var unnamed = env; unnamed["env_var"] = nil
        XCTAssertEqual(ModelsSettingsView.unloadWhenIdleRow(for: try Self.state(Self.payload(unloadWhenIdle: unnamed)))?.lockedReason,
                       "Set by \(RecognizerUnloadWhenIdle.defaultEnvironmentVariable)")
        // Malformed shapes are ignored, never shown as a switch that might lie.
        for bad: [String: Any] in [["effective": true, "source": "environment", "raw": NSNull()],
                                   ["effective": 1, "source": "default", "raw": NSNull()],
                                   ["effective": false, "source": "default", "raw": "0"],
                                   ["effective": false, "source": "future", "raw": NSNull()]] {
            XCTAssertNil(try Self.state(Self.payload(unloadWhenIdle: bad)).unloadWhenIdle, "\(bad)")
        }
    }

    func testSelectedLineFollowsTheSwitch() throws {
        XCTAssertEqual(try Self.state(Self.payload(unloadWhenIdle: Self.off)).autoLoadLine(for: .parakeet), "Stays loaded between dictations.")
        let on: [String: Any] = ["effective": true, "source": "settings", "raw": NSNull()]
        XCTAssertEqual(try Self.state(Self.payload(unloadWhenIdle: on)).autoLoadLine(for: .parakeet), "Unloads after 10 min idle to free memory.")
        XCTAssertNil(try Self.state(Self.payload(parakeet: "sleeping", unloadWhenIdle: Self.off)).autoLoadLine(for: .parakeet),
                     "Sleeping already says it loads when you dictate")
        XCTAssertEqual(try Self.state(Self.payload()).autoLoadLine(for: .parakeet),
                       "Loads automatically when selected; unloads after 10 min idle.", "older daemons keep the old line")
    }

    func testVoiceStateSendsTheSwitchAndSettlesOnTheAck() throws {
        let voice = RecognizerBindingTests.voice(); var sent: [[String: Any]] = []; voice.sendCommand = { sent.append($0) }
        voice.setConnectionStatus(true)
        voice.handleEvent(Self.payload(1, unloadWhenIdle: Self.off)); sent.removeAll()
        voice.setRecognizerUnloadWhenIdle(false)
        XCTAssertTrue(sent.isEmpty, "already off")
        voice.setRecognizerUnloadWhenIdle(true)
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent.last?["cmd"] as? String, RecognizerUnloadWhenIdle.command)
        XCTAssertEqual(sent.last?["value"] as? Bool, true)
        let id = try XCTUnwrap(sent.last?["id"] as? String)
        XCTAssertEqual(voice.recognizerPickerState.unloadWhenIdlePending, true)
        XCTAssertEqual(ModelsSettingsView.unloadWhenIdleRow(for: voice.recognizerPickerState)?.isOn, true, "shows the choice while pending")
        XCTAssertEqual(ModelsSettingsView.unloadWhenIdleRow(for: voice.recognizerPickerState)?.disabled, true)
        voice.setRecognizerUnloadWhenIdle(false)
        XCTAssertEqual(sent.count, 1, "one write at a time")
        var ack = Self.payload(1, unloadWhenIdle: ["effective": true, "source": "settings", "raw": NSNull()])
        ack["type"] = "ack"; ack["command"] = RecognizerUnloadWhenIdle.command; ack["id"] = id; ack["outcome"] = "accept"
        voice.handleEvent(ack)
        XCTAssertNil(voice.recognizerPickerState.unloadWhenIdlePending)
        XCTAssertEqual(voice.recognizerPickerState.unloadWhenIdle?.effective, true, "an equal-revision ack still carries the new value")
        XCTAssertNotNil(voice.recognizerSnapshot)
    }

    func testAckWithoutASnapshotKeepsThePickerAndReadsTheDaemon() throws {
        let voice = RecognizerBindingTests.voice(); var sent: [[String: Any]] = []; voice.sendCommand = { sent.append($0) }
        voice.setConnectionStatus(true)
        voice.handleEvent(Self.payload(1, unloadWhenIdle: Self.off)); sent.removeAll()
        voice.setRecognizerUnloadWhenIdle(true)
        let id = try XCTUnwrap(sent.last?["id"] as? String)
        voice.handleEvent(["type": "ack", "command": RecognizerUnloadWhenIdle.command, "id": id, "outcome": "reject"])
        XCTAssertNotNil(voice.recognizerSnapshot, "a bare ack must not erase the picker")
        XCTAssertEqual(voice.recognizerPickerState.explanation, "Couldn't change Unload when idle.")
        XCTAssertNil(voice.recognizerPickerState.unloadWhenIdlePending)
        XCTAssertEqual(sent.last?["cmd"] as? String, "get_recognizer_status")
    }

    func testLockedSwitchSendsNothing() throws {
        let voice = RecognizerBindingTests.voice(); var sent: [[String: Any]] = []; voice.sendCommand = { sent.append($0) }
        voice.setConnectionStatus(true)
        voice.handleEvent(Self.payload(1, unloadWhenIdle: ["effective": false, "source": "environment", "raw": "0"])); sent.removeAll()
        voice.setRecognizerUnloadWhenIdle(true)
        XCTAssertTrue(sent.isEmpty)
    }

    // MARK: Row 3: Sleeping on the selected engine loads when you dictate

    func testSleepingSelectedEngineSaysItLoadsWhenYouDictate() throws {
        let sleeping = try Self.state(Self.payload(parakeet: "sleeping", unloadWhenIdle: Self.off))
        XCTAssertTrue(sleeping.showsSleepingHint(for: .parakeet))
        XCTAssertEqual(sleeping.statusText(for: .parakeet), "Sleeping (loads when you dictate)")
        XCTAssertTrue(RecognizerPickerView.subtitle(sleeping, .parakeet).hasPrefix("Sleeping (loads when you dictate) · "))
        // The other engine is also Sleeping, but dictating would not load it.
        XCTAssertFalse(sleeping.showsSleepingHint(for: .whisper))
        XCTAssertEqual(RecognizerPickerView.subtitle(sleeping, .whisper), "Sleeping", "no size reported for Whisper in this fixture")
        XCTAssertEqual(sleeping.statusText(for: .whisper), "Sleeping")
        // After a dictation it reads Ready, with no leftover hint.
        let ready = try Self.state(Self.payload(2, parakeet: "ready", unloadWhenIdle: Self.off))
        XCTAssertFalse(ready.showsSleepingHint(for: .parakeet))
        XCTAssertTrue(RecognizerPickerView.subtitle(ready, .parakeet).hasPrefix("Ready · "))
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
