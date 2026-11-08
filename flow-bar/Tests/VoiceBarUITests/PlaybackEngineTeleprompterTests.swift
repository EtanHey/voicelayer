import AppKit
import SwiftUI
@testable import VoiceBarUI
import XCTest

/// Lane B (2.4): the teleprompter side of the one PlaybackSession engine, laid out against the REAL notch geometry
/// recorded on the M4 (Tests/Fixtures/notch-geometry-m4-mac16-5.json, NSScreen values, never an assumed width).
/// Frames are opt-in (VOICEBAR_LANEB_SHOTS_DIR); synthetic text, fixed clock, no audio.
@MainActor
final class PlaybackEngineTeleprompterTests: XCTestCase {
    // MARK: - Real notch geometry

    private struct RealScreen {
        let metrics: VoiceBarNotchScreenMetrics
        let safeAreaTop: CGFloat
    }

    private static func realScreen() throws -> RealScreen {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/notch-geometry-m4-mac16-5.json")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let screens = try XCTUnwrap(json["screens"] as? [[String: Any]])
        let screen = try XCTUnwrap(screens.first { $0["builtIn"] as? Bool == true })
        func rect(_ key: String) throws -> CGRect {
            let value = try XCTUnwrap(screen[key] as? [String: Double], key)
            return CGRect(x: value["x"]!, y: value["y"]!, width: value["width"]!, height: value["height"]!)
        }
        let insets = try XCTUnwrap(screen["safeAreaInsets"] as? [String: Double])
        let top = CGFloat(try XCTUnwrap(insets["top"]))
        return RealScreen(metrics: VoiceBarNotchScreenMetrics(
            frame: try rect("frame"), visibleFrame: try rect("visibleFrame"), safeAreaTop: top,
            auxiliaryTopLeftArea: try rect("auxiliaryTopLeftArea"), auxiliaryTopRightArea: try rect("auxiliaryTopRightArea")),
            safeAreaTop: top)
    }

    /// The physical housing between the two auxiliary areas, straight from NSScreen.
    private static func housingWidth(_ screen: RealScreen) -> CGFloat {
        screen.metrics.auxiliaryTopRightArea!.minX - screen.metrics.auxiliaryTopLeftArea!.maxX
    }

    func testTheColumnIsTheBodysWholeTextWidthAtTheRealNotch() throws {
        let screen = try Self.realScreen()
        let core = Self.housingWidth(screen)
        XCTAssertEqual(core, 185, "M4 Mac16,5 housing, from auxiliaryTopLeftArea/auxiliaryTopRightArea")
        let geometry = VoiceBarNotchScreenGeometry.resolve(metrics: screen.metrics)
        XCTAssertEqual(geometry.kind, .hardwareNotch)
        let column = VoiceBarNotchContract.material.teleprompterTextWidth(coreWidth: core)
        // ≥ 8 pt from every edge: the body's text inset, and the text starts below the physical notch band.
        let inset = VoiceBarNotchContract.material.teleprompterBodyHorizontalInset + VoiceBarNotchContract.material.teleprompterTextInnerInset
        XCTAssertGreaterThanOrEqual(inset, 8)
        let body = VoiceBarNotchContract.geometry(for: .teleprompter, coreWidth: core)
        // The column is the body's whole text width, so a wider drawer (Lane A) widens it with no change here.
        // Wider than the old 404 pt cap (429 pt at a 465 pt body; 509 pt at Lane A's 545 pt body).
        XCTAssertEqual(column, body.bodyWidth - 2 * inset)
        XCTAssertGreaterThan(column, 404)
        XCTAssertEqual(TeleprompterA.columnWidth, column)
        XCTAssertGreaterThanOrEqual(body.topHeight, screen.safeAreaTop, "the reading lines sit under the notch band")
        XCTAssertGreaterThanOrEqual(body.bodyWidth - column, 2 * 8)
    }

    // MARK: - Whole words ("Cod…")

    private static let longWords = """
    Codex reviews Claude, then Codex again: Codex, Codex and Codex. The internationalization of VoiceLayer's \
    teleprompter keeps antidisestablishmentarianism whole, and supercalifragilisticexpialidocious too. \
    See https://github.com/EtanHey/voicelayer/pull/809 for the teleprompter clock, then Codex.
    """

    private static func model(_ text: String, column: CGFloat) -> TeleprompterAModel {
        TeleprompterAModelCache().model(text: text, boundaries: [], blocks: [], complete: false, column: column)
    }

    func testEveryLineFitsTheRealColumnSoNoWordIsCompressedToAnEllipsis() throws {
        let column = VoiceBarNotchContract.material.teleprompterTextWidth(coreWidth: Self.housingWidth(try Self.realScreen()))
        for text in [Self.longWords, String(repeating: "Codex ", count: 80), Self.longWords.uppercased()] {
            let model = Self.model(text, column: column)
            let usable = column - TeleprompterA.wrapSlack
            for range in model.lines {
                var used: CGFloat = 0
                for word in range {
                    let gap: CGFloat = word == range.lowerBound || model.glued[word] ? 0 : model.spacing
                    used += gap + min(model.widths[word], usable)
                }
                XCTAssertLessThanOrEqual(used, usable, "line \(range) would be compressed: \(range.map { model.layouts[$0].displayText })")
            }
            for word in model.widths.indices {
                XCTAssertEqual(model.shrinks[word], model.widths[word] > usable, model.layouts[word].displayText)
            }
        }
    }

    func testTheModelMeasuresWhatSwiftUIDraws() {
        for (text, heading) in [("Codex", false), ("Codex,", false), ("internationalization", false), ("Codex", true),
                                ("WWWWWWWWWW", false), ("VoiceLayer's", false)] {
            let host = NSHostingView(rootView: Text(text)
                .font(.system(size: TeleprompterA.fontSize, weight: heading ? .semibold : .medium)).fixedSize())
            XCTAssertLessThanOrEqual(host.fittingSize.width, TeleprompterAModel.width(text, heading: heading) + 0.5, text)
        }
    }

    /// The document splits a token over 24 characters into pieces; they must read as one word, never "antidis… nism".
    func testPiecesOfALongTokenGlueWithNoSpace() {
        let model = Self.model("keep antidisestablishmentarianism whole", column: 429)
        let pieces = model.layouts.indices.filter { model.tokenOfWord?[$0] == 1 }
        XCTAssertEqual(pieces.count, 2)
        XCTAssertFalse(model.glued[pieces[0]])
        XCTAssertTrue(model.glued[pieces[1]])
        XCTAssertEqual(model.lineOfWord[pieces[0]], model.lineOfWord[pieces[1]], "it fits, so it stays on one line")
        XCTAssertEqual(pieces.map { model.layouts[$0].displayText }.joined(), "antidisestablishmentarianism")
    }

    func testAWordWiderThanTheColumnShrinksOnItsOwnLineAndIsNeverCut() {
        let model = Self.model("A Codexcodexcodexcodexcodexcodexcodexcodexcodex word", column: 120)
        let wide = model.widths.indices.filter { model.shrinks[$0] }
        XCTAssertFalse(wide.isEmpty)
        for word in wide {
            let line = model.lines[model.lineOfWord[word]]
            XCTAssertEqual(line.count, 1, "an over-wide piece sits alone on its line")
        }
    }

    func testFooterReadsReadingAndTheSpeedIsItsOwnControl() {
        XCTAssertEqual(TeleprompterA.footerState(isPaused: false, isPausedForDictation: false), "Reading")
        XCTAssertEqual(VoiceState.speedLabel(1), "1×")
        XCTAssertEqual(VoiceState.speedLabel(1.25), "1.25×")
        XCTAssertEqual(VoiceState.speedLabel(0.75), "0.75×")
        var speed = 1.0
        var seen: [Double] = [speed]
        for _ in 1 ..< VoiceState.playbackSpeeds.count { speed = VoiceState.nextPlaybackSpeed(after: speed); seen.append(speed) }
        XCTAssertEqual(Set(seen).count, VoiceState.playbackSpeeds.count)
        XCTAssertEqual(VoiceState.nextPlaybackSpeed(after: speed), 1)
    }

    // MARK: - Clock and controls (VoiceState)

    private var now: TimeInterval = 100

    private func makeState() -> (VoiceState, () -> [[String: Any]]) {
        let state = VoiceState(playbackAmplitudeClock: { [unowned self] in now })
        state.isConnected = true
        state.isCollapsed = false
        var sent: [[String: Any]] = []
        state.sendCommand = { sent.append($0) }
        return (state, { sent })
    }

    private func speaking(offset: Int = 0, rate: Double? = nil, preparing: Bool = false) -> [String: Any] {
        var event: [String: Any] = ["type": "state", "state": "speaking", "text": "One two three four five six seven eight nine ten",
                                    "utteranceId": "read-1", "playback_id": "p-1", "generation": 1,
                                    "playback_offset_ms": offset, "duration_ms": 10_000, "chunk_duration_ms": 10_000,
                                    "long_read": ["id": "read-1", "chunk_index": 0, "chunk_count": 1, "chunk_start_ms": 0,
                                                  "preparing": preparing]]
        if let rate { event["playback_rate"] = rate }
        return event
    }

    /// Etan's QA 2026-11-08 "pause jumps back to 0:00": the clock reads 0 while a read prepares, and that 0 was sent.
    func testPauseWhileThereIsNoPlayerSendsNoClockSoTheDaemonPausesAtItsOwnPosition() {
        let (state, sent) = makeState()
        state.handleEvent(speaking(preparing: true))
        XCTAssertEqual(state.playbackElapsedMilliseconds(), 0, "no player, no clock")
        state.togglePlaybackPause()
        let pause = sent().last { $0["cmd"] as? String == "pause" }
        XCTAssertNotNil(pause)
        XCTAssertNil(pause?["playback_elapsed_ms"], "a 0 from 'no player' must never become the pause position")
    }

    func testPauseWithALivePlayerStillSendsItsClock() {
        let (state, sent) = makeState()
        state.handleEvent(speaking(offset: 2000))
        now += 1.3
        state.togglePlaybackPause()
        XCTAssertEqual(sent().last { $0["cmd"] as? String == "pause" }?["playback_elapsed_ms"] as? Int, 3300)
    }

    func testTheClockRunsAtThePlayersSpeed() {
        let (state, _) = makeState()
        state.handleEvent(speaking(offset: 3000, rate: 1.5))
        XCTAssertEqual(state.playbackRate, 1.5)
        XCTAssertEqual(state.playbackElapsedMilliseconds(), 3000)
        now += 2
        XCTAssertEqual(state.playbackElapsedMilliseconds(), 6000, "2 s of wall time at 1.5× is 3 s of audio")
        state.handleEvent(speaking(offset: 6000))
        now += 1
        XCTAssertEqual(state.playbackRate, 1)
        XCTAssertEqual(state.playbackElapsedMilliseconds(), 7000)
    }

    func testAnAskOwnedPauseIsAPause() {
        let (state, _) = makeState()
        state.handleEvent(speaking(offset: 0))
        state.handleEvent(["type": "playback_state", "state": "paused", "playback_id": "p-1", "generation": 2,
                           "offset_ms": 4000, "chunk_offset_ms": 4000, "pause_owner": "ask", "word_index": 4, "word_count": 10])
        XCTAssertTrue(state.isPlaybackPaused)
        XCTAssertFalse(state.isF5SpeechPausedDuringCapture)
    }

    func testSessionMirrorDrivesThePreviousButtonAndTheSpeedChip() {
        let (state, sent) = makeState()
        state.handleEvent(speaking(offset: 0))
        XCTAssertNil(state.playPreviousRead(), "no previous narration yet: nothing is sent")
        state.handleEvent(["type": "playback_session", "session_id": "read-1", "phase": "playing", "word_index": 2,
                           "word_count": 10, "ask": "none", "parked_by_ask": NSNull(), "previous_available": true, "speed": 1.25])
        XCTAssertTrue(state.previousReadAvailable)
        XCTAssertEqual(state.playbackSpeed, 1.25)
        XCTAssertNotNil(state.playPreviousRead())
        XCTAssertEqual(sent().last?["cmd"] as? String, "previous_read")
        state.cyclePlaybackSpeed()
        XCTAssertEqual(sent().last?["cmd"] as? String, "set_playback_speed")
        XCTAssertEqual(sent().last?["speed"] as? Double, 1.5)
        XCTAssertEqual(state.playbackSpeed, 1.5)
        state.handleEvent(["type": "playback_session", "speed": 7, "previous_available": false])
        XCTAssertEqual(state.playbackSpeed, 1.5, "an unknown speed is ignored")
        XCTAssertFalse(state.previousReadAvailable)
    }

    // MARK: - Frames at the real column (opt-in)

    func testWriteRealGeometryFramesWhenRequested() throws {
        guard let path = ProcessInfo.processInfo.environment["VOICEBAR_LANEB_SHOTS_DIR"], !path.isEmpty else {
            throw XCTSkip("Set VOICEBAR_LANEB_SHOTS_DIR to write the Lane B teleprompter frames")
        }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let column = VoiceBarNotchContract.material.teleprompterTextWidth(coreWidth: Self.housingWidth(try Self.realScreen()))
        var table = SpeechWordTable(utteranceID: "laneb")
        let rows = TeleprompterContentModel.displayTokens(Self.longWords).enumerated().map { index, token -> [String: Any] in
            ["text": token, "startMs": index * 300, "endMs": index * 300 + 250]
        }
        table.apply(["utteranceId": "laneb", "wordOffset": 0, "words": rows])
        for (appearanceName, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            for (name, lines, speed) in [("3-line", 3, 1.0), ("8-line", 8, 1.5)] {
                let view = TeleprompterAView(text: Self.longWords, speechWords: table, visibleLines: lines,
                                             onVisibleLinesChange: { _ in }, columnWidth: column,
                                             playbackElapsedMilliseconds: { 2_700 }, speed: speed, onCycleSpeed: {},
                                             previousAvailable: true, onPrevious: {})
                try render(view, column: column, appearance: appearance,
                           to: directory.appendingPathComponent("laneb-teleprompter-\(name)-\(appearanceName).png"))
            }
        }
    }

    private func render(_ view: TeleprompterAView, column: CGFloat, appearance: NSAppearance.Name, to url: URL) throws {
        let notchAppearance: VoiceBarNotchAppearance = appearance == .darkAqua ? .dark : .light
        let size = CGSize(width: column + 36, height: TeleprompterA.bodyHeight(lines: view.visibleLines) + 44)
        let root = view
            .padding(18)
            .frame(width: size.width, height: size.height, alignment: .top)
            .background(RoundedRectangle(cornerRadius: 24)
                .fill(notchAppearance == .dark ? Color.black : Color(red: 0.86, green: 0.88, blue: 0.92)))
            .environment(\.voiceBarNotchAppearance, notchAppearance)
        let host = NSHostingView(rootView: root)
        host.appearance = NSAppearance(named: appearance)
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        window.orderBack(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url)
    }
}
