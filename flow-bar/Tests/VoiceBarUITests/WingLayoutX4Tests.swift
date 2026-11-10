import AppKit
import OffscreenTestSupport
import SwiftUI
@testable import VoiceBarUI
import XCTest

/// X4 (Etan, PR #860 pictures and the 12:57 M4 recording, 2026-11-10): "no gap between timer and waveform, too much
/// space on the right, waveform sitting high, stop / eye / replay not centred with the drag bar"; J2 "the seconds and
/// the waveform shift sideways when I open or hold the notch"; J4 "the mute button has no tooltip".
///
/// Pixels are read at a fixed 2x (the `EtanQA0510Tests.fixedScaleBitmap` pattern). The wing rows are painted through
/// the production slot layout (`VoiceBarNotchWingSlot`) without glass, so they measure on every host; the whole
/// BarView is measured too, but only where `cacheDisplay` paints native glass content (macOS 26.5 paints it dim, so
/// the M1 skips that one loudly and the M4 runs it). Positions (lower row, J2) come from the drawn controls' own
/// tooltip views, which need no pixels.
@MainActor
final class WingLayoutX4Tests: XCTestCase {
    private final class Router: BarCommandRouting {
        func handlePrimaryTap() {}
        func handleCancel() {}
        func handleStop() {}
        func handleReplay() {}
        func handleRetranscribeHistoryEntry(recordingPath: String) {}
    }

    private static let scale: CGFloat = 2
    /// The M4's measured hardware-notch occlusion (the glass hides the right wing's first 8.5 pt).
    private static let insets: [CGFloat] = [0, 8.5]
    private static let microphone = "QA microphone"
    private var windows: [NSWindow] = []

    override func tearDown() {
        for window in windows { window.contentView = nil; window.close() }
        windows.removeAll()
        super.tearDown()
    }

    // MARK: Fixtures

    private enum Fixture: String, CaseIterable {
        case recordingPTT, recordingVAD, readingOpen, readingPaused, readingHidden

        var isRecording: Bool { self == .recordingPTT || self == .recordingVAD }
    }

    private func state(_ fixture: Fixture) -> VoiceState {
        let state = VoiceState(recentTranscriptionsLoader: { [] }, recentTranscriptionsSaver: { _ in },
                               recentTranscriptionEntriesLoader: { [] }, recentTranscriptionEntriesSaver: { _ in },
                               playbackAmplitudeClock: { 100 }, keepsExpandedInDevState: false)
        state.recordingTimingClock = { 100 }
        state.recordingMicrophoneNameProvider = { Self.microphone }
        state.sendCommand = { _ in }
        state.isConnected = true
        state.isCollapsed = false
        switch fixture {
        case .recordingPTT, .recordingVAD:
            state.handleEvent(["type": "state", "state": "recording",
                               "mode": fixture == .recordingPTT ? "ptt" : "vad"])
            // The first audio frame opens capture: the time shows from here (silence keeps the bars flat).
            state.handleEvent(["type": "audio_level", "rms": 0.0])
            XCTAssertTrue(state.isRecordingCaptureOpen, "fixture: capture is open, so the time paints")
        case .readingOpen, .readingPaused, .readingHidden:
            state.handleEvent(["type": "state", "state": "speaking",
                               "text": "A synthetic sentence for the wing layout. Every word stays visible.",
                               "request_id": "x4-read", "playback_id": "x4-player", "generation": 1])
            state.canReplay = true
            if fixture == .readingPaused {
                state.handleEvent(["type": "playback_state", "state": "paused", "playback_id": "x4-player",
                                   "generation": 2, "offset_ms": 0, "chunk_offset_ms": 0])
            }
            if fixture == .readingHidden { state.dismissTeleprompter() }
        }
        return state
    }

    private func presentation(_ fixture: Fixture, inset: CGFloat) -> VoiceBarNotchPresentation {
        let state = state(fixture)
        return VoiceBarPresentation.notchPresentation(from: VoiceBarNotchOperationalInput(
            mode: state.mode,
            showsRecordingHold: fixture == .recordingVAD,
            showsRecordingPause: fixture == .recordingPTT,
            hasTeleprompterText: state.teleprompterText != nil,
            isTeleprompterDismissed: state.isTeleprompterDismissed,
            isPlaybackPaused: state.isPlaybackPaused,
            readQueueLeadingSlotCount: VoiceBarPresentation.playbackLeadingSlotCount(for: state),
            visibleCoreOcclusionInset: inset))
    }

    // MARK: Mounting

    private func mount(_ view: some View, size: CGSize, panel: Bool = true) -> NSHostingView<AnyView> {
        let host = NSHostingView(rootView: AnyView(view
            .frame(width: size.width, height: size.height, alignment: .top)
            .environment(\.colorScheme, .dark)
            .environment(\.visualRenderTime, 0)
            .transaction { $0.animation = nil; $0.disablesAnimations = true }))
        host.frame = NSRect(origin: .zero, size: size)
        host.appearance = NSAppearance(named: .darkAqua)
        let window: NSWindow = panel
            ? NSPanel(contentRect: host.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered,
                      defer: false)
            : NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = host.appearance
        window.contentView = host
        windows.append(window)
        XCTAssertTrue(VLOffscreenPolicyInstalled())
        VLOrderTestWindow(window)
        host.layoutSubtreeIfNeeded()
        // Wing content fades in after a short delay; let it land.
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        host.layoutSubtreeIfNeeded()
        return host
    }

    /// The whole BarView on a 540 pt canvas, as the catalog draws it.
    private func mountBar(_ state: VoiceState, model: VoiceBarNotchPresentationModel? = nil,
                          _ configure: (BarView) -> BarView = { $0 }) -> NSHostingView<AnyView> {
        let old = NSApplication.shared.appearance
        NSApplication.shared.appearance = NSAppearance(named: .darkAqua) // BarView takes its ink at init
        defer { NSApplication.shared.appearance = old }
        let bar = configure(BarView(state: state, commandRouter: Router(), onOpenSettings: {}, onOpenHistory: {},
                                    presentationModel: model, includesPanelOutsets: true))
            .fixedSize(horizontal: false, vertical: true)
        let height = max(80, ceil(NSHostingView(rootView: bar).fittingSize.height))
        return mount(ZStack(alignment: .top) { Color(red: 0.16, green: 0.17, blue: 0.19); bar },
                     size: CGSize(width: 540, height: height))
    }

    /// The frame (window points, y up) of the drawn view registering `tooltip`.
    private func tooltipFrame(_ tooltip: String, in host: NSView) -> CGRect? {
        func all(_ view: NSView) -> [NSView] { view.subviews + view.subviews.flatMap(all) }
        return all(host).first { $0.toolTip == tooltip && !$0.visibleRect.isEmpty }
            .map { $0.convert($0.bounds, to: nil) }
    }

    // MARK: Pixel reading

    private struct Painted {
        let bitmap: NSBitmapImageRep
        var width: Int { bitmap.pixelsWide }
        var height: Int { bitmap.pixelsHigh }

        func rgb(_ x: Int, _ y: Int) -> (CGFloat, CGFloat, CGFloat) {
            guard let c = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return (0, 0, 0) }
            return (c.redComponent, c.greenComponent, c.blueComponent)
        }

        /// First and last matching column, and the weighted vertical centre, in pixels.
        func ink(x: Range<Int>, y: Range<Int>, _ weight: (CGFloat, CGFloat, CGFloat) -> CGFloat)
            -> (first: Int, last: Int, centreY: CGFloat)? {
            var first = Int.max, last = -1, total: CGFloat = 0, weightedY: CGFloat = 0
            for px in x.clamped(to: 0 ..< width) {
                for py in y.clamped(to: 0 ..< height) {
                    let (r, g, b) = rgb(px, py)
                    let w = weight(r, g, b)
                    guard w > 0 else { continue }
                    first = min(first, px); last = max(last, px)
                    total += w; weightedY += w * (CGFloat(py) + 0.5)
                }
            }
            return last < 0 ? nil : (first, last, weightedY / total)
        }
    }

    /// The time's digits: neutral, bright ink.
    private static func digit(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> CGFloat {
        let lo = min(r, g, b), hi = max(r, g, b)
        return lo > 0.45 && hi - lo < 0.08 ? lo : 0
    }

    /// The level meter: the recording red or the reading blue.
    private static func bar(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> CGFloat {
        if r > 0.45, r - max(g, b) > 0.2 { return r - max(g, b) }
        if b > 0.45, b - max(r, g) > 0.15 { return b - max(r, g) }
        return 0
    }

    /// Any drawn mark: glyphs, plates, bars.
    private static func mark(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> CGFloat {
        0.299 * r + 0.587 * g + 0.114 * b > 0.25 || bar(r, g, b) > 0 ? 1 : 0
    }

    private struct RowNumbers: CustomStringConvertible {
        var gap: CGFloat, digitsY: CGFloat, barsY: CGFloat, coreSide: CGFloat, outerSide: CGFloat

        var description: String {
            String(format: "gap=%.2f digitsY=%.2f barsY=%.2f visibleCoreSide=%.2f outerSide=%.2f",
                   gap, digitsY, barsY, coreSide, outerSide)
        }
    }

    /// Reads the right-wing row out of a painted strip of `wingWidth` points whose first `inset` points are hidden.
    private func rowNumbers(_ p: Painted, wingWidth: CGFloat, inset: CGFloat, label: String) throws -> RowNumbers {
        let s = Self.scale
        let all = 0 ..< p.width, rows = 0 ..< p.height
        // The meter is the first coloured ink; the time is the bright ink before it (Stop's glyph comes after).
        let firstBar = try XCTUnwrap(p.ink(x: all, y: rows, Self.bar), "\(label): the meter paints").first
        let digits = try XCTUnwrap(p.ink(x: 0 ..< firstBar, y: rows, Self.digit), "\(label): the time paints")
        let bars = try XCTUnwrap(p.ink(x: firstBar ..< firstBar + Int(WaveformLayout.viewportWidth * s), y: rows,
                                       Self.bar))
        let marks = try XCTUnwrap(p.ink(x: all, y: rows, Self.mark))
        return RowNumbers(gap: CGFloat(bars.first - digits.last - 1) / s, digitsY: digits.centreY / s,
                          barsY: bars.centreY / s, coreSide: CGFloat(marks.first) / s - inset,
                          outerSide: wingWidth - CGFloat(marks.last + 1) / s)
    }

    /// One right wing painted alone, laid out by the production slot (`VoiceBarNotchWingSlot`) for `band`.
    private func paintRightWing(_ content: some View, band: VoiceBarNotchVisualState, inset: CGFloat,
                                width: CGFloat, name: String) throws -> Painted {
        let slot = VoiceBarNotchContract.material.wingContentLayout(for: .trailing, state: band,
                                                                    visibleCoreOcclusionInset: inset)
        let size = CGSize(width: width, height: VoiceBarNotchContract.topHeight)
        let host = mount(content.modifier(VoiceBarNotchWingSlot(slot: slot)).background(Color.black), size: size,
                         panel: false)
        let bitmap = try EtanQA0510Tests.fixedScaleBitmap(host, scale: Self.scale)
        if let directory = ProcessInfo.processInfo.environment["VOICEBAR_X4_CANDIDATES"] {
            try bitmap.representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: directory).appendingPathComponent("x4-right-wing-\(name).png"))
        }
        return Painted(bitmap: bitmap)
    }

    private func recordingRow() -> some View {
        VoiceBarRecordingTrailingRow {
            VoiceBarRecordingTimeRegion(elapsedMilliseconds: { 2_000 }, isCaptureOpen: true, microphoneName: nil,
                                        color: .white)
        } meter: {
            VoiceBarNotchWaveform(mode: .recording, isListening: false, isCaptureLive: true,
                                  recordingLevel: { 0 }, playbackLevel: { nil })
        }
    }

    /// The reading row as BarView composes it (`notchSpeakingTrailingContent`).
    private func readingRow(collapsed: Bool, inset: CGFloat) -> some View {
        VoiceBarReadingTrailingRow(showsStop: collapsed) {
            VoiceBarReadingTimeRegion(elapsedMilliseconds: { 2_000 }, color: .white)
        } meter: {
            VoiceBarNotchWaveform(mode: .speaking, isListening: false, isCaptureLive: false,
                                  recordingLevel: { nil }, playbackLevel: { 0 })
                .frame(width: WaveformLayout.viewportWidth, alignment: .trailing)
        } stop: {
            VoiceBarPillControlButton(icon: "stop.fill", optics: .resolve(for: "stop.fill"), foreground: .white,
                                      halo: .clear, isSelected: false, isDestructive: true,
                                      accessibilityLabel: "Stop speaking", accessibilityHint: "", action: {})
        }
        .padding(.leading, inset)
    }

    // MARK: 1 + 3. Gap and vertical centre (painted, 2x)

    func testTimeAndMeterHaveAClearGapAndShareTheTimeCentre() throws {
        for inset in Self.insets {
            let recordingWidth = presentation(.recordingPTT, inset: inset).geometry.trailingWingWidth
            let readingWidth = VoiceBarPresentation.readingTrailingWingWidth(visibleCoreOcclusionInset: inset)
            let rows: [(String, Painted, CGFloat)] = [
                ("recording-\(inset)", try paintRightWing(recordingRow(), band: .recording, inset: inset,
                                                           width: recordingWidth, name: "recording-\(inset)"),
                 recordingWidth),
                ("reading-open-\(inset)", try paintRightWing(readingRow(collapsed: false, inset: inset),
                    band: .teleprompter, inset: inset, width: readingWidth, name: "reading-open-\(inset)"),
                 readingWidth),
                ("reading-paused-\(inset)", try paintRightWing(readingRow(collapsed: true, inset: inset),
                    band: .compactStatus, inset: inset, width: readingWidth, name: "reading-paused-\(inset)"),
                 readingWidth),
            ]
            for (label, painted, width) in rows {
                let n = try rowNumbers(painted, wingWidth: width, inset: inset, label: label)
                print("[X4] \(label): \(n)")
                XCTAssertGreaterThanOrEqual(n.gap, 5, "[X4-1] \(label): the digits and bars have a clear gap")
                XCTAssertLessThanOrEqual(n.gap, 7, "[X4-1] \(label): the same 6 pt gap Etan accepted (J1)")
                XCTAssertEqual(n.barsY, n.digitsY, accuracy: 0.5, "[X4-3] \(label): the meter sits on the time's centre")
                XCTAssertEqual(n.barsY, VoiceBarNotchContract.topHeight / 2, accuracy: 0.5,
                               "[X4-3] \(label): the meter sits on the row's centre")
            }
        }
    }

    // MARK: 2. Equal wings and no blank outer region

    func testWingsAreEqualAboutTheNotch() {
        for inset in Self.insets {
            for fixture in Fixture.allCases {
                let g = presentation(fixture, inset: inset).geometry
                print("[X4-2] \(fixture.rawValue) inset=\(inset): wings L/R=\(g.leadingWingWidth)/\(g.trailingWingWidth)")
                XCTAssertEqual(g.leadingWingWidth, g.trailingWingWidth, accuracy: 0.5,
                               "[X4-2] \(fixture.rawValue) inset \(inset): equal wings about the notch")
                XCTAssertLessThanOrEqual(g.trailingWingWidth, VoiceBarNotchContract.morphCanvasWingCapacity,
                                         "\(fixture.rawValue): inside the morph canvas")
            }
        }
    }

    func testRightWingRowIsCentredWithNoBlankOuterRegion() throws {
        for inset in Self.insets {
            let recordingWidth = presentation(.recordingPTT, inset: inset).geometry.trailingWingWidth
            let readingWidth = VoiceBarPresentation.readingTrailingWingWidth(visibleCoreOcclusionInset: inset)
            let rows: [(String, Painted, CGFloat)] = [
                ("recording-\(inset)", try paintRightWing(recordingRow(), band: .recording, inset: inset,
                                                           width: recordingWidth, name: "recording-\(inset)"),
                 recordingWidth),
                ("reading-open-\(inset)", try paintRightWing(readingRow(collapsed: false, inset: inset),
                    band: .teleprompter, inset: inset, width: readingWidth, name: "reading-open-\(inset)"),
                 readingWidth),
                ("reading-paused-\(inset)", try paintRightWing(readingRow(collapsed: true, inset: inset),
                    band: .compactStatus, inset: inset, width: readingWidth, name: "reading-paused-\(inset)"),
                 readingWidth),
            ]
            for (label, painted, width) in rows {
                let n = try rowNumbers(painted, wingWidth: width, inset: inset, label: label)
                // The time region is trailing-aligned, so its digits' side bearing adds up to ~2.5 pt on the core side.
                XCTAssertEqual(n.coreSide, n.outerSide, accuracy: 3,
                               "[X4-2] \(label): the row is centred in the visible wing (\(n))")
                XCTAssertGreaterThanOrEqual(n.coreSide, 8, "[X4-2] \(label): 8 pt clear of the physical notch")
            }
        }
    }

    // MARK: 4. The lower row is centred on the drag bar

    func testTeleprompterControlsAreCentredOnTheDragBar() throws {
        let host = mountBar(state(.readingOpen))
        let replay = try XCTUnwrap(tooltipFrame("Replay", in: host), "fixture: Replay is drawn")
        let eye = try XCTUnwrap(tooltipFrame("Hide teleprompter", in: host), "fixture: the eye is drawn")
        let stop = try XCTUnwrap(tooltipFrame("Stop speaking", in: host), "fixture: Stop is drawn")
        let handle = try XCTUnwrap(tooltipFrame("Drag to show more or fewer lines", in: host),
                                   "fixture: the drag bar is drawn")
        let group = (replay.midX + stop.midX) / 2
        print("[X4-4] replay=\(replay.midX) eye=\(eye.midX) stop=\(stop.midX) group=\(group) handle=\(handle.midX)")
        XCTAssertEqual(group, handle.midX, accuracy: 0.5, "[X4-4] Replay, eye and Stop are centred on the drag bar")
        XCTAssertEqual(eye.midX, handle.midX, accuracy: 0.5, "[X4-4] the eye sits over the drag bar")
        XCTAssertEqual(replay.midY, stop.midY, accuracy: 0.5, "one row")
        XCTAssertEqual(eye.midX - replay.midX, stop.midX - eye.midX, accuracy: 0.5, "even pitch")
    }

    // MARK: J2. The recording row never moves while the notch is hovered, pressed or pulled

    func testJ2RecordingRowHoldsStillThroughHoverPressAndDrawerPull() throws {
        for inset in Self.insets {
            func timeX(_ label: String, hovered: Bool = false, history: Bool = false,
                       _ configure: @escaping (BarView) -> BarView = { $0 }) throws -> CGFloat {
                let state = state(.recordingPTT)
                state.recentTranscriptionEntries = [RecentTranscriptionEntry(text: "An earlier take for the drawer.",
                                                                             recordingPath: nil)]
                let resolved = presentation(.recordingPTT, inset: inset)
                let model = VoiceBarNotchPresentationModel()
                model.updateOperationalEnvelope(
                    hasTeleprompter: false, isRecording: true, hasCompactStatus: false,
                    recordingLeadingWingWidth: resolved.geometry.leadingWingWidth,
                    recordingTrailingWingWidth: resolved.geometry.trailingWingWidth,
                    visibleCoreOcclusionInset: inset)
                if hovered { state.setHovering(true); model.setHovered(true) }
                if history { model.setHistoryPanelOpen(true) }
                let host = mountBar(state, model: model, configure)
                let frame = try XCTUnwrap(tooltipFrame(Self.microphone, in: host), "\(label): the time is drawn")
                print("[X4 J2] inset=\(inset) \(label): visual=\(model.presentation.visualState) time.minX=\(frame.minX)")
                return frame.minX
            }
            let rest = try timeX("rest")
            let hover = try timeX("hover", hovered: true)
            let press = try timeX("press (pull begins)", hovered: true, history: true) {
                $0.freezingHistoryMorph(at: 0.04)
            }
            let pull = try timeX("drawer half pulled", hovered: true, history: true) { $0.freezingHistoryMorph(at: 0.5) }
            let open = try timeX("drawer open", history: true) { $0.presentingHistoryForTesting() }
            for (label, x) in [("hover", hover), ("press", press), ("pull", pull), ("open", open)] {
                XCTAssertEqual(x, rest, accuracy: 0.25, "[X4 J2] inset \(inset): the time moved on \(label)")
            }
        }
    }

    // MARK: J4. The mute button names itself

    func testMuteButtonTooltipAndHint() throws {
        let live = try XCTUnwrap(VoiceBarPresentation.recordingPauseControl(mode: .recording, recordingMode: "ptt",
                                                                             isPaused: false))
        let muted = try XCTUnwrap(VoiceBarPresentation.recordingPauseControl(mode: .recording, recordingMode: "ptt",
                                                                              isPaused: true))
        XCTAssertEqual(live.tooltip, "Mute microphone")
        XCTAssertEqual(live.accessibilityHint, "Mute microphone")
        XCTAssertEqual(muted.tooltip, "Unmute microphone")
        XCTAssertEqual(muted.accessibilityHint, "Unmute microphone")
        let state = state(.recordingPTT)
        XCTAssertNotNil(tooltipFrame("Mute microphone", in: mountBar(state)), "[X4 J4] the drawn mute button registers it")
        state.setRecordingPaused(true)
        XCTAssertNotNil(tooltipFrame("Unmute microphone", in: mountBar(state)), "[X4 J4] and its muted form")
    }

    // MARK: The whole bar, painted (hosts whose cacheDisplay paints glass content)

    func testWholeBarPaintsTheGapCentreAndBalance() throws {
        try GlassTextCapability.current.get().requireReadableText()
        for fixture in [Fixture.recordingPTT, .recordingVAD, .readingOpen, .readingPaused] {
            let host = mountBar(state(fixture))
            let p = Painted(bitmap: try EtanQA0510Tests.fixedScaleBitmap(host, scale: Self.scale))
            let s = Self.scale
            let g = presentation(fixture, inset: 0).geometry
            let coreMinX = Int((270 - g.coreWidth / 2) * s), coreMaxX = Int((270 + g.coreWidth / 2) * s)
            let rightEdge = coreMaxX + Int(g.trailingWingWidth * s)
            let right = coreMaxX ..< rightEdge, top = 0 ..< Int(32 * s)
            let digits = try XCTUnwrap(p.ink(x: right, y: top, Self.digit), "\(fixture): the time paints")
            let bars = try XCTUnwrap(p.ink(x: (digits.last + 1) ..< rightEdge, y: top, Self.bar))
            let marks = try XCTUnwrap(p.ink(x: right, y: top, Self.mark))
            let gap = CGFloat(bars.first - digits.last - 1) / s
            let coreSide = CGFloat(marks.first - coreMaxX) / s, outerSide = CGFloat(rightEdge - marks.last - 1) / s
            print("[X4 bar] \(fixture.rawValue): gap=\(gap) digitsY=\(digits.centreY / s) barsY=\(bars.centreY / s) " +
                  "core/outer=\(coreSide)/\(outerSide) left wing=\(CGFloat(coreMinX) / s - (270 - g.coreWidth / 2 - g.leadingWingWidth))")
            XCTAssertGreaterThanOrEqual(gap, 5, "[X4-1] \(fixture)")
            XCTAssertLessThanOrEqual(gap, 7, "[X4-1] \(fixture)")
            XCTAssertEqual(bars.centreY, digits.centreY, accuracy: 1, "[X4-3] \(fixture)")
            XCTAssertEqual(coreSide, outerSide, accuracy: 3, "[X4-2] \(fixture)")
        }
    }
}
