import OffscreenTestSupport
import AppKit
import SwiftUI
@testable import VoiceBarUI
import XCTest

@MainActor
final class TeleprompterScrubTests: XCTestCase {
    func testTimedWordTapSendsExactShortAndGlobalLongReadSeek() throws {
        for chunkStart in [0, 12000] {
            let state = VoiceState(playbackAmplitudeClock: { 100 })
            var commands: [[String: Any]] = []
            state.sendCommand = { commands.append($0) }
            var event: [String: Any] = ["type": "state", "state": "speaking", "text": "Hello world",
                                       "playback_offset_ms": chunkStart, "duration_ms": chunkStart + 4000, "readback_id": "fixture"]
            if chunkStart > 0 { event["long_read"] = ["chunk_start_ms": chunkStart] }
            state.handleEvent(event)
            state.handleEvent(["type": "subtitle", "words": [
                ["text": "Hello", "offset_ms": 100, "duration_ms": 300],
                ["text": "world", "offset_ms": 650, "duration_ms": 300],
            ]])
            let words = words(for: state)
            TeleprompterSeekPolicy.seek(words[1], isReadback: false, seek: state.seek)
            XCTAssertEqual(commands.count, 1)
            XCTAssertEqual(commands.first?["cmd"] as? String, "seek")
            XCTAssertEqual(commands.first?["offset_ms"] as? Int, chunkStart + 650)
            XCTAssertEqual(state.mode, .speaking)
        }
    }

    func testEndedReadbackWordSeeksAtExactGlobalOffset() throws {
        for chunkStart in [0, 12000] {
            let state = VoiceState()
            var commands: [[String: Any]] = []
            state.sendCommand = { commands.append($0) }
            var event: [String: Any] = ["type": "state", "state": "speaking", "text": "Hello world",
                                       "duration_ms": chunkStart + 4000, "readback_id": "fixture"]
            if chunkStart > 0 { event["long_read"] = ["chunk_start_ms": chunkStart] }
            state.handleEvent(event)
            state.handleEvent(["type": "subtitle", "words": [
                ["text": "Hello", "offset_ms": 100, "duration_ms": 200],
                ["text": "world", "offset_ms": 650, "duration_ms": 200],
            ]])
            state.handleEvent(["type": "state", "state": "idle", "source": "playback"])
            let retained = TeleprompterContentModel.words(text: state.teleprompterText ?? "",
                                                        wordBoundaries: state.teleprompterWordBoundaries)
            XCTAssertTrue(state.isTeleprompterReadback)
            XCTAssertEqual(TeleprompterSeekPolicy.offset(for: retained[1], isReadback: true), chunkStart + 650)
            TeleprompterSeekPolicy.seek(retained[1], isReadback: true, seek: state.seek)
            XCTAssertEqual(commands.last?["offset_ms"] as? Int, chunkStart + 650)
            XCTAssertEqual(commands.last?["scope"] as? String, "readback")
            XCTAssertEqual(commands.last?["readback_id"] as? String, "fixture")
            XCTAssertEqual(state.mode, .idle, "Only the daemon's playback receipt starts the clock")
        }
    }

    func testReadbackTimingAndAudioFailuresAreVisibleWithoutChangingTheReadback() {
        let state = VoiceState()
        state.handleEvent(["type": "state", "state": "speaking", "text": "Clone speech", "readback_id": "clone"])
        state.handleEvent(["type": "state", "state": "idle", "source": "playback"])
        var seeks: [Int] = []
        let untimed = TeleprompterContentModel.words(text: "Clone speech", wordBoundaries: [])
        TeleprompterSeekPolicy.seek(untimed[0], isReadback: true, seek: { seeks.append($0) },
                                   unavailable: state.reportWordTimingUnavailable)
        XCTAssertTrue(seeks.isEmpty)
        XCTAssertEqual(state.confirmationText, "Word timing unavailable")
        var readbackSeek: [String: Any]?
        state.sendCommand = { readbackSeek = $0 }
        state.seek(offsetMs: 300)
        state.handleEvent(["type": "ack", "command": "seek", "id": readbackSeek?["id"] as Any,
                           "outcome": "reject", "reason": "Replay prefix audio unavailable"])
        XCTAssertEqual(state.confirmationText, "Replay prefix audio unavailable")
        state.handleEvent(["type": "error", "source": "seek", "message": "Conversion failed"])
        XCTAssertEqual(state.confirmationText, "Conversion failed")
        XCTAssertEqual(state.teleprompterText, "Clone speech")
        XCTAssertEqual(state.mode, .idle)
        var commands: [[String: Any]] = []
        state.sendCommand = { commands.append($0) }
        state.handleEvent(["type": "state", "state": "recording"])
        state.seek(offsetMs: 300)
        XCTAssertTrue(commands.isEmpty)
    }

    func testLateCurrentSeekAckCannotToastDuringReadback() {
        let state = VoiceState()
        state.handleEvent(["type": "state", "state": "speaking", "text": "Readback", "readback_id": "retained"])
        state.handleEvent(["type": "state", "state": "idle", "source": "playback"])
        state.handleEvent(["type": "ack", "command": "seek", "id": "old-current-seek", "outcome": "noop", "reason": "nothing playing"])
        XCTAssertNil(state.confirmationText)
        var command: [String: Any]?
        state.sendCommand = { command = $0 }
        state.seek(offsetMs: 100)
        state.handleEvent(["type": "ack", "command": "seek", "id": command?["id"] as Any,
                           "outcome": "reject", "reason": "Replay prefix audio unavailable"])
        XCTAssertEqual(state.confirmationText, "Replay prefix audio unavailable")
    }

    func testUntimedAndEstimatedWordsNeverGuessASeek() {
        let untimed = TeleprompterContentModel.words(text: "Clone speech", wordBoundaries: [])
        let estimated = TeleprompterContentModel.words(text: "Hello world", wordBoundaries: [
            TeleprompterBoundary(offsetMs: 100, durationMs: 900, text: "Hello world"),
        ])
        XCTAssertNotNil(estimated[1].offsetMs, "existing estimated highlighting remains available")
        var seeks: [Int] = []
        for word in untimed + estimated {
            TeleprompterSeekPolicy.seek(word, isReadback: false, seek: { seeks.append($0) })
        }
        let timed = TeleprompterContentModel.words(text: "Hello", wordBoundaries: [
            TeleprompterBoundary(offsetMs: 100, durationMs: 200, text: "Hello"),
        ])
        XCTAssertTrue(seeks.isEmpty)
        TeleprompterSeekPolicy.seek(timed[0], isReadback: true, seek: { seeks.append($0) })
        XCTAssertEqual(seeks, [100])
    }

    func testSharedDragPreviewsAndCommitsOnlyOnceIncludingTrackClick() {
        var drag = SettingsScrubDrag()
        var seeks: [Double] = []
        drag.changed(toFraction: 0.2, duration: 20)
        drag.changed(toFraction: 0.7, duration: 20)
        XCTAssertEqual(drag.fraction, 0.7)
        XCTAssertTrue(seeks.isEmpty)
        drag.ended(atFraction: 0.7, duration: 20, seek: { seeks.append($0) })
        XCTAssertEqual(seeks, [14])
        XCTAssertNil(drag.fraction)
        drag.ended(atFraction: 0.25, duration: 20, seek: { seeks.append($0) })
        XCTAssertEqual(seeks, [14, 5])
    }

    func testPositionUsesGlobalClockOnceAndSynthesizedDurationGrows() {
        var now = 100.0
        let state = VoiceState(playbackAmplitudeClock: { now })
        state.handleEvent(["type": "state", "state": "speaking", "text": "Second chunk",
                           "playback_offset_ms": 12500, "duration_ms": 18000,
                           "long_read": ["chunk_start_ms": 12000]])
        now += 0.5
        XCTAssertEqual(state.teleprompterPlaybackPosition.currentTime, 13)
        XCTAssertEqual(state.teleprompterPlaybackPosition.duration, 18)
        XCTAssertEqual(state.teleprompterPlaybackPosition.fraction, 13.0 / 18, accuracy: 0.0001)
        XCTAssertTrue(state.isPlaybackDurationGrowing)
        state.handleEvent(["type": "state", "state": "speaking", "text": "Third chunk",
                           "playback_offset_ms": 18000, "duration_ms": 23000,
                           "long_read": ["chunk_start_ms": 18000, "estimated_total_ms": 24000]])
        XCTAssertEqual(state.teleprompterPlaybackPosition.duration, 23, "seek only synthesized audio")
        XCTAssertFalse(state.isPlaybackDurationGrowing)
    }

    func testSeekReceiptImmediatelySelectsWordAtClockAndIdleStopsTimeline() {
        let state = VoiceState(playbackAmplitudeClock: { 100 })
        state.handleEvent(["type": "state", "state": "speaking", "text": "Hello world", "duration_ms": 4000, "readback_id": "fixture"])
        state.handleEvent(["type": "subtitle", "words": [
            ["text": "Hello", "offset_ms": 0, "duration_ms": 300],
            ["text": "world", "offset_ms": 650, "duration_ms": 300],
        ]])
        state.handleEvent(["type": "state", "state": "speaking", "text": "Hello world",
                           "playback_offset_ms": 650, "duration_ms": 4000, "readback_id": "fixture"])
        XCTAssertEqual(TeleprompterPlaybackPolicy.currentWordIndex(in: words(for: state),
                       elapsedMilliseconds: state.playbackElapsedMilliseconds()), 1)
        state.handleEvent(["type": "state", "state": "idle", "source": "playback"])
        XCTAssertFalse(TeleprompterPlaybackPolicy.animatesTimeline(isReadback: state.isTeleprompterReadback))
        var commands: [[String: Any]] = []
        state.sendCommand = { commands.append($0) }
        state.seek(offsetMs: 650)
        XCTAssertEqual(commands.last?["offset_ms"] as? Int, 650)
    }

    func testViewWiresAccessibleTimedButtonsAndMountsScrubberOnlyWhileSpeaking() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let view = try String(contentsOf: root.appendingPathComponent("Sources/VoiceBarUI/TeleprompterView.swift"))
        let bar = try String(contentsOf: root.appendingPathComponent("Sources/VoiceBarUI/BarView.swift"))
        XCTAssertTrue(view.contains("Button {"))
        XCTAssertTrue(view.contains(".accessibilityHint(\"Seek to this word\")"))
        XCTAssertTrue(bar.contains("if state.showsTeleprompterScrubber {\n                    TeleprompterPlaybackScrubBar(state: state)"),
                      "SCRUB1: ended readback keeps the scrubber mounted")
        let scrub = try String(contentsOf: root.appendingPathComponent("Sources/VoiceBarUI/SettingsPlaybackScrubBar.swift"))
        XCTAssertTrue(scrub.contains("if isPlaying {\n                TimelineView"), "idle has no periodic schedule")
        let wrapper = try String(contentsOf: root.appendingPathComponent("Sources/VoiceBarUI/TeleprompterPlaybackScrubBar.swift"))
        XCTAssertTrue(wrapper.contains("control.disabled(!state.isTeleprompterScrubSeekable)"))
        XCTAssertLessThanOrEqual(1 / SettingsPlaybackScrubBar.tickInterval, 10)
    }

    // SCRUB1: Etan, 2.2.46 — "the scrub doesn't work at all" on an ended read.
    func testEndedReadbackKeepsARealDurationScrubberThatSeeksTheRetainedReadback() {
        for (chunkStart, stoppedAt) in [(0, 18300), (12000, 15000)] {
            var now = 100.0
            let state = VoiceState(playbackAmplitudeClock: { now })
            var event: [String: Any] = ["type": "state", "state": "speaking", "text": "Hello world",
                                       "playback_offset_ms": chunkStart, "duration_ms": 18300, "readback_id": "fixture"]
            if chunkStart > 0 { event["long_read"] = ["id": "read", "chunk_start_ms": chunkStart, "estimated_total_ms": 18300] }
            state.handleEvent(event)
            now += Double(stoppedAt - chunkStart) / 1000
            state.handleEvent(["type": "state", "state": "idle", "source": "playback"])
            XCTAssertTrue(state.isTeleprompterReadback)
            XCTAssertTrue(state.showsTeleprompterScrubber)
            XCTAssertTrue(state.isTeleprompterScrubSeekable)
            XCTAssertEqual(state.teleprompterPlaybackPosition.duration, 18.3, accuracy: 0.001)
            XCTAssertEqual(state.teleprompterPlaybackPosition.currentTime, Double(stoppedAt) / 1000, accuracy: 0.001)
            let wrapper = TeleprompterPlaybackScrubBar(state: state)
            XCTAssertTrue(wrapper.control.allowsSeeking)
            XCTAssertFalse(wrapper.control.isPlaying, "an ended read samples no clock")
            XCTAssertFalse(wrapper.control.isGrowing)
            XCTAssertNil(wrapper.timingNotice)
            var commands: [[String: Any]] = []
            state.sendCommand = { commands.append($0) }
            wrapper.control.seek(5)
            XCTAssertEqual(commands.count, 1)
            XCTAssertEqual(commands.first?["cmd"] as? String, "seek")
            XCTAssertEqual(commands.first?["offset_ms"] as? Int, 5000)
            XCTAssertEqual(commands.first?["scope"] as? String, "readback")
            XCTAssertEqual(commands.first?["readback_id"] as? String, "fixture")
            XCTAssertEqual(state.mode, .idle, "only the daemon's speaking receipt restarts the clock")
            now += 30
            XCTAssertEqual(state.teleprompterPlaybackPosition.currentTime, Double(stoppedAt) / 1000, accuracy: 0.001)
            state.handleEvent(["type": "state", "state": "speaking", "text": "Hello world", "playback_offset_ms": 5000,
                               "duration_ms": 18300, "readback_id": "fixture"])
            XCTAssertTrue(state.isTeleprompterPlaybackReady)
            XCTAssertEqual(state.teleprompterPlaybackPosition.currentTime, 5, accuracy: 0.001)
            state.handleEvent(["type": "state", "state": "recording"])
            XCTAssertFalse(state.showsTeleprompterScrubber)
            XCTAssertFalse(state.isTeleprompterScrubSeekable)
        }
    }

    // SCRUB1 R2 (Sol #2): a stopped long read only offers what the daemon retained, not its lookahead.
    func testStoppedLongReadReadbackOffersOnlyTheRetainedRange() {
        var now = 100.0
        let state = VoiceState(playbackAmplitudeClock: { now })
        state.handleEvent(["type": "state", "state": "speaking", "text": "Chunk zero", "duration_ms": 1000,
                           "readback_id": "fixture", "readback_duration_ms": 1000,
                           "long_read": ["id": "read", "chunk_start_ms": 0]])
        state.handleEvent(["type": "playback_duration", "long_read_id": "read", "duration_ms": 3000, "final": true])
        XCTAssertEqual(state.teleprompterPlaybackPosition.duration, 3, "live speech shows the synthesized total")
        now += 0.6
        state.handleEvent(["type": "state", "state": "idle", "source": "playback"])
        XCTAssertEqual(state.teleprompterPlaybackPosition.duration, 1, "readback shows only the retained range")
        XCTAssertEqual(state.teleprompterPlaybackPosition.currentTime, 0.6, accuracy: 0.001)
        var commands: [[String: Any]] = []
        state.sendCommand = { commands.append($0) }
        let wrapper = TeleprompterPlaybackScrubBar(state: state)
        var drag = SettingsScrubDrag()
        drag.ended(atFraction: 1, duration: state.teleprompterPlaybackPosition.duration, seek: wrapper.control.seek)
        XCTAssertEqual(commands.last?["offset_ms"] as? Int, 900, "the far end stays inside the retained 1000 ms")
        XCTAssertEqual(commands.last?["scope"] as? String, "readback")

        let legacy = VoiceState(playbackAmplitudeClock: { 100 })
        legacy.handleEvent(["type": "state", "state": "speaking", "text": "Old daemon", "duration_ms": 4000, "readback_id": "old"])
        legacy.handleEvent(["type": "state", "state": "idle", "source": "playback"])
        XCTAssertEqual(legacy.teleprompterPlaybackPosition.duration, 4, "an older daemon falls back to its duration")
    }

    func testReadbackWithoutRetainedAudioOrDurationShowsAnInertScrubber() {
        for event: [String: Any] in [
            ["type": "state", "state": "speaking", "text": "No audio identity", "duration_ms": 4000],
            ["type": "state", "state": "speaking", "text": "No duration", "readback_id": "fixture"],
        ] {
            let state = VoiceState(playbackAmplitudeClock: { 100 })
            state.handleEvent(event)
            state.handleEvent(["type": "state", "state": "idle", "source": "playback"])
            XCTAssertTrue(state.showsTeleprompterScrubber)
            XCTAssertFalse(state.isTeleprompterScrubSeekable)
            XCTAssertFalse(TeleprompterPlaybackScrubBar(state: state).control.allowsSeeking)
        }
        let dismissed = VoiceState(playbackAmplitudeClock: { 100 })
        dismissed.handleEvent(["type": "state", "state": "speaking", "text": "Gone", "duration_ms": 4000, "readback_id": "fixture"])
        dismissed.handleEvent(["type": "state", "state": "idle", "source": "playback"])
        dismissed.dismissRetainedTeleprompter()
        XCTAssertFalse(dismissed.showsTeleprompterScrubber)
        XCTAssertFalse(dismissed.isTeleprompterScrubSeekable)
    }

    func testLongReadDurationUpdatesReplaceTheStaleSoFarTotal() {
        let state = VoiceState(playbackAmplitudeClock: { 100 })
        state.handleEvent(["type": "state", "state": "speaking", "text": "Preparing speech…",
                           "long_read": ["id": "read", "chunk_start_ms": 0, "preparing": true]])
        state.handleEvent(["type": "playback_duration", "long_read_id": "read", "duration_ms": 5000, "final": false])
        XCTAssertFalse(state.isTeleprompterPlaybackReady, "preparation stays static until audio starts")
        state.handleEvent(["type": "state", "state": "speaking", "text": "First chunk", "duration_ms": 5000,
                           "long_read": ["id": "read", "chunk_start_ms": 0]])
        XCTAssertTrue(state.isPlaybackDurationGrowing)
        state.handleEvent(["type": "playback_duration", "long_read_id": "other", "duration_ms": 99000, "final": true])
        XCTAssertEqual(state.teleprompterPlaybackPosition.duration, 5, "a foreign read never moves this clock")
        state.handleEvent(["type": "playback_duration", "long_read_id": "read", "duration_ms": 11000, "final": false])
        XCTAssertEqual(state.teleprompterPlaybackPosition.duration, 11)
        XCTAssertTrue(state.isPlaybackDurationGrowing)
        state.handleEvent(["type": "playback_duration", "long_read_id": "read", "duration_ms": 18300, "final": true])
        XCTAssertEqual(state.teleprompterPlaybackPosition.duration, 18.3, accuracy: 0.001)
        XCTAssertFalse(state.isPlaybackDurationGrowing, "the final total drops the \"so far\" label")
        state.handleEvent(["type": "state", "state": "speaking", "text": "Second chunk", "playback_offset_ms": 5000,
                           "duration_ms": 11000, "long_read": ["id": "read", "chunk_start_ms": 5000]])
        XCTAssertEqual(state.teleprompterPlaybackPosition.duration, 18.3, accuracy: 0.001,
                       "a later chunk edge never shrinks a total the read already reported")
        XCTAssertFalse(state.isPlaybackDurationGrowing)
        state.handleEvent(["type": "state", "state": "idle", "source": "playback"])
        state.handleEvent(["type": "playback_duration", "long_read_id": "read", "duration_ms": 30000, "final": true])
        XCTAssertEqual(state.teleprompterPlaybackPosition.duration, 18.3, accuracy: 0.001, "idle ignores late totals")
    }

    // SCRUB1 parity (QA 2026-10-19 03:48, Findings 1–2): readback wears the speaking chrome.
    func testReadbackWearsTheSpeakingChromeWithAFilledWingAndCentredText() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let bar = try String(contentsOf: root.appendingPathComponent("Sources/VoiceBarUI/BarView.swift"))
        XCTAssertTrue(bar.contains(".frame(height: state.showsTeleprompterScrubber ? Theme.teleprompterViewportHeight : nil)"))
        XCTAssertTrue(bar.contains("if state.showsTeleprompterScrubber { Spacer(minLength: 0) }"))
        XCTAssertTrue(bar.contains("case .teleprompter:\n            if state.mode == .speaking || state.isTeleprompterReadback {\n                notchWaveform"),
                      "the reserved trailing wing is never left empty in readback")
        XCTAssertTrue(bar.contains("isPlaybackEnded: state.isTeleprompterReadback"))
        XCTAssertTrue(bar.contains("accessibilityLabel: \"Dismiss teleprompter\""), "readback keeps its dismiss control")
        XCTAssertEqual(TeleprompterScrollPolicy.initialViewportAlignment, .center)
        let state = VoiceState()
        state.handleEvent(["type": "state", "state": "speaking", "text": "Done", "duration_ms": 4000, "readback_id": "fixture"])
        state.handleEvent(["type": "state", "state": "idle", "source": "playback"])
        XCTAssertEqual(state.showsTeleprompterScrubber, true)
    }

    func testEndedPlaybackWingIsAVisibleRestingBedThatSamplesNoLevel() async throws {
        XCTAssertNotEqual(VoiceBarNotchWaveform.waveformColor(mode: .idle, isCaptureLive: false, isPlaybackEnded: true), .clear)
        XCTAssertEqual(VoiceBarNotchWaveform.waveformColor(mode: .idle, isCaptureLive: false), .clear)
        var reads = 0
        let host = NSHostingView(rootView: VoiceBarNotchWaveform(
            mode: .idle, isListening: false, isCaptureLive: false,
            recordingLevel: { reads += 1; return 1 }, playbackLevel: { reads += 1; return 1 },
            isPlaybackEnded: true
        ).frame(width: 60, height: 20))
        host.frame = NSRect(x: 0, y: 0, width: 60, height: 20)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(reads, 0, "an ended read has no level to show")
    }

    /// NOTCH2: the teleprompter centres "Preparing speech…" only while the daemon prepares, then crossfades to
    /// the read's text on the first chunk.
    func testPreparingSpeechLastsUntilTheFirstChunkOrIdle() {
        let state = VoiceState(playbackAmplitudeClock: { 100 })
        XCTAssertFalse(state.isPreparingSpeech)
        state.handleEvent(["type": "state", "state": "speaking", "text": "Preparing speech…",
                           "long_read": ["id": "r1", "chunk_start_ms": 0, "preparing": true]])
        XCTAssertTrue(state.isPreparingSpeech)
        state.handleEvent(["type": "state", "state": "speaking", "text": "First chunk", "duration_ms": 4000,
                           "long_read": ["id": "r1", "chunk_index": 0, "chunk_count": 2, "chunk_start_ms": 0]])
        XCTAssertFalse(state.isPreparingSpeech)
        state.handleEvent(["type": "state", "state": "speaking", "text": "Preparing speech…",
                           "long_read": ["id": "r2", "chunk_start_ms": 0, "preparing": true]])
        XCTAssertTrue(state.isPreparingSpeech)
        state.handleEvent(["type": "state", "state": "idle", "source": "playback"])
        XCTAssertFalse(state.isPreparingSpeech)
    }

    func testPreparingIsStaticUntilDurationAndNotReadyAckDoesNotJumpClock() {
        let state = VoiceState(playbackAmplitudeClock: { 100 })
        state.handleEvent(["type": "state", "state": "speaking", "text": "Preparing speech…",
                           "long_read": ["chunk_start_ms": 0, "preparing": true]])
        XCTAssertFalse(state.isTeleprompterPlaybackReady)
        let epoch = state.playbackEpoch
        state.handleEvent(["type": "ack", "command": "seek", "outcome": "reject", "reason": "not ready"])
        XCTAssertNil(state.confirmationText, "Current-scope preparation acks stay silent")
        XCTAssertEqual(state.playbackEpoch, epoch)
        XCTAssertEqual(state.playbackElapsedMilliseconds(), 0)
        XCTAssertEqual(state.mode, .speaking)
        state.handleEvent(["type": "state", "state": "speaking", "text": "Ready", "duration_ms": 4000])
        XCTAssertTrue(state.isTeleprompterPlaybackReady)
    }

    func testIdleScrubBarDoesNotSampleAClock() async throws {
        var reads = 0
        let host = NSHostingView(rootView: SettingsPlaybackScrubBar(
            position: { reads += 1; return SettingsAudioPlaybackPosition(currentTime: 2, duration: 10) },
            seek: { _ in }, accessibilityNoun: "agent speech", isPlaying: false
        ).frame(width: 300, height: 20))
        host.frame = NSRect(x: 0, y: 0, width: 300, height: 20)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        let settledReads = reads
        try await Task.sleep(for: .milliseconds(800))
        XCTAssertEqual(reads, settledReads, "no periodic clock reads while idle")
    }

    func testSeekRestartUsesReceiptClockWordAndScrollsOnPlaybackEpoch() throws {
        let state = VoiceState(playbackAmplitudeClock: { 100 })
        state.handleEvent(["type": "state", "state": "speaking", "text": "one two three", "duration_ms": 4000])
        state.handleEvent(["type": "subtitle", "words": [
            ["text": "one", "offset_ms": 0, "duration_ms": 300],
            ["text": "two", "offset_ms": 1000, "duration_ms": 300],
            ["text": "three", "offset_ms": 2000, "duration_ms": 300],
        ]])
        state.handleEvent(["type": "state", "state": "speaking", "text": "one two three",
                           "duration_ms": 4000, "playback_offset_ms": 2100])
        let index = TeleprompterPlaybackPolicy.restartWordIndex(in: words(for: state),
            elapsedMilliseconds: state.playbackElapsedMilliseconds(), isReadback: false)
        XCTAssertEqual(index, 2)
        XCTAssertEqual(TeleprompterScrollPolicy.position(for: index), .center)
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/VoiceBarUI/TeleprompterView.swift"))
        XCTAssertTrue(source.contains(".onChange(of: playbackEpoch) { _, _ in\n                restart()\n                scrollToCurrentWord(with: proxy, animated: false)"))
        XCTAssertTrue(source.contains("currentIndex = TeleprompterPlaybackPolicy.restartWordIndex("))
        XCTAssertTrue(source.contains("TeleprompterScrollPolicy.position(for: currentIndex)"))
    }

    func testWrapperPreparingReadyAndCloneGateSamplingAndInteraction() async throws {
        var clockReads = 0
        let state = VoiceState(playbackAmplitudeClock: { clockReads += 1; return 100 })
        state.handleEvent(["type": "state", "state": "speaking", "text": "Preparing speech…",
                           "long_read": ["preparing": true, "chunk_start_ms": 0]])
        state.handleEvent(["type": "subtitle", "words": [["text": "Preparing", "offset_ms": 0, "duration_ms": 300]]])
        let wrapper = TeleprompterPlaybackScrubBar(state: state)
        XCTAssertFalse(wrapper.control.isPlaying)
        XCTAssertFalse(wrapper.control.allowsSeeking)
        XCTAssertFalse(wrapper.control.isGrowing)
        let host = NSHostingView(rootView: wrapper.frame(width: 400, height: 45))
        host.frame = NSRect(x: 0, y: 0, width: 400, height: 45)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        let before = clockReads
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(clockReads, before, "wrapper must not sample while preparing")
        state.handleEvent(["type": "state", "state": "speaking", "text": "Ready now", "duration_ms": 4000])
        state.handleEvent(["type": "subtitle", "words": [["text": "Ready", "offset_ms": 0, "duration_ms": 300]]])
        XCTAssertTrue(wrapper.control.isPlaying)
        XCTAssertTrue(wrapper.control.allowsSeeking)
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertGreaterThan(clockReads, before, "ready timed playback samples the clock")
        state.handleEvent(["type": "state", "state": "speaking", "text": "Cloned reply", "duration_ms": 4000,
                           "long_read": ["chunk_start_ms": 0]])
        XCTAssertTrue(state.wordBoundaries.isEmpty)
        XCTAssertTrue(wrapper.control.isPlaying, "ready clone playback samples the time clock")
        XCTAssertTrue(wrapper.control.allowsSeeking, "time seeking does not require word timings")
        XCTAssertTrue(wrapper.control.isGrowing)
        var commands: [[String: Any]] = []
        state.sendCommand = { commands.append($0) }
        for word in words(for: state) {
            XCTAssertNil(TeleprompterSeekPolicy.offset(for: word, isReadback: false))
            TeleprompterSeekPolicy.seek(word, isReadback: false, seek: state.seek)
        }
        XCTAssertTrue(commands.isEmpty, "clone words remain non-clickable")
        wrapper.control.seek(1.5)
        XCTAssertEqual(commands.count, 1)
        XCTAssertEqual(commands.first?["cmd"] as? String, "seek")
        XCTAssertEqual(commands.first?["offset_ms"] as? Int, 1500)
    }


    func testGrowingDurationClearsAfterIdleAndPreparationHasNoGrowingAffordance() {
        let state = VoiceState(playbackAmplitudeClock: { 100 })
        state.handleEvent(["type": "state", "state": "speaking", "text": "Long reply", "duration_ms": 4000,
                           "long_read": ["chunk_start_ms": 0]])
        XCTAssertTrue(state.isPlaybackDurationGrowing)
        state.handleEvent(["type": "state", "state": "idle", "source": "playback"])
        XCTAssertFalse(state.isPlaybackDurationGrowing)
        state.handleEvent(["type": "state", "state": "speaking", "text": "Preparing speech…",
                           "long_read": ["preparing": true, "chunk_start_ms": 0]])
            XCTAssertFalse(TeleprompterPlaybackScrubBar(state: state).control.isGrowing)
        }

    func testWritesSpeakingLongReadAndCloneArtifacts() async throws {
        try VisualArtifactTestPolicy.requireRegeneration()
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("docs.local/teleprompter-scrub")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (name, chunkStart, timed, text) in [
            ("speaking", 0, true, "The build passed. I found the missing callback and wired it to the playback clock. The highlight now follows the audio."),
            ("long-read", 60000, true, "The next section explains the tradeoff. We can start playing the first paragraph while the remaining paragraphs are still being synthesized."),
            ("clone", 0, false, "I checked the logs. The service restarted cleanly, and your recordings are intact. The remaining change is ready for review."),
        ] {
            let state = VoiceState()
            state.isConnected = true
            state.hotkeyEnabled = true
            var event: [String: Any] = ["type": "state", "state": "speaking", "text": text,
                                       "voice": timed ? "en-US-GuyNeural" : "theo-c4",
                                       "playback_offset_ms": chunkStart + 2100, "duration_ms": chunkStart + 12000]
            if chunkStart > 0 { event["long_read"] = ["chunk_start_ms": chunkStart, "chunk_index": 3, "chunk_count": 8] }
            let envelope = PlaybackAmplitudeEnvelope(source: .decodedRMS, sampleIntervalMilliseconds: 50, samples: (0..<240).map { [0.3, 0.4, 0.5, 0.4][$0 % 4] })
            state.handleEvent(event, playbackAmplitude: envelope)
            if timed {
                state.handleEvent(["type": "subtitle", "words": text.split(separator: " ").enumerated().map {
                    ["text": String($0.element), "offset_ms": $0.offset * 350, "duration_ms": 300] as [String: Any]
                }])
            }
            let view = BarView(state: state, commandRouter: ArtifactRouter(), onOpenSettings: {}, onOpenHistory: {})
                .environment(\.controlActiveState, .active)
                .frame(width: 465, height: 228)
            let host = NSHostingView(rootView: view)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 465, height: 228),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = host
            window.appearance = NSAppearance(named: .darkAqua)
            window.backgroundColor = .black
            window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
            VLOrderTestWindow(window)
            window.isReleasedWhenClosed = false
            defer { window.close() }
            host.appearance = NSAppearance(named: .darkAqua)
            host.frame = NSRect(x: 0, y: 0, width: 465, height: 228)
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(450))
            host.needsLayout = true
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            bitmap.size = host.frame.size
            host.cacheDisplay(in: host.bounds, to: bitmap)
            if timed {
                // Word viewport only: excludes the clock, scrub knob and transport glyphs.
                let scale = bitmap.pixelsWide / 465
                let brightTextPixels = (45 * scale..<98 * scale).reduce(0) { count, y in
                    count + (10 * scale..<430 * scale).filter { x in
                        guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return false }
                        return min(color.redComponent, color.greenComponent, color.blueComponent) > 0.86
                    }.count
                }
                XCTAssertGreaterThan(brightTextPixels, 25, "the selected word must remain bright in the mounted notch")
            }
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                .write(to: directory.appendingPathComponent("r2-\(name).png"))
        }
    }

    func testTimedWordCursorPushPopBalancesOverlapsAndDisappear() {
        var pointer = TeleprompterPointerState()
        var actions: [String] = []
        let push = { actions.append("push") }
        let pop = { actions.append("pop") }
        pointer.hover(wordID: 1, isInside: true, push: push, pop: pop)
        pointer.hover(wordID: 1, isInside: true, push: push, pop: pop)
        pointer.hover(wordID: 2, isInside: true, push: push, pop: pop)
        pointer.hover(wordID: 1, isInside: false, push: push, pop: pop)
        XCTAssertEqual(actions, ["push"])
        pointer.reset(pop: pop)
        pointer.hover(wordID: 2, isInside: false, push: push, pop: pop)
        pointer.reset(pop: pop)
        XCTAssertEqual(actions, ["push", "pop"], "disappear pops exactly once")
        pointer.hover(wordID: 3, isInside: true, push: push, pop: pop)
        pointer.hover(wordID: 3, isInside: false, push: push, pop: pop)
        XCTAssertEqual(actions, ["push", "pop", "push", "pop"])
    }

    private final class ArtifactRouter: BarCommandRouting {
        func handlePrimaryTap() {}
        func handleCancel() {}
        func handleStop() {}
        func handleReplay() {}
        func handleRetranscribeHistoryEntry(recordingPath: String) {}
    }

    private func words(for state: VoiceState) -> [TeleprompterWord] {
        TeleprompterContentModel.words(text: state.statusText, wordBoundaries: state.wordBoundaries)
    }
}
