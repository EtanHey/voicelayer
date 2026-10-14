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
                                       "playback_offset_ms": chunkStart, "duration_ms": chunkStart + 4000]
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

    func testUntimedEstimatedAndReadbackWordsNeverSeek() {
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
        TeleprompterSeekPolicy.seek(timed[0], isReadback: true, seek: { seeks.append($0) })
        XCTAssertTrue(seeks.isEmpty)
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
        state.handleEvent(["type": "state", "state": "speaking", "text": "Hello world", "duration_ms": 4000])
        state.handleEvent(["type": "subtitle", "words": [
            ["text": "Hello", "offset_ms": 0, "duration_ms": 300],
            ["text": "world", "offset_ms": 650, "duration_ms": 300],
        ]])
        state.handleEvent(["type": "state", "state": "speaking", "text": "Hello world",
                           "playback_offset_ms": 650, "duration_ms": 4000])
        XCTAssertEqual(TeleprompterPlaybackPolicy.currentWordIndex(in: words(for: state),
                       elapsedMilliseconds: state.playbackElapsedMilliseconds()), 1)
        state.handleEvent(["type": "state", "state": "idle", "source": "playback"])
        XCTAssertFalse(TeleprompterPlaybackPolicy.animatesTimeline(isReadback: state.isTeleprompterReadback))
        var commands: [[String: Any]] = []
        state.sendCommand = { commands.append($0) }
        state.seek(offsetMs: 650)
        XCTAssertTrue(commands.isEmpty)
    }

    func testViewWiresAccessibleTimedButtonsAndMountsScrubberOnlyWhileSpeaking() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let view = try String(contentsOf: root.appendingPathComponent("Sources/VoiceBarUI/TeleprompterView.swift"))
        let bar = try String(contentsOf: root.appendingPathComponent("Sources/VoiceBarUI/BarView.swift"))
        XCTAssertTrue(view.contains("Button {"))
        XCTAssertTrue(view.contains(".accessibilityHint(\"Seek to this word\")"))
        XCTAssertTrue(bar.contains("if state.mode == .speaking"))
        XCTAssertTrue(bar.contains("TeleprompterPlaybackScrubBar(state: state)"))
        let scrub = try String(contentsOf: root.appendingPathComponent("Sources/VoiceBarUI/SettingsPlaybackScrubBar.swift"))
        XCTAssertTrue(scrub.contains("if isPlaying {\n                TimelineView"), "idle has no periodic schedule")
        XCTAssertLessThanOrEqual(1 / SettingsPlaybackScrubBar.tickInterval, 10)
    }

    func testPreparingIsStaticUntilDurationAndNotReadyAckDoesNotJumpClock() {
        let state = VoiceState(playbackAmplitudeClock: { 100 })
        state.handleEvent(["type": "state", "state": "speaking", "text": "Preparing speech…",
                           "long_read": ["chunk_start_ms": 0, "preparing": true]])
        XCTAssertFalse(state.isTeleprompterPlaybackReady)
        let epoch = state.playbackEpoch
        state.handleEvent(["type": "ack", "command": "seek", "outcome": "reject", "reason": "not ready"])
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

    func testWritesSpeakingLongReadAndCloneArtifacts() async throws {
        try VisualArtifactTestPolicy.requireRegeneration()
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("docs.local/teleprompter-scrub")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (name, chunkStart, timed) in [("speaking", 0, true), ("long-read", 60000, true), ("clone", 0, false)] {
            let state = VoiceState(playbackAmplitudeClock: { 100 })
            let text = "Click a timed word to return to its start or drag the timeline to listen again."
            state.isConnected = true
            state.hotkeyEnabled = true
            state.handleEvent(["type": "state", "state": "speaking", "text": text,
                               "playback_offset_ms": chunkStart + 2100, "duration_ms": chunkStart + 7000,
                               "long_read": chunkStart > 0 ? ["chunk_start_ms": chunkStart] : NSNull()])
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
            window.orderFront(nil)
            window.isReleasedWhenClosed = false
            defer { window.close() }
            host.appearance = NSAppearance(named: .darkAqua)
            host.frame = NSRect(x: 0, y: 0, width: 465, height: 228)
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(120))
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
                .write(to: directory.appendingPathComponent("\(name)-verified.png"))
        }
    }

    private final class ArtifactRouter: BarCommandRouting {
        func handlePrimaryTap() {}
        func handleCancel() {}
        func handleStop() {}
        func handleReplay() {}
        func handleRetranscribeHistoryEntry(recordingPath: String) {}
    }

    private func words(for state: VoiceState) -> [TeleprompterWord] {
        TeleprompterContentModel.words(text: state.statusText, wordBoundaries: state.wordBoundaries.map {
            TeleprompterBoundary(offsetMs: $0.offsetMs, durationMs: $0.durationMs, text: $0.text)
        })
    }
}
