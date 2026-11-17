import AppKit
import OffscreenTestSupport
import SwiftUI
@testable import VoiceBarUI
import XCTest

/// Owner r2 (2.4.3), one rule for the left side: in every state that shows a left wing, the innermost left control's
/// INK sits 16.5 pt from the notch's visible edge, as the right side's innermost ink does (16.5 to 17.5 pt) and as the
/// recording X already did. Before this the X sat at 16.5 pt and the microphone chevron at 20 pt, so a ruler laid over
/// the recording and transcribing bands showed two different left gaps.
///
/// Each number is measured, not derived: the control's slot is where the real BarView lays it out (its tooltip view,
/// which is the 20 pt plate frame), and the glyph's core-side bearing is read from that control rendered alone at a
/// fixed 2x. This Mac's offscreen capture paints the notch glass dim, so the whole band cannot be read off one bitmap;
/// the two halves are each real. The notch's visible edge is the calibrated core edge (the M1's 2x stills show the
/// black housing ending exactly there); recording is measured at the real hardware notch's 8.5 pt occlusion.
@MainActor
final class NotchLeftInkRuleTests: XCTestCase {
    private final class Router: BarCommandRouting {
        func handlePrimaryTap() {}
        func handleCancel() {}
        func handleStop() {}
        func handleReplay() {}
        func handleRetranscribeHistoryEntry(recordingPath: String) {}
    }

    static let rule: CGFloat = 16.5
    static let tolerance: CGFloat = 0.5
    /// The hardware notch's measured occlusion (the calibration inset), where the recording wing was approved.
    static let hardwareOcclusion: CGFloat = VoiceBarNotchContract.hardwareHorizontalCalibrationInset
    private var windows: [NSWindow] = []

    override func tearDown() {
        for window in windows { window.contentView = nil; window.close() }
        windows.removeAll()
        super.tearDown()
    }

    struct Fixture {
        let name: String
        /// The innermost control's tooltip and its SF Symbol.
        let tooltip: String
        let icon: String
        var occlusion: CGFloat = 0
        var opensHistory = false
        let configure: (VoiceState) -> Void
    }

    static let fixtures: [Fixture] = [
        Fixture(name: "idle hovered (launcher)", tooltip: "Choose microphone", icon: "chevron.down") {
            $0.isHovering = true
        },
        Fixture(name: "History drawer", tooltip: "Choose microphone", icon: "chevron.down", opensHistory: true) {
            $0.isHovering = true
        },
        Fixture(name: "setup error badge", tooltip: "Choose microphone", icon: "chevron.down") {
            $0.isHovering = true
            $0.setSetupMissingPermissions([.accessibility])
        },
        Fixture(name: "transcribing", tooltip: "Choose microphone", icon: "chevron.down") {
            $0.handleEvent(["type": "state", "state": "transcribing"])
        },
        Fixture(name: "compact status (Typed)", tooltip: "Choose microphone", icon: "chevron.down") {
            $0.confirmationText = "Typed"
        },
        Fixture(name: "recording", tooltip: "Cancel recording", icon: "xmark", occlusion: hardwareOcclusion) {
            $0.handleEvent(["type": "state", "state": "recording", "mode": "ptt"])
            $0.handleEvent(["type": "audio_level", "rms": 0.0])
        },
        Fixture(name: "recording with the lock", tooltip: "Lock recording", icon: "lock.fill",
                occlusion: hardwareOcclusion) {
            $0.handleEvent(["type": "state", "state": "recording", "mode": "vad"])
            $0.handleEvent(["type": "audio_level", "rms": 0.0])
        },
        Fixture(name: "recording with an earlier take's spinner", tooltip: "Cancel recording", icon: "xmark",
                occlusion: hardwareOcclusion) {
            $0.handleEvent(["type": "state", "state": "recording", "source": "recording", "mic_take_id": "B", "mode": "ptt",
                            "recording_jobs": [["take_id": "A", "kind": "live", "phase": "processing"],
                                               ["take_id": "B", "kind": "live", "phase": "capturing"]]])
            $0.handleEvent(["type": "audio_level", "rms": 0.0])
        },
        Fixture(name: "reading aloud", tooltip: "Next read", icon: "forward.end.fill") {
            $0.handleEvent(["type": "state", "state": "speaking", "text": "A synthetic sentence to read.",
                            "request_id": "ink-read", "playback_id": "ink-player", "generation": 1])
        },
        Fixture(name: "compact status (error)", tooltip: "Synthetic failure", icon: "exclamationmark.triangle.fill") {
            $0.handleEvent(["type": "error", "message": "Synthetic failure", "recoverable": true])
        },
    ]

    func testTheInnermostLeftInkSitsOnTheRuleInEveryState() throws {
        var rows: [String] = []
        for fixture in Self.fixtures {
            let measured = try innerInkGap(fixture)
            rows.append(String(format: "%@: %.2f pt (slot %.2f + bearing %.2f)", fixture.name, measured.gap,
                               measured.slotGap, measured.bearing))
            XCTAssertEqual(measured.gap, Self.rule, accuracy: Self.tolerance,
                           "\(fixture.name): the innermost left ink sits \(measured.gap) pt from the notch")
        }
        print("LEFT_INK_RULE\n" + rows.joined(separator: "\n"))
    }

    /// CI r3: the error glyph's row moved onto the rule (its ink sat at 17.0 pt on the M1, 17.5 on GitHub's runner);
    /// its hit slot follows the painted one. The resident app's error configuration (`VoiceBarApp`'s one leading
    /// control at the default inset) goes through the panel layout's `followingLeadingRow`, as every panel does.
    func testTheErrorGlyphsHitSlotFollowsItsPaintedSlot() throws {
        let fixture = try XCTUnwrap(Self.fixtures.first { $0.name == "compact status (error)" })
        let painted = try innerInkGap(fixture)
        let presentation = VoiceBarPresentation.notchPresentation(from: VoiceBarNotchOperationalInput(
            mode: .error, statusText: VoiceBarPresentation.errorStatusText("Synthetic failure")))
        XCTAssertEqual(presentation.visualState, .compactStatus)
        XCTAssertEqual(presentation.geometry.leadingWingWidth, VoiceBarNotchContract.errorStatusLeadingWingWidth)
        let resident = VoiceBarNotchInteractionConfiguration(leadingControlCount: 1, trailingControlCountFromOuter: 1,
                                                             trailingOuterInset: WaveformLayout.outerInset)
        let region = VoiceBarNotchHitRegion(geometry: presentation.geometry,
                                            configuration: resident.followingLeadingRow(of: presentation))
        let geometry = presentation.geometry
        let leading = try XCTUnwrap(region.rects.filter { $0.maxX <= geometry.coreOriginX + 0.01 }.max { $0.maxX < $1.maxX },
                                    "the error glyph has a hit slot")
        XCTAssertEqual(geometry.coreOriginX - leading.maxX, painted.slotGap, accuracy: 0.01,
                       "the error glyph's hit slot sits where its plate is painted")
        XCTAssertEqual(geometry.coreOriginX - leading.maxX, VoiceBarNotchContract.errorStatusLeadingContentInset)
    }

    /// Review r1 (lead decision): reading aloud while an Ask answer is still transcribing with nothing queued puts the
    /// spinner in Forward's slot. Its ink meets the rule too (it sat at 15.0 pt); the slot and every hit rect stay.
    func testTheSpinnerInForwardsSlotSitsOnTheRule() throws {
        let fixture = Fixture(name: "reading aloud, Ask answer transcribing", tooltip: "Pause speech", icon: "pause.fill") {
            var speaking: [String: Any] = ["type": "state", "state": "speaking", "text": "A synthetic sentence to read.",
                                           "request_id": "ink-read", "playback_id": "ink-player", "generation": 1]
            speaking["utteranceId"] = "ink-read"
            $0.handleEvent(speaking)
            $0.handleEvent(["type": "read_processing", "utterance_id": "ink-read", "active": true])
        }
        let state = VoiceState(recentTranscriptionsLoader: { [] }, recentTranscriptionsSaver: { _ in },
                               recentTranscriptionEntriesLoader: { [] }, recentTranscriptionEntriesSaver: { _ in },
                               playbackAmplitudeClock: { 100 }, keepsExpandedInDevState: false)
        state.sendCommand = { _ in }
        state.isConnected = true
        state.isCollapsed = false
        fixture.configure(state)
        XCTAssertTrue(VoiceBarPresentation.readingForwardControl(for: state).showsProcessingSpinner,
                      "fixture: the spinner takes Forward's slot")
        let host = mountBar(state, model: nil, opensHistory: false)
        let coreMinX = 270 - VoiceBarNotchContract.coreWidth / 2
        let left = leftControls(in: host, coreMinX: coreMinX)
        let innermost = try XCTUnwrap(left.max { $0.frame.maxX < $1.frame.maxX })
        XCTAssertEqual(innermost.tooltip, fixture.tooltip, "the spinner has no control of its own; Pause is next out")
        let material = VoiceBarNotchContract.material
        // Forward's slot, one pitch inside Pause.
        let slotGap = coreMinX - (innermost.frame.maxX + material.compactControlSpacing + material.compactControlSize)
        let bitmap = try NotchDesignPixels.render(
            VoiceBarReadingForwardSpinner(appearance: .dark).environment(\.visualRenderTime, 1.25)
                .frame(width: 20, height: 20).padding(10).background(.black), size: CGSize(width: 40, height: 40))
        var inkMaxX: CGFloat?
        for y in 20 ..< 60 { for x in 20 ..< 60 {
            guard let c = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                  max(c.redComponent, c.greenComponent, c.blueComponent) > 0.12 else { continue }
            inkMaxX = max(inkMaxX ?? 0, CGFloat(x + 1) / 2)
        } }
        let bearing = 30 - (try XCTUnwrap(inkMaxX, "the spinner drew no ink"))
        let gap = slotGap + bearing
        print(String(format: "LEFT_INK_RULE spinner: %.2f pt (slot %.2f + bearing %.2f)", gap, slotGap, bearing))
        XCTAssertEqual(gap, Self.rule, accuracy: Self.tolerance, "the spinner's innermost ink sits \(gap) pt from the notch")
    }

    // MARK: - Measuring

    struct Measured { let gap: CGFloat; let slotGap: CGFloat; let bearing: CGFloat }

    private func innerInkGap(_ fixture: Fixture) throws -> Measured {
        let state = VoiceState(recentTranscriptionsLoader: { [] }, recentTranscriptionsSaver: { _ in },
                               recentTranscriptionEntriesLoader: { [] }, recentTranscriptionEntriesSaver: { _ in },
                               playbackAmplitudeClock: { 100 }, keepsExpandedInDevState: false)
        state.recordingTimingClock = { 100 }
        state.sendCommand = { _ in }
        state.isConnected = true
        state.isCollapsed = false
        state.recentTranscriptionEntries = [RecentTranscriptionEntry(text: "An earlier take.", recordingPath: nil)]
        fixture.configure(state)
        var model: VoiceBarNotchPresentationModel?
        if fixture.occlusion > 0 {
            let resolved = VoiceBarPresentation.notchPresentation(from: VoiceBarNotchOperationalInput(
                mode: .recording, showsRecordingHold: state.recordingMode == "vad",
                showsRecordingPause: state.recordingMode == "ptt", visibleCoreOcclusionInset: fixture.occlusion,
                showsEarlierTakeProcessing: VoiceBarPresentation.showsEarlierTakeProcessing(for: state)))
            let recording = VoiceBarNotchPresentationModel()
            recording.updateOperationalEnvelope(
                hasTeleprompter: false, isRecording: true, hasCompactStatus: false,
                recordingLeadingWingWidth: resolved.geometry.leadingWingWidth,
                recordingTrailingWingWidth: resolved.geometry.trailingWingWidth,
                visibleCoreOcclusionInset: fixture.occlusion)
            model = recording
        }
        let host = mountBar(state, model: model, opensHistory: fixture.opensHistory)
        let coreMinX = 270 - VoiceBarNotchContract.coreWidth / 2
        let left = leftControls(in: host, coreMinX: coreMinX)
        let innermost = try XCTUnwrap(left.max { $0.frame.maxX < $1.frame.maxX },
                                      "\(fixture.name): no left control is drawn")
        XCTAssertEqual(innermost.tooltip, fixture.tooltip,
                       "\(fixture.name): the innermost left control is \(innermost.tooltip) (all: \(left.map(\.tooltip)))")
        XCTAssertEqual(innermost.frame.width, VoiceBarNotchContract.material.compactControlSize, accuracy: 0.01,
                       "\(fixture.name): the tooltip view is the 20 pt plate")
        let bearing = try Self.coreSideBearing(fixture.icon)
        let slotGap = coreMinX - innermost.frame.maxX
        return Measured(gap: slotGap + bearing, slotGap: slotGap, bearing: bearing)
    }

    /// The glyph's ink edge on its core side, inside its 20 pt plate, rendered alone at 2x.
    static func coreSideBearing(_ icon: String) throws -> CGFloat {
        let button = VoiceBarPillControlButton(icon: icon, optics: .resolve(for: icon), foreground: .white,
                                               isSelected: false, isDestructive: false, accessibilityLabel: icon,
                                               accessibilityHint: "", action: {})
        let bitmap = try NotchDesignPixels.render(button.frame(width: 20, height: 20).padding(10).background(.black),
                                                 size: CGSize(width: 40, height: 40))
        let ink = try XCTUnwrap(NotchDesignPixels.inkBounds(bitmap, rect: CGRect(x: 10, y: 10, width: 20, height: 20)),
                                "\(icon) drew no ink")
        return 30 - ink.maxX
    }

    private func leftControls(in host: NSView, coreMinX: CGFloat) -> [(tooltip: String, frame: CGRect)] {
        func all(_ view: NSView) -> [NSView] { view.subviews + view.subviews.flatMap(all) }
        // The band's row: the top 32 pt of the canvas (a lower drawer's rows start below it).
        let bandMinY = host.bounds.height - VoiceBarNotchContract.topHeight - 4
        return all(host).compactMap { view in
            guard let tooltip = view.toolTip, !view.visibleRect.isEmpty else { return nil }
            let frame = view.convert(view.bounds, to: nil)
            // The band's row only (window points, y up), left of the core.
            guard frame.midY > bandMinY, frame.maxX <= coreMinX + 0.5 else { return nil }
            return (tooltip, frame)
        }
    }

    private final class ReferenceWindow: NSWindow {
        override var backingScaleFactor: CGFloat { 2 }
    }

    /// The whole BarView on a 540 pt canvas with the core centred at x = 270 (as `WingLayoutX4Tests` mounts it).
    private func mountBar(_ state: VoiceState, model: VoiceBarNotchPresentationModel?, opensHistory: Bool)
        -> NSHostingView<AnyView> {
        let old = NSApplication.shared.appearance
        NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
        defer { NSApplication.shared.appearance = old }
        var bar = BarView(state: state, commandRouter: Router(), onOpenSettings: {}, onOpenHistory: {},
                          presentationModel: model, includesPanelOutsets: true)
        if opensHistory {
            model?.setHistoryPanelOpen(true)
            bar = bar.presentingHistoryForTesting()
        }
        let height: CGFloat = 520
        let host = NSHostingView(rootView: AnyView(ZStack(alignment: .top) {
            Color(red: 0.16, green: 0.17, blue: 0.19)
            bar.fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: 540, height: height, alignment: .top)
        .environment(\.colorScheme, .dark)
        .environment(\.displayScale, 2)
        .environment(\.visualRenderTime, 0)
        .transaction { $0.animation = nil; $0.disablesAnimations = true }))
        host.frame = NSRect(x: 0, y: 0, width: 540, height: height)
        host.appearance = NSAppearance(named: .darkAqua)
        let window = ReferenceWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = host.appearance
        window.contentView = host
        windows.append(window)
        VLOrderTestWindow(window)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        host.layoutSubtreeIfNeeded()
        return host
    }
}
