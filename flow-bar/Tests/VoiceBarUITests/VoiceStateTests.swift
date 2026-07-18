@testable import VoiceBarUI
import XCTest

final class VoiceStateTests: XCTestCase {
    func testDefaultPlaybackClockUsesMonotonicSystemUptime() {
        let state = VoiceState()
        let envelope = PlaybackAmplitudeEnvelope(
            source: .decodedRMS,
            sampleIntervalMilliseconds: 60000,
            samples: [0.8]
        )

        state.handleEvent(
            ["type": "state", "state": "speaking", "text": "hello"],
            playbackAmplitude: envelope
        )

        XCTAssertEqual(
            state.playbackAudioLevel(
                atSystemUptime: ProcessInfo.processInfo.systemUptime
            ),
            0.8
        )
    }

    func testSpeakingIndexesTypedPlaybackAmplitudeFromReceiptClock() {
        var now = 10.0
        let state = VoiceState(playbackAmplitudeClock: { now })
        let envelope = PlaybackAmplitudeEnvelope(
            source: .decodedRMS,
            sampleIntervalMilliseconds: 50,
            samples: [0.1, 0.5, 0.9]
        )

        state.handleEvent([
            "type": "state",
            "state": "speaking",
            "text": "Truth",
        ], playbackAmplitude: envelope)

        XCTAssertEqual(state.playbackAudioLevel(), 0.1, accuracy: 0.0001)
        now = 10.075
        XCTAssertEqual(state.playbackAudioLevel(), 0.7, accuracy: 0.0001)
    }

    func testSpeakingPresentsTheSameIndependentTimeOffsetShapeAsF5() {
        var now = 10.0
        let state = VoiceState(playbackAmplitudeClock: { now })
        let envelope = PlaybackAmplitudeEnvelope(
            source: .decodedRMS,
            sampleIntervalMilliseconds: 50,
            samples: [0.1, 0.7, 0.2, 0.9, 0.3, 0.8, 0.4, 0.6]
        )
        state.handleEvent(
            ["type": "state", "state": "speaking", "text": "Truth"],
            playbackAmplitude: envelope
        )

        now = 10.350

        XCTAssertEqual(
            state.playbackWaveformLevels(),
            [0.7, 0.2, 0.9, 0.3, 0.8, 0.4, 0.6]
        )
    }

    func testPlaybackIdleClearsPlaybackAmplitudeTruth() {
        var now = 10.0
        let state = VoiceState(playbackAmplitudeClock: { now })
        let envelope = PlaybackAmplitudeEnvelope(
            source: .decodedRMS,
            sampleIntervalMilliseconds: 50,
            samples: [0.8]
        )
        state.handleEvent([
            "type": "state",
            "state": "speaking",
            "text": "Truth",
        ], playbackAmplitude: envelope)
        now = 10.01
        XCTAssertEqual(state.playbackAudioLevel(), 0.8, accuracy: 0.0001)

        state.handleEvent([
            "type": "state",
            "state": "idle",
            "source": "playback",
        ])

        XCTAssertNil(state.playbackAmplitudeEnvelope)
        XCTAssertEqual(state.playbackAudioLevel(), 0)
    }

    func testPlaybackErrorClearsPlaybackAmplitudeTruth() {
        let state = VoiceState(playbackAmplitudeClock: { 10 })
        state.handleEvent([
            "type": "state",
            "state": "speaking",
            "text": "Truth",
        ], playbackAmplitude: PlaybackAmplitudeEnvelope(
            source: .decodedRMS,
            sampleIntervalMilliseconds: 50,
            samples: [0.8]
        ))
        XCTAssertNotNil(state.playbackAmplitudeEnvelope)

        state.handleEvent([
            "type": "error",
            "message": "player failed",
            "recoverable": true,
        ])

        XCTAssertNil(state.playbackAmplitudeEnvelope)
        XCTAssertEqual(state.playbackAudioLevel(), 0)
    }

    func testPolishDegradationPersistsAndSignalsMenuOnlyOnce() throws {
        let state = VoiceState()

        state.handleEvent([
            "type": "polish_degraded",
            "reason": "missing-binary",
            "hint": "Install mlx-lm",
        ])
        state.handleEvent([
            "type": "polish_degraded",
            "reason": "missing-binary",
            "hint": "Install mlx-lm",
        ])

        let degradation = try XCTUnwrap(state.polishDegradation)
        XCTAssertEqual(degradation.reason, "missing-binary")
        XCTAssertEqual(degradation.hint, "Install mlx-lm")
        XCTAssertTrue(state.polishMenuSignalPending)

        state.acknowledgePolishMenuSignal()

        XCTAssertFalse(state.polishMenuSignalPending)
        XCTAssertNotNil(state.polishDegradation)
    }

    func testDismissedPolishDegradationStaysDismissedWhenStatusReplays() {
        let state = VoiceState()
        let event: [String: Any] = [
            "type": "polish_degraded",
            "reason": "missing-binary",
            "hint": "Install mlx-lm",
        ]

        state.handleEvent(event)
        state.dismissPolishDegradation()
        state.handleEvent(event)

        XCTAssertNil(state.polishDegradation)
        XCTAssertFalse(state.polishMenuSignalPending)
    }

    func testPolishReadyClearsDegradationAndAllowsFutureSignal() {
        let state = VoiceState()
        let degraded: [String: Any] = [
            "type": "polish_degraded",
            "reason": "missing-binary",
            "hint": "Install mlx-lm",
        ]

        state.handleEvent(degraded)
        state.handleEvent(["type": "polish_ready"])

        XCTAssertNil(state.polishDegradation)
        XCTAssertFalse(state.polishMenuSignalPending)

        state.handleEvent(degraded)
        XCTAssertNotNil(state.polishDegradation)
        XCTAssertTrue(state.polishMenuSignalPending)
    }

    func testFinalTranscriptionRetainsUnpolishedHonestyMetadata() {
        let state = VoiceState(recentTranscriptionsLoader: { [] })
        state.minimumTranscribingDisplayDuration = 0

        state.handleEvent([
            "type": "transcription",
            "text": "Raw fallback text.",
            "polished": false,
            "polish_reason": "connection refused",
        ])

        XCTAssertEqual(state.lastTranscriptionPolished, false)
        XCTAssertEqual(state.lastTranscriptionPolishReason, "connection refused")
    }

    func testRecordIntentDoesNotTransitionLocally() {
        let state = VoiceState()
        var sentCommand: [String: Any]?

        state.sendCommand = { command in
            sentCommand = command
        }

        state.record()

        XCTAssertEqual(state.mode, .idle)
        XCTAssertEqual(sentCommand?["cmd"] as? String, "record")
        XCTAssertNotNil(sentCommand?["id"] as? String)
        XCTAssertEqual(state.pendingIntent?.command, .record)
        XCTAssertEqual(state.pendingIntent?.id, sentCommand?["id"] as? String)
    }

    func testPressToTalkRecordShowsRecordingImmediately() {
        let state = VoiceState()
        state.setConnectionStatus(true)
        var sentCommand: [String: Any]?
        var modes: [VoiceMode] = []

        state.sendCommand = { command in
            sentCommand = command
        }
        state.onModeChange = { mode in
            modes.append(mode)
        }

        state.record(pressToTalk: true)

        XCTAssertEqual(state.mode, .recording)
        XCTAssertEqual(modes, [.recording])
        XCTAssertEqual(sentCommand?["cmd"] as? String, "record")
        XCTAssertEqual(sentCommand?["press_to_talk"] as? Bool, true)
    }

    func testBarRecordingUsesLongSafetyTimeout() {
        let state = VoiceState()
        var sentCommand: [String: Any]?

        state.sendCommand = { command in
            sentCommand = command
        }

        state.record(pressToTalk: true)

        XCTAssertEqual(sentCommand?["timeout_seconds"] as? Int, 3600)
    }

    func testVoiceAskUsesTheF5LocalMeterEvenWhenTheSocketMeterIsInflated() throws {
        let state = VoiceState()
        state.setConnectionStatus(true)
        state.sendCommand = { _ in }

        state.record(pressToTalk: true)
        state.handleEvent([
            "type": "audio_level",
            "rms": 0.42,
        ])
        state.setLocalRecordingLevel(0)

        XCTAssertEqual(try XCTUnwrap(state.audioLevel), 0, accuracy: 0.0001)
        XCTAssertEqual(state.recordingWaveformLevel, 0, accuracy: 0.0001)
    }

    func testRecordingAudioLevelKeepsLocalMeterWhenItIsStrongerThanSocket() throws {
        let state = VoiceState()
        state.setConnectionStatus(true)
        state.sendCommand = { _ in }

        state.record(pressToTalk: true)
        state.handleEvent([
            "type": "audio_level",
            "rms": 0.25,
        ])
        state.setLocalRecordingLevel(0.63)

        XCTAssertEqual(try XCTUnwrap(state.audioLevel), 0.63, accuracy: 0.0001)
    }

    func testVoiceAskSocketOnlyRoomToneUsesTheAcceptedF5SilenceFloor() {
        let state = VoiceState()
        state.handleEvent([
            "type": "state",
            "state": "recording",
        ])
        state.handleEvent([
            "type": "audio_level",
            "rms": 0.42,
        ])
        state.setLocalRecordingLevel(AudioLevelMonitor.normalizeAveragePower(-50))

        XCTAssertEqual(state.recordingWaveformLevel, 0, accuracy: 0.0001)
    }

    func testVoiceAskSocketOnlySpeechPreservesRangeAboveTheAcceptedF5SilenceFloor() {
        let state = VoiceState()
        state.handleEvent([
            "type": "state",
            "state": "recording",
        ])

        state.handleEvent(["type": "audio_level", "rms": 0.7])
        let quietSpeech = state.recordingWaveformLevel
        state.handleEvent(["type": "audio_level", "rms": 0.95])
        let loudSpeech = state.recordingWaveformLevel

        XCTAssertEqual(
            quietSpeech,
            WaveformMetrics.recordingLevel(from: 0.7),
            accuracy: 0.0001
        )
        XCTAssertGreaterThan(quietSpeech, 0)
        XCTAssertGreaterThan(loudSpeech, quietSpeech)
    }

    func testRecordingWaveformUsesAdaptedLocalMeterWhenItIsStronger() {
        let state = VoiceState()
        state.handleEvent([
            "type": "state",
            "state": "recording",
        ])
        state.handleEvent([
            "type": "audio_level",
            "rms": 0.25,
        ])
        let loudLocalLevel = AudioLevelMonitor.normalizeAveragePower(-20)
        state.setLocalRecordingLevel(loudLocalLevel)

        XCTAssertEqual(
            state.recordingWaveformLevel,
            WaveformMetrics.recordingLevel(from: loudLocalLevel),
            accuracy: 0.0001
        )
    }

    func testRecordingWaveformUsesARealTimeOffsetSampleWindow() {
        var now = 40.0
        let state = VoiceState(playbackAmplitudeClock: { now })
        state.handleEvent(["type": "state", "state": "recording"])
        let rawLevels = [0.70, 0.85, 0.75, 0.95, 0.80, 0.90, 0.72]

        for rawLevel in rawLevels {
            state.handleEvent(["type": "audio_level", "rms": rawLevel])
            now += 0.05
        }

        XCTAssertEqual(
            state.recordingWaveformLevels,
            rawLevels.map { WaveformMetrics.recordingLevel(from: $0) }
        )
    }

    func testRepeatedRecordingStateDoesNotClearTheLiveLevelOrInjectASilentSample() {
        var now = 50.0
        let state = VoiceState(playbackAmplitudeClock: { now })
        state.handleEvent(["type": "state", "state": "recording"])
        state.setLocalRecordingLevel(0.9)
        let beforeRefresh = state.recordingWaveformLevels

        now += 0.05
        state.handleEvent(["type": "state", "state": "recording"])

        XCTAssertEqual(state.recordingWaveformLevels, beforeRefresh)
        XCTAssertEqual(
            state.recordingWaveformLevel,
            WaveformMetrics.recordingLevel(from: 0.9),
            accuracy: 0.0001
        )
    }

    func testTranscribingReplaysTheActualRecordedEnvelopeFromTheLastLiveWindow() throws {
        var now = 10.0
        let state = VoiceState(playbackAmplitudeClock: { now })
        state.handleEvent(["type": "state", "state": "recording"])
        let rawLevels = [0.70, 0.82, 0.74, 0.93, 0.78, 0.88, 0.76, 0.97]
        for rawLevel in rawLevels {
            state.handleEvent(["type": "audio_level", "rms": rawLevel])
            now += 0.05
        }
        let realLevels = rawLevels.map { WaveformMetrics.recordingLevel(from: $0) }

        state.handleEvent(["type": "state", "state": "transcribing"])

        XCTAssertEqual(
            try XCTUnwrap(state.transcribingWaveformLevels(atSystemUptime: now)),
            Array(realLevels.suffix(7))
        )
        now += 0.05
        XCTAssertEqual(
            try XCTUnwrap(state.transcribingWaveformLevels(atSystemUptime: now)),
            [realLevels[2], realLevels[3], realLevels[4], realLevels[5], realLevels[6], realLevels[7], realLevels[0]]
        )
    }

    func testTranscribingReplayKeepsMovingAtTheRecordedFiftyMillisecondCadence() throws {
        var now = 20.0
        let state = VoiceState(playbackAmplitudeClock: { now })
        state.handleEvent(["type": "state", "state": "recording"])
        for rawLevel in [0.70, 0.82, 0.74, 0.93, 0.78, 0.88, 0.76, 0.97] {
            state.handleEvent(["type": "audio_level", "rms": rawLevel])
            now += 0.05
        }

        state.handleEvent(["type": "state", "state": "transcribing"])
        let initial = try XCTUnwrap(state.transcribingWaveformLevels(atSystemUptime: now))
        now += 0.049
        XCTAssertEqual(
            try XCTUnwrap(state.transcribingWaveformLevels(atSystemUptime: now)),
            initial
        )
        now += 0.001
        XCTAssertNotEqual(
            try XCTUnwrap(state.transcribingWaveformLevels(atSystemUptime: now)),
            initial
        )
    }

    func testTranscribingWithoutARecordingDoesNotReuseAnOlderWaveform() {
        var now = 30.0
        let state = VoiceState(playbackAmplitudeClock: { now })
        state.handleEvent(["type": "state", "state": "recording"])
        state.handleEvent(["type": "audio_level", "rms": 0.50])
        state.handleEvent(["type": "state", "state": "transcribing"])
        XCTAssertNotNil(state.transcribingWaveformLevels(atSystemUptime: now))

        state.handleEvent(["type": "state", "state": "idle"])
        now = 31
        state.handleEvent(["type": "state", "state": "transcribing"])

        XCTAssertNil(state.transcribingWaveformLevels(atSystemUptime: now))
    }

    func testPressToTalkRecordAndFirstAudioDiagnosticsCarryTimingDeltas() throws {
        let state = VoiceState()
        state.setConnectionStatus(true)
        var clockValues = [10.0, 10.125, 10.2]
        state.recordingTimingClock = {
            clockValues.removeFirst()
        }
        var diagnostics: [(event: String, details: [String: String])] = []
        state.diagnosticLogger = { event, details in
            diagnostics.append((event, details))
        }
        state.sendCommand = { _ in }

        state.record(pressToTalk: true)
        state.handleEvent([
            "type": "state",
            "state": "recording",
            "mode": "ptt",
        ])
        state.handleEvent([
            "type": "audio_level",
            "rms": 0.3,
        ])
        state.handleEvent([
            "type": "audio_level",
            "rms": 0.4,
        ])

        let recordStart = try XCTUnwrap(diagnostics.first { $0.event == "record_start" })
        XCTAssertEqual(recordStart.details["recordCommandUptimeMs"], "10000")
        XCTAssertEqual(recordStart.details["pressToTalk"], "true")

        let firstAudioDiagnostics = diagnostics.filter { $0.event == "recording_first_audio_level" }
        XCTAssertEqual(firstAudioDiagnostics.count, 1)
        let firstAudio = try XCTUnwrap(firstAudioDiagnostics.first)
        XCTAssertEqual(firstAudio.details["firstAudioLevelUptimeMs"], "10200")
        XCTAssertEqual(firstAudio.details["msSinceRecordCommand"], "200")
        XCTAssertEqual(firstAudio.details["msSinceRecordingState"], "75")
        XCTAssertEqual(firstAudio.details["socketRms"], "0.3000")
    }

    func testRepeatedRecordingStateDoesNotResetFirstAudioTimingBaseline() throws {
        let state = VoiceState()
        state.setConnectionStatus(true)
        var clockValues = [10.0, 10.125, 10.5, 10.7]
        state.recordingTimingClock = {
            clockValues.removeFirst()
        }
        var diagnostics: [(event: String, details: [String: String])] = []
        state.diagnosticLogger = { event, details in
            diagnostics.append((event, details))
        }
        state.sendCommand = { _ in }

        state.record(pressToTalk: true)
        state.handleEvent([
            "type": "state",
            "state": "recording",
            "mode": "ptt",
        ])
        state.handleEvent([
            "type": "state",
            "state": "recording",
            "mode": "ptt",
        ])
        state.handleEvent([
            "type": "audio_level",
            "rms": 0.3,
        ])

        let firstAudio = try XCTUnwrap(
            diagnostics.first { $0.event == "recording_first_audio_level" }
        )
        XCTAssertEqual(firstAudio.details["firstAudioLevelUptimeMs"], "10500")
        XCTAssertEqual(firstAudio.details["msSinceRecordCommand"], "500")
        XCTAssertEqual(firstAudio.details["msSinceRecordingState"], "375")
    }

    func testRetranscribeLastCaptureSendsRecoverCommand() {
        let state = VoiceState()
        var sentCommand: [String: Any]?

        state.sendCommand = { command in
            sentCommand = command
        }

        state.retranscribeLastCapture()

        XCTAssertEqual(sentCommand?["cmd"] as? String, "retranscribe_last")
        XCTAssertNotNil(sentCommand?["id"] as? String)
        XCTAssertEqual(state.pendingIntent?.command, .retranscribeLast)
        XCTAssertEqual(state.pendingIntent?.id, sentCommand?["id"] as? String)
    }

    func testRecoveredLastCapturePastesFinalTranscription() throws {
        let state = VoiceState(recentTranscriptionsLoader: { [] })
        state.minimumTranscribingDisplayDuration = 0
        var sentCommand: [String: Any]?
        var pastedTexts: [String] = []
        state.sendCommand = { command in
            sentCommand = command
        }
        state.pasteHandler = { text in
            pastedTexts.append(text)
            return true
        }

        state.retranscribeLastCapture()
        let id = try XCTUnwrap(sentCommand?["id"] as? String)
        state.handleEvent([
            "type": "ack",
            "command": "retranscribe_last",
            "outcome": "accept",
            "id": id,
        ])
        state.handleEvent([
            "type": "state",
            "state": "transcribing",
        ])
        state.handleEvent([
            "type": "transcription",
            "text": "recovered cancelled dictation",
        ])

        XCTAssertEqual(pastedTexts, ["recovered cancelled dictation"])
        XCTAssertEqual(state.latestReusableTranscript, "recovered cancelled dictation")
    }

    func testRejectedRecoveredLastCaptureDoesNotPasteLaterTranscription() throws {
        let state = VoiceState(recentTranscriptionsLoader: { [] })
        state.minimumTranscribingDisplayDuration = 0
        var sentCommand: [String: Any]?
        var pastedTexts: [String] = []
        state.sendCommand = { command in
            sentCommand = command
        }
        state.pasteHandler = { text in
            pastedTexts.append(text)
            return true
        }

        state.retranscribeLastCapture()
        let id = try XCTUnwrap(sentCommand?["id"] as? String)
        state.handleEvent([
            "type": "ack",
            "command": "retranscribe_last",
            "outcome": "reject",
            "id": id,
            "reason": "Nothing to transcribe",
        ])
        state.handleEvent([
            "type": "transcription",
            "text": "later unrelated transcript",
        ])

        XCTAssertEqual(pastedTexts, [])
        XCTAssertEqual(state.confirmationText, "Nothing to transcribe")
        XCTAssertEqual(state.latestReusableTranscript, "later unrelated transcript")
    }

    func testRetranscribeLastCaptureDebouncesWhileRecoveryIsPending() {
        let state = VoiceState()
        var sentCommands: [[String: Any]] = []

        state.sendCommand = { command in
            sentCommands.append(command)
        }

        state.retranscribeLastCapture()
        let firstPendingIntent = state.pendingIntent
        state.retranscribeLastCapture()

        XCTAssertEqual(sentCommands.count, 1)
        XCTAssertEqual(firstPendingIntent?.command, .retranscribeLast)
        XCTAssertEqual(state.pendingIntent?.id, firstPendingIntent?.id)
    }

    func testTranscriptionEventStoresArchivedRecordingPathForHistoryEntry() {
        let audioPath = "/Users/etan/.local/share/voicelayer/recordings/2026-06-25/2026-06-25T10-11-12-000Z-abcd1234/audio.wav"
        let state = VoiceState(
            recentTranscriptionsLoader: { [] },
            recentTranscriptionsSaver: { _ in },
            recentTranscriptionEntriesLoader: { [] },
            recentTranscriptionEntriesSaver: { _ in }
        )

        state.handleEvent([
            "type": "transcription",
            "text": "Etan confirmed the correction",
            "recording_path": audioPath,
        ])

        XCTAssertEqual(state.recentTranscriptionEntries.first?.text, "Etan confirmed the correction")
        XCTAssertEqual(state.recentTranscriptionEntries.first?.recordingPath, audioPath)
        XCTAssertEqual(state.recentTranscriptions, ["Etan confirmed the correction"])
    }

    func testTranscriptionEventWithRecordingPathNotifiesHistoryArchiveChange() {
        let audioPath = "/Users/etan/.local/share/voicelayer/recordings/2026-06-25/2026-06-25T10-11-12-000Z-abcd1234/audio.wav"
        let state = VoiceState(
            recentTranscriptionsLoader: { [] },
            recentTranscriptionsSaver: { _ in },
            recentTranscriptionEntriesLoader: { [] },
            recentTranscriptionEntriesSaver: { _ in }
        )
        var historyArchiveChangeCount = 0
        state.onHistoryArchiveChange = {
            historyArchiveChangeCount += 1
        }

        state.handleEvent([
            "type": "transcription",
            "text": "Etan confirmed the correction",
            "recording_path": audioPath,
        ])

        XCTAssertEqual(historyArchiveChangeCount, 1)
    }

    func testHistoryRetranscribeUpdatesOlderEntryInPlaceWithoutReordering() {
        let latestPath = "/Users/etan/.local/share/voicelayer/recordings/2026-06-25/2026-06-25T10-11-12-000Z-latest/audio.wav"
        let olderPath = "/Users/etan/.local/share/voicelayer/recordings/2026-06-25/2026-06-25T10-11-12-000Z-older/audio.wav"
        let state = VoiceState(
            recentTranscriptionsLoader: { [] },
            recentTranscriptionsSaver: { _ in },
            recentTranscriptionEntriesLoader: {
                [
                    RecentTranscriptionEntry(text: "Latest untouched transcript", recordingPath: latestPath),
                    RecentTranscriptionEntry(text: "Ethan old transcript", recordingPath: olderPath),
                ]
            },
            recentTranscriptionEntriesSaver: { _ in }
        )

        state.handleEvent([
            "type": "transcription",
            "text": "Etan corrected older transcript",
            "recording_path": olderPath,
        ])

        XCTAssertEqual(state.recentTranscriptionEntries.map(\.text), [
            "Latest untouched transcript",
            "Etan corrected older transcript",
        ])
        XCTAssertEqual(state.recentTranscriptionEntries.map(\.recordingPath), [
            latestPath,
            olderPath,
        ])
    }

    func testHistoryEntryRetranscribeSendsArchivedAudioPathAndUpdatesEntryWithoutPaste() throws {
        let audioPath = "/Users/etan/.local/share/voicelayer/recordings/2026-06-25/2026-06-25T10-11-12-000Z-abcd1234/audio.wav"
        let state = VoiceState(
            recentTranscriptionsLoader: { [] },
            recentTranscriptionsSaver: { _ in },
            recentTranscriptionEntriesLoader: { [] },
            recentTranscriptionEntriesSaver: { _ in }
        )
        state.minimumTranscribingDisplayDuration = 0
        var sentCommand: [String: Any]?
        var pastedTexts: [String] = []
        state.sendCommand = { command in
            sentCommand = command
        }
        state.pasteHandler = { text in
            pastedTexts.append(text)
            return true
        }
        state.handleEvent([
            "type": "transcription",
            "text": "Ethan confirmed the old transcript",
            "recording_path": audioPath,
        ])

        XCTAssertNil(state.activeHistoryRetranscriptionPath)
        state.retranscribeHistoryEntry(recordingPath: audioPath)

        XCTAssertEqual(sentCommand?["cmd"] as? String, "retranscribe_recording")
        XCTAssertEqual(sentCommand?["audio_path"] as? String, audioPath)
        XCTAssertEqual(state.activeHistoryRetranscriptionPath, audioPath)
        let id = try XCTUnwrap(sentCommand?["id"] as? String)
        XCTAssertNil(state.pendingIntent)
        state.handleEvent([
            "type": "ack",
            "command": "retranscribe_recording",
            "outcome": "accept",
            "id": id,
        ])
        XCTAssertEqual(state.activeHistoryRetranscriptionPath, audioPath)
        state.handleEvent([
            "type": "state",
            "state": "transcribing",
        ])
        state.handleEvent([
            "type": "transcription",
            "text": "Etan confirmed the corrected transcript",
            "recording_path": audioPath,
        ])

        XCTAssertNil(state.activeHistoryRetranscriptionPath)
        XCTAssertEqual(state.recentTranscriptionEntries.map(\.text), [
            "Etan confirmed the corrected transcript",
        ])
        XCTAssertEqual(state.recentTranscriptionEntries.first?.recordingPath, audioPath)
        XCTAssertEqual(state.recentTranscriptions, ["Etan confirmed the corrected transcript"])
        XCTAssertEqual(pastedTexts, [])
    }

    func testHistoryRetranscribeAckStillClearsAfterReplayOverwritesPendingIntent() throws {
        let firstAudioPath = "/Users/etan/.local/share/voicelayer/recordings/2026-06-25/2026-06-25T10-11-12-000Z-first/audio.wav"
        let secondAudioPath = "/Users/etan/.local/share/voicelayer/recordings/2026-06-25/2026-06-25T10-11-12-000Z-second/audio.wav"
        let state = VoiceState(
            recentTranscriptionsLoader: { [] },
            recentTranscriptionsSaver: { _ in },
            recentTranscriptionEntriesLoader: { [] },
            recentTranscriptionEntriesSaver: { _ in }
        )
        var sentCommands: [[String: Any]] = []
        state.sendCommand = { command in
            sentCommands.append(command)
        }

        state.retranscribeHistoryEntry(recordingPath: firstAudioPath)
        let historyID = try XCTUnwrap(sentCommands.first?["id"] as? String)
        state.replay()
        XCTAssertEqual(state.pendingIntent?.command, .replay)

        state.handleEvent([
            "type": "ack",
            "command": "retranscribe_recording",
            "outcome": "reject",
            "id": historyID,
            "reason": "Missing archived recording",
        ])
        state.retranscribeHistoryEntry(recordingPath: secondAudioPath)

        let historyCommands = sentCommands.filter { $0["cmd"] as? String == "retranscribe_recording" }
        XCTAssertEqual(historyCommands.count, 2)
        XCTAssertEqual(historyCommands.last?["audio_path"] as? String, secondAudioPath)
        XCTAssertEqual(state.confirmationText, "Missing archived recording")
    }

    func testDeferredHistoryRetranscribeFinalSurvivesNewRecordingState() async throws {
        let audioPath = "/Users/etan/.local/share/voicelayer/recordings/2026-06-25/2026-06-25T10-11-12-000Z-abcd1234/audio.wav"
        let state = VoiceState(
            recentTranscriptionsLoader: { [] },
            recentTranscriptionsSaver: { _ in },
            recentTranscriptionEntriesLoader: { [] },
            recentTranscriptionEntriesSaver: { _ in }
        )
        state.minimumTranscribingDisplayDuration = 0.05
        var sentCommand: [String: Any]?
        state.sendCommand = { command in
            sentCommand = command
        }
        state.handleEvent([
            "type": "transcription",
            "text": "Ethan confirmed the old transcript",
            "recording_path": audioPath,
        ])

        state.retranscribeHistoryEntry(recordingPath: audioPath)
        let historyID = try XCTUnwrap(sentCommand?["id"] as? String)
        state.handleEvent([
            "type": "ack",
            "command": "retranscribe_recording",
            "outcome": "accept",
            "id": historyID,
        ])
        state.handleEvent([
            "type": "state",
            "state": "transcribing",
        ])
        state.handleEvent([
            "type": "transcription",
            "text": "Etan confirmed the corrected transcript",
            "recording_path": audioPath,
        ])
        state.handleEvent([
            "type": "state",
            "state": "recording",
        ])
        try? await Task.sleep(for: .milliseconds(90))

        XCTAssertEqual(state.recentTranscriptionEntries.map(\.text), [
            "Etan confirmed the corrected transcript",
        ])
        XCTAssertEqual(state.recentTranscriptionEntries.first?.recordingPath, audioPath)
    }

    func testDeferredHistoryRetranscribeFinalSurvivesUserRecordStart() async throws {
        let audioPath = "/Users/etan/.local/share/voicelayer/recordings/2026-06-25/2026-06-25T10-11-12-000Z-abcd1234/audio.wav"
        let state = VoiceState(
            recentTranscriptionsLoader: { [] },
            recentTranscriptionsSaver: { _ in },
            recentTranscriptionEntriesLoader: { [] },
            recentTranscriptionEntriesSaver: { _ in }
        )
        state.minimumTranscribingDisplayDuration = 0.05
        var sentCommand: [String: Any]?
        var pastedTexts: [String] = []
        state.sendCommand = { command in
            sentCommand = command
        }
        state.pasteHandler = { text in
            pastedTexts.append(text)
            return true
        }
        state.handleEvent([
            "type": "transcription",
            "text": "Ethan confirmed the old transcript",
            "recording_path": audioPath,
        ])

        state.retranscribeHistoryEntry(recordingPath: audioPath)
        let historyID = try XCTUnwrap(sentCommand?["id"] as? String)
        state.handleEvent([
            "type": "ack",
            "command": "retranscribe_recording",
            "outcome": "accept",
            "id": historyID,
        ])
        state.handleEvent([
            "type": "state",
            "state": "transcribing",
        ])
        state.handleEvent([
            "type": "transcription",
            "text": "Etan confirmed the corrected transcript",
            "recording_path": audioPath,
        ])
        state.handleEvent([
            "type": "state",
            "state": "idle",
            "source": "recording",
        ])

        state.record()
        try? await Task.sleep(for: .milliseconds(90))

        XCTAssertEqual(state.recentTranscriptionEntries.map(\.text), [
            "Etan confirmed the corrected transcript",
        ])
        XCTAssertEqual(pastedTexts, [])
    }

    func testRecordClearsHistoryRetranscribeIntentLatchAfterRejectedRecordStart() throws {
        let firstAudioPath = "/Users/etan/.local/share/voicelayer/recordings/2026-06-25/2026-06-25T10-11-12-000Z-first/audio.wav"
        let secondAudioPath = "/Users/etan/.local/share/voicelayer/recordings/2026-06-25/2026-06-25T10-11-12-000Z-second/audio.wav"
        let state = VoiceState(
            recentTranscriptionsLoader: { [] },
            recentTranscriptionsSaver: { _ in },
            recentTranscriptionEntriesLoader: { [] },
            recentTranscriptionEntriesSaver: { _ in }
        )
        var sentCommands: [[String: Any]] = []
        state.sendCommand = { command in
            sentCommands.append(command)
        }

        state.retranscribeHistoryEntry(recordingPath: firstAudioPath)
        state.record()
        let recordID = try XCTUnwrap(sentCommands.last?["id"] as? String)
        state.handleEvent([
            "type": "ack",
            "command": "record",
            "outcome": "reject",
            "id": recordID,
            "reason": "busy",
        ])
        state.retranscribeHistoryEntry(recordingPath: secondAudioPath)

        let historyCommands = sentCommands.filter { $0["cmd"] as? String == "retranscribe_recording" }
        XCTAssertEqual(historyCommands.count, 2)
        XCTAssertEqual(historyCommands.last?["audio_path"] as? String, secondAudioPath)
    }

    func testHistoryEntryRetranscribeDebouncesWhilePending() {
        let firstAudioPath = "/Users/etan/.local/share/voicelayer/recordings/2026-06-25/2026-06-25T10-11-12-000Z-first/audio.wav"
        let secondAudioPath = "/Users/etan/.local/share/voicelayer/recordings/2026-06-25/2026-06-25T10-11-12-000Z-second/audio.wav"
        let state = VoiceState(
            recentTranscriptionsLoader: { [] },
            recentTranscriptionsSaver: { _ in },
            recentTranscriptionEntriesLoader: { [] },
            recentTranscriptionEntriesSaver: { _ in }
        )
        var sentCommands: [[String: Any]] = []
        state.sendCommand = { command in
            sentCommands.append(command)
        }

        state.retranscribeHistoryEntry(recordingPath: firstAudioPath)
        state.retranscribeHistoryEntry(recordingPath: secondAudioPath)

        XCTAssertEqual(sentCommands.count, 1)
        XCTAssertEqual(sentCommands.first?["audio_path"] as? String, firstAudioPath)
    }

    func testLateHistoryRetranscribeFinalDoesNotPasteIntoNewBarRecording() throws {
        let audioPath = "/Users/etan/.local/share/voicelayer/recordings/2026-06-25/2026-06-25T10-11-12-000Z-abcd1234/audio.wav"
        let state = VoiceState(
            recentTranscriptionsLoader: { [] },
            recentTranscriptionsSaver: { _ in },
            recentTranscriptionEntriesLoader: { [] },
            recentTranscriptionEntriesSaver: { _ in }
        )
        state.minimumTranscribingDisplayDuration = 0
        var sentCommand: [String: Any]?
        var pastedTexts: [String] = []
        state.sendCommand = { command in
            sentCommand = command
        }
        state.pasteHandler = { text in
            pastedTexts.append(text)
            return true
        }
        state.handleEvent([
            "type": "transcription",
            "text": "Ethan confirmed the old transcript",
            "recording_path": audioPath,
        ])

        state.retranscribeHistoryEntry(recordingPath: audioPath)
        let retryId = try XCTUnwrap(sentCommand?["id"] as? String)
        state.handleEvent([
            "type": "ack",
            "command": "retranscribe_recording",
            "outcome": "accept",
            "id": retryId,
        ])
        state.handleEvent([
            "type": "state",
            "state": "transcribing",
        ])
        state.handleEvent([
            "type": "state",
            "state": "idle",
        ])

        state.record()
        XCTAssertEqual(sentCommand?["cmd"] as? String, "record")
        state.handleEvent([
            "type": "state",
            "state": "recording",
        ])
        state.handleEvent([
            "type": "state",
            "state": "transcribing",
        ])
        state.handleEvent([
            "type": "transcription",
            "text": "Etan confirmed the corrected transcript",
            "recording_path": audioPath,
        ])

        XCTAssertEqual(state.recentTranscriptionEntries.map(\.text), [
            "Etan confirmed the corrected transcript",
        ])
        XCTAssertEqual(pastedTexts, [])
    }

    func testHistoryRetranscribePendingClearsWhenDaemonReturnsIdleWithoutTranscript() throws {
        let audioPath = "/Users/etan/.local/share/voicelayer/recordings/2026-06-25/2026-06-25T10-11-12-000Z-abcd1234/audio.wav"
        let state = VoiceState(
            recentTranscriptionsLoader: { [] },
            recentTranscriptionsSaver: { _ in },
            recentTranscriptionEntriesLoader: { [] },
            recentTranscriptionEntriesSaver: { _ in }
        )
        var sentCommand: [String: Any]?
        state.sendCommand = { command in
            sentCommand = command
        }

        state.retranscribeHistoryEntry(recordingPath: audioPath)
        let retryId = try XCTUnwrap(sentCommand?["id"] as? String)
        state.handleEvent([
            "type": "ack",
            "command": "retranscribe_recording",
            "outcome": "accept",
            "id": retryId,
        ])
        state.handleEvent([
            "type": "state",
            "state": "transcribing",
        ])
        XCTAssertTrue(state.isHistoryRetranscriptionPending)

        state.handleEvent([
            "type": "state",
            "state": "idle",
            "source": "recording",
        ])

        XCTAssertFalse(state.isHistoryRetranscriptionPending)
    }

    func testHistoryRetranscribeUsesExtendedTranscriptionTimeout() async throws {
        let audioPath = "/Users/etan/.local/share/voicelayer/recordings/2026-06-25/2026-06-25T10-11-12-000Z-abcd1234/audio.wav"
        let state = VoiceState(
            recentTranscriptionsLoader: { [] },
            recentTranscriptionsSaver: { _ in },
            recentTranscriptionEntriesLoader: { [] },
            recentTranscriptionEntriesSaver: { _ in }
        )
        state.transcriptionTimeout = .milliseconds(20)
        state.barInitiatedTranscriptionTimeout = .seconds(30)
        var sentCommand: [String: Any]?
        state.sendCommand = { command in
            sentCommand = command
        }

        state.retranscribeHistoryEntry(recordingPath: audioPath)
        let retryId = try XCTUnwrap(sentCommand?["id"] as? String)
        state.handleEvent([
            "type": "ack",
            "command": "retranscribe_recording",
            "outcome": "accept",
            "id": retryId,
        ])
        state.handleEvent([
            "type": "state",
            "state": "transcribing",
        ])
        try? await Task.sleep(for: .milliseconds(60))

        XCTAssertEqual(state.mode, .transcribing)
        XCTAssertTrue(state.isHistoryRetranscriptionPending)
        XCTAssertNil(state.errorMessage)
    }

    func testHistoryRetranscribeValidationErrorSurvivesImmediateRecordingIdle() throws {
        let audioPath = "/Users/etan/.local/share/voicelayer/recordings/2026-06-25/2026-06-25T10-11-12-000Z-missing/audio.wav"
        let state = VoiceState(
            recentTranscriptionsLoader: { [] },
            recentTranscriptionsSaver: { _ in },
            recentTranscriptionEntriesLoader: { [] },
            recentTranscriptionEntriesSaver: { _ in }
        )
        var sentCommand: [String: Any]?
        state.sendCommand = { command in
            sentCommand = command
        }

        state.retranscribeHistoryEntry(recordingPath: audioPath)
        let historyID = try XCTUnwrap(sentCommand?["id"] as? String)
        state.handleEvent([
            "type": "ack",
            "command": "retranscribe_recording",
            "outcome": "accept",
            "id": historyID,
        ])
        state.handleEvent([
            "type": "error",
            "message": "Archived recording audio does not exist",
        ])
        state.handleEvent([
            "type": "state",
            "state": "idle",
            "source": "recording",
        ])

        XCTAssertEqual(state.mode, .error)
        XCTAssertEqual(state.errorMessage, "Archived recording audio does not exist")
    }

    func testRecoveryErrorDoesNotPasteLaterFinalTranscription() {
        let state = VoiceState(recentTranscriptionsLoader: { [] })
        state.minimumTranscribingDisplayDuration = 0
        var pastedTexts: [String] = []
        state.pasteHandler = { text in
            pastedTexts.append(text)
            return true
        }

        state.retranscribeLastCapture()
        state.handleEvent([
            "type": "error",
            "message": "Recovery failed",
        ])
        state.handleEvent([
            "type": "transcription",
            "text": "later unrelated transcript",
        ])

        XCTAssertEqual(pastedTexts, [])
        XCTAssertEqual(state.latestReusableTranscript, "later unrelated transcript")
    }

    func testPendingIntentClearsOnMatchingAck() throws {
        let state = VoiceState()
        var sentCommand: [String: Any]?

        state.sendCommand = { command in
            sentCommand = command
        }

        state.record()
        let id = try XCTUnwrap(sentCommand?["id"] as? String)

        state.handleEvent([
            "type": "ack",
            "command": "record",
            "outcome": "accept",
            "id": id,
        ])

        XCTAssertNil(state.pendingIntent)
        XCTAssertEqual(state.mode, .idle)
    }

    func testCancelIntentExitsRecordingLocallyEvenWithoutDaemonAck() {
        let state = VoiceState()
        state.setConnectionStatus(true)
        state.handleEvent([
            "type": "state",
            "state": "recording",
            "mode": "vad",
        ])

        state.cancel()

        XCTAssertEqual(state.mode, .idle)
    }

    func testStopShowsTranscribingImmediatelyWhileWaitingForDaemon() async {
        let state = VoiceState()
        var modes: [VoiceMode] = []
        state.onModeChange = { modes.append($0) }
        state.handleEvent([
            "type": "state",
            "state": "recording",
            "mode": "vad",
        ])

        state.stop()
        try? await Task.sleep(for: .milliseconds(2200))

        XCTAssertEqual(state.mode, .transcribing)
        XCTAssertEqual(modes, [.recording, .transcribing])
    }

    func testPlaybackStopExitsWithoutRetainingADismissedLiveTeleprompter() {
        let state = VoiceState()
        state.handleEvent([
            "type": "queue",
            "depth": 2,
            "items": [
                [
                    "text": "Current line",
                    "voice": "jenny",
                    "priority": "normal",
                    "is_current": true,
                ],
                [
                    "text": "Queued line",
                    "voice": "jenny",
                    "priority": "normal",
                    "is_current": false,
                ],
            ],
        ])
        state.handleEvent([
            "type": "state",
            "state": "speaking",
            "text": "Etan runs supabase",
        ])

        state.dismissTeleprompter()
        state.stop()

        XCTAssertEqual(state.mode, .idle)
        XCTAssertNil(state.teleprompterText)
        XCTAssertFalse(state.isTeleprompterReadback)
        XCTAssertFalse(state.isTeleprompterDismissed)
        XCTAssertEqual(state.statusText, "")
        XCTAssertEqual(state.queueDepth, 0)
        XCTAssertTrue(state.queueItems.isEmpty)
    }

    func testLiveTeleprompterVisibilityChangesRequestPanelRelayout() async {
        let state = VoiceState()
        state.handleEvent([
            "type": "state",
            "state": "speaking",
            "text": "Live teleprompter changes its panel envelope",
        ])
        try? await Task.sleep(for: .milliseconds(30))
        var relayoutCount = 0
        state.onPanelLayoutChange = {
            relayoutCount += 1
        }

        state.dismissTeleprompter()
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(relayoutCount, 1)

        state.showTeleprompter()
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(relayoutCount, 2)
    }

    func testPlaybackIdleRetainsOriginalTeleprompterAndWordBoundaries() {
        let state = VoiceState()
        state.handleEvent([
            "type": "state",
            "state": "speaking",
            "text": "Original Etan spelling",
        ])
        state.handleEvent([
            "type": "subtitle",
            "words": [
                ["offset_ms": 0, "duration_ms": 120, "text": "Eh tahn"],
                ["offset_ms": 120, "duration_ms": 180, "text": "spelling"],
            ],
        ])

        state.handleEvent([
            "type": "state",
            "state": "idle",
            "source": "playback",
        ])

        XCTAssertEqual(state.mode, .idle)
        XCTAssertEqual(state.teleprompterText, "Original Etan spelling")
        XCTAssertEqual(state.teleprompterWordBoundaries.map(\.text), ["Eh tahn", "spelling"])
        XCTAssertTrue(state.isTeleprompterReadback)
    }

    func testPlaybackIdlePreservesTemporaryTeleprompterVisibility() {
        let state = VoiceState()
        state.handleEvent([
            "type": "state",
            "state": "speaking",
            "text": "Keep this visible",
        ])

        state.dismissTeleprompter()
        state.handleEvent([
            "type": "state",
            "state": "idle",
            "source": "playback",
        ])

        XCTAssertTrue(state.isTeleprompterDismissed)
        state.showTeleprompter()
        XCTAssertFalse(state.isTeleprompterDismissed)
        XCTAssertEqual(state.teleprompterText, "Keep this visible")
    }

    func testExplicitRetainedTeleprompterDismissalClearsSnapshot() {
        let state = VoiceState()
        state.handleEvent([
            "type": "state",
            "state": "speaking",
            "text": "Dismiss this readback",
        ])
        state.handleEvent([
            "type": "state",
            "state": "idle",
            "source": "playback",
        ])

        state.dismissRetainedTeleprompter()

        XCTAssertNil(state.teleprompterText)
        XCTAssertTrue(state.teleprompterWordBoundaries.isEmpty)
        XCTAssertFalse(state.isTeleprompterReadback)
    }

    func testGenericIdleDoesNotOverwriteRetainedTeleprompter() {
        let state = VoiceState()
        state.handleEvent([
            "type": "state",
            "state": "speaking",
            "text": "Retained original script",
        ])
        state.handleEvent([
            "type": "state",
            "state": "idle",
            "source": "playback",
        ])

        state.handleEvent([
            "type": "state",
            "state": "idle",
            "source": "status",
        ])

        XCTAssertEqual(state.teleprompterText, "Retained original script")
        XCTAssertTrue(state.isTeleprompterReadback)
    }

    func testNewRecordingTurnClearsRetainedTeleprompter() {
        let state = VoiceState()
        state.handleEvent([
            "type": "state",
            "state": "speaking",
            "text": "Previous original script",
        ])
        state.handleEvent([
            "type": "state",
            "state": "idle",
            "source": "playback",
        ])

        state.handleEvent([
            "type": "state",
            "state": "recording",
            "mode": "vad",
        ])

        XCTAssertNil(state.teleprompterText)
        XCTAssertFalse(state.isTeleprompterReadback)
    }

    func testNewSpeakingTurnClearsRetainedTeleprompterEvenBeforeFreshTextArrives() {
        let state = VoiceState()
        state.handleEvent([
            "type": "state",
            "state": "speaking",
            "text": "Previous original script",
        ])
        state.handleEvent([
            "type": "state",
            "state": "idle",
            "source": "playback",
        ])
        XCTAssertTrue(state.isTeleprompterReadback)

        state.handleEvent([
            "type": "state",
            "state": "speaking",
            "text": "",
        ])
        state.handleEvent([
            "type": "state",
            "state": "idle",
            "source": "playback",
        ])

        XCTAssertNil(state.teleprompterText)
        XCTAssertFalse(state.isTeleprompterReadback)
        XCTAssertTrue(state.teleprompterWordBoundaries.isEmpty)
    }

    func testVADRecordingHoldOptimisticallyEngagesAndReleases() throws {
        let state = VoiceState()
        var commands: [[String: Any]] = []
        state.sendCommand = { commands.append($0) }
        state.handleEvent([
            "type": "state",
            "state": "recording",
            "mode": "vad",
        ])

        state.setRecordingHold(true)
        XCTAssertTrue(state.isRecordingHoldEngaged)
        XCTAssertEqual(commands.last?["cmd"] as? String, "set_recording_hold")
        XCTAssertEqual(commands.last?["engaged"] as? Bool, true)
        XCTAssertNotNil(commands.last?["id"] as? String)

        let engageID = try XCTUnwrap(commands.last?["id"] as? String)
        state.handleEvent([
            "type": "ack",
            "command": "set_recording_hold",
            "outcome": "accept",
            "id": engageID,
        ])
        state.setRecordingHold(false)

        XCTAssertFalse(state.isRecordingHoldEngaged)
        XCTAssertEqual(commands.last?["engaged"] as? Bool, false)
    }

    func testPTTRecordingCannotEngageRecordingHold() {
        let state = VoiceState()
        var commands: [[String: Any]] = []
        state.sendCommand = { commands.append($0) }
        state.handleEvent([
            "type": "state",
            "state": "recording",
            "mode": "ptt",
        ])

        state.setRecordingHold(true)

        XCTAssertFalse(state.isRecordingHoldEngaged)
        XCTAssertTrue(commands.isEmpty)
    }

    func testRecordingHoldRejectAckRollsBackOptimisticState() throws {
        let state = VoiceState()
        var sentCommand: [String: Any]?
        state.sendCommand = { sentCommand = $0 }
        state.handleEvent([
            "type": "state",
            "state": "recording",
            "mode": "vad",
        ])
        state.setRecordingHold(true)
        let id = try XCTUnwrap(sentCommand?["id"] as? String)

        state.handleEvent([
            "type": "ack",
            "command": "set_recording_hold",
            "outcome": "reject",
            "id": id,
            "reason": "not recording",
        ])

        XCTAssertFalse(state.isRecordingHoldEngaged)
    }

    func testRecordingHoldSerializesToggleRequestsUntilAck() {
        let state = VoiceState()
        var commands: [[String: Any]] = []
        state.sendCommand = { commands.append($0) }
        state.handleEvent([
            "type": "state",
            "state": "recording",
            "mode": "vad",
        ])

        state.setRecordingHold(true)
        state.setRecordingHold(false)

        XCTAssertTrue(state.isRecordingHoldEngaged)
        XCTAssertEqual(commands.count, 1)
        XCTAssertEqual(commands.first?["engaged"] as? Bool, true)
    }

    func testRecordingExitClearsHoldState() {
        let state = VoiceState()
        state.sendCommand = { _ in }
        state.handleEvent([
            "type": "state",
            "state": "recording",
            "mode": "vad",
        ])
        state.setRecordingHold(true)

        state.handleEvent([
            "type": "state",
            "state": "transcribing",
        ])

        XCTAssertFalse(state.isRecordingHoldEngaged)
    }
}
