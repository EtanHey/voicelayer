import AppKit
import SwiftUI
@testable import VoiceBarUI
import XCTest

/// 2.3 U2, one test per wing state of the 3-wings mock, run in the test host: the real `BarView` inside the real
/// non-activating `FloatingPillPanel`, offscreen. Events go to the panel with `sendEvent`, so nothing is posted to
/// the system and the pointer never moves. Each test checks that both wings stay at the fixed 73.5 pt (T1/T5: reading has
/// its transport and recording-style wings; a PTT recording's left wing is the three-control 99.5 pt, Stop · Pause · ✕), that the right
/// wing never holds more than two controls, and that the first click on every control dispatches its
/// action once while the panel stays non-key and the frontmost app stays put (PILL1).
///
/// The interaction configurations mirror `AppDelegate.notchInteractionConfiguration` (pinned to the same values
/// in AppLifecycleTests), because that function lives in the app target.
@MainActor
final class WingsU2HostTests: XCTestCase {
    private var windows: [NSWindow] = []

    override func tearDown() {
        MainActor.assumeIsolated {
            for window in windows {
                window.isReleasedWhenClosed = false
                window.orderOut(nil)
                window.close()
            }
            windows.removeAll()
        }
        super.tearDown()
    }

    private final class Spy: BarCommandRouting {
        var calls: [String] = []
        func handlePrimaryTap() { calls.append("primary") }
        func handleCancel() { calls.append("cancel") }
        func handleStop() { calls.append("stop") }
        func handleReplay() { calls.append("replay") }
        func handleRetranscribeHistoryEntry(recordingPath _: String) {}
    }

    private struct Host {
        let host: PillHostingView<BarView>
        let panel: FloatingPillPanel
        let layout: VoiceBarPanelLayout
        let controlRects: [CGRect]
        let router: Spy
    }

    private final class Callbacks {
        var calls: [String] = []
    }

    // MARK: - States

    func testIdleLauncherIsMicAndChevronLeftHistoryAndSettingsRight() {
        let state = makeState()
        state.isHovering = true
        let callbacks = Callbacks()
        let host = makeHost(
            state: state,
            hovered: true,
            configuration: VoiceBarNotchInteractionConfiguration(leadingControlCount: 2, trailingControlCountFromCore: 2),
            callbacks: callbacks
        )
        XCTAssertEqual(host.layout.presentation.visualState, .hoverLauncher)
        assertFixedWings(host, leading: 2, trailing: 2)

        // Hit rects run from the core outward: the chevron sits beside the core, the mic outside it.
        firstClick(host, control: 1)
        XCTAssertEqual(host.router.calls, ["primary"], "mic")
        firstClick(host, control: 0)
        drainMain()
        XCTAssertEqual(callbacks.calls, ["microphones"], "chevron opens the microphone list")
        firstClick(host, control: 3)
        XCTAssertEqual(callbacks.calls, ["microphones", "settings"], "gear without a setup problem")
        firstClick(host, control: 2)
        drainMain()
        XCTAssertTrue(hasTooltip(host, "Close history"), "History opens from the right wing")
        XCTAssertEqual(host.router.calls, ["primary"])
    }

    func testSetupErrorBadgesTheGearAndItOpensTheSetupSpot() {
        let state = makeState()
        state.isHovering = true
        state.setSetupMissingPermissions([.accessibility])
        let callbacks = Callbacks()
        let host = makeHost(
            state: state,
            hovered: true,
            configuration: VoiceBarNotchInteractionConfiguration(leadingControlCount: 2, trailingControlCountFromCore: 2),
            callbacks: callbacks
        )
        assertFixedWings(host, leading: 2, trailing: 2)
        firstClick(host, control: 3)
        XCTAssertEqual(callbacks.calls, ["setup"], "the badged gear goes to the setup spot, not plain Settings")
        XCTAssertEqual(
            VoiceBarSetupAttention.tooltip(missing: [.accessibility]),
            "Accessibility is off, so F5 can’t start dictation. Click to fix."
        )
        XCTAssertEqual(
            VoiceBarSetupAttention.tooltip(missing: [.accessibility, .inputMonitoring]),
            "Accessibility and Input Monitoring are off, so F5 can’t start dictation. Click to fix."
        )
        XCTAssertEqual(
            VoiceBarSetupAttention.tooltip(missing: [.accessibility, .inputMonitoring, .microphone]),
            "Accessibility, Input Monitoring and Microphone access are off, so F5 can’t start dictation. Click to fix."
        )
        XCTAssertEqual(VoiceBarSetupAttention.tooltip(missing: []), "Settings")
        XCTAssertEqual(VoiceBarSetupAttention.accessibilityLabel(missing: []), "Settings")
        XCTAssertTrue(VoiceBarSetupAttention.accessibilityLabel(missing: [.accessibility]).hasPrefix("Settings. "))
    }

    func testRecordingIsStopPauseAndCancelLeftLevelBarsRight() {
        let state = makeState()
        var sent: [[String: Any]] = []
        state.sendCommand = { sent.append($0) }
        state.handleEvent(["type": "state", "state": "recording", "mode": "ptt"])
        // Mirrors AppDelegate's PTT recording configuration (AppLifecycleTests): Stop · Pause · ✕.
        let host = makeHost(
            state: state,
            configuration: VoiceBarNotchInteractionConfiguration(leadingControlCount: 3)
        )
        XCTAssertEqual(host.layout.presentation.visualState, .recording)
        // 2.3 N1: the right wing hugs the time, the microphone and the level meter; it holds no control. Recording
        // pause: Pause takes the third left-wing slot, as Lock does on a VAD take, so the left wing is the
        // three-control width.
        assertFixedWings(host, leading: 3, trailing: 0,
                         trailingWidth: VoiceBarNotchContract.recordingTrailingWingWidth,
                         leadingWidth: VoiceBarNotchContract.recordingLeadingWingWidthWithHoldControl)
        // From the core outward: Cancel, then Pause, then Stop.
        firstClick(host, control: 0)
        XCTAssertEqual(host.router.calls, ["cancel"])
        firstClick(host, control: 1)
        drainMain()
        XCTAssertEqual(host.router.calls, ["cancel"], "Pause is not a router command")
        XCTAssertEqual(sent.last?["cmd"] as? String, "set_recording_pause")
        XCTAssertEqual(sent.last?["paused"] as? Bool, true)
        firstClick(host, control: 2)
        XCTAssertEqual(host.router.calls, ["cancel", "stop"], "Stop stays reachable beside Pause")
    }

    func testTranscribingKeepsHistoryAndSettingsLiveWithoutAThirdControl() {
        let state = makeState()
        state.handleEvent(["type": "state", "state": "transcribing"])
        let callbacks = Callbacks()
        let host = makeHost(
            state: state,
            configuration: VoiceBarNotchInteractionConfiguration(trailingControlCountFromCore: 2),
            callbacks: callbacks
        )
        XCTAssertEqual(host.layout.presentation.visualState, .compactStatus)
        assertFixedWings(host, leading: 0, trailing: 2)
        firstClick(host, control: 1)
        XCTAssertEqual(callbacks.calls, ["settings"])
        firstClick(host, control: 0)
        drainMain()
        XCTAssertTrue(hasTooltip(host, "Close history"))
        XCTAssertEqual(host.router.calls, [], "the spinner is not a control and nothing cancels the take")
    }

    /// T1/T6: speed, Back, Pause, Forward on the left (Pause is the second from the core). T5/T7: time, meter and
    /// Stop (in the outer region) on the right; a hidden read's eye sits one pitch inside Stop.
    func testReadingAloudCollapsedIsPauseLeftShowAndStopRight() {
        let state = makeSpeakingState()
        state.dismissTeleprompter()
        var sent: [String] = []
        state.sendCommand = { if let cmd = $0["cmd"] as? String { sent.append(cmd) } }
        let host = makeHost(state: state, configuration: BarViewClickabilityTests.readingConfiguration(trailingFromOuter: 2))
        XCTAssertEqual(host.layout.presentation.visualState, .compactStatus)
        assertFixedWings(host, leading: 4, trailing: 2, trailingWidth: VoiceBarNotchContract.recordingTrailingWingWidth,
                         leadingWidth: VoiceBarPresentation.readingTransportWingWidth)
        assertDrawnControlsSitOnTheirHitRects(host, ["Next read", "Pause speech", "Previous read", "Playback speed",
                                                     "Stop speaking", "Show teleprompter"])
        firstClick(host, control: BarViewClickabilityTests.pauseIndex)
        XCTAssertEqual(sent, ["pause"])
        // From the outer edge inward: Stop, then Show teleprompter.
        firstClick(host, control: BarViewClickabilityTests.compactStopIndex)
        XCTAssertEqual(host.router.calls, ["stop"])
        XCTAssertTrue(state.isTeleprompterDismissed)
        firstClick(host, control: BarViewClickabilityTests.compactStopIndex + 1)
        XCTAssertFalse(state.isTeleprompterDismissed, "the eye shows the teleprompter again")
    }

    func testReadingAloudPausedIsPlayLeftTimeAndStopRight() {
        let state = makeSpeakingState()
        state.handleEvent(["type": "playback_state", "state": "paused", "playback_id": "p-1", "generation": 2,
                           "offset_ms": 900, "chunk_offset_ms": 900])
        state.dismissTeleprompter()
        var sent: [String] = []
        state.sendCommand = { if let cmd = $0["cmd"] as? String { sent.append(cmd) } }
        let host = makeHost(state: state, configuration: BarViewClickabilityTests.readingConfiguration(trailingFromOuter: 1))
        assertFixedWings(host, leading: 4, trailing: 1, trailingWidth: VoiceBarNotchContract.recordingTrailingWingWidth,
                         leadingWidth: VoiceBarPresentation.readingTransportWingWidth)
        assertDrawnControlsSitOnTheirHitRects(host, ["Next read", "Resume speech", "Previous read", "Playback speed",
                                                     "Stop speaking"])
        firstClick(host, control: BarViewClickabilityTests.pauseIndex)
        XCTAssertEqual(sent, ["resume"])
        firstClick(host, control: BarViewClickabilityTests.compactStopIndex)
        XCTAssertEqual(host.router.calls, ["stop"])
    }

    /// 2.3 U5: with the teleprompter open the right wing shows the reading time and the live Stop (SPEC wing
    /// states); the lower row has no Stop. A click into a mounted teleprompter makes the production panel key
    /// (becomesKeyOnlyIfNeeded, unchanged), which the offscreen isolation forbids, so Pause and Stop prove here that
    /// their hit targets accept the first mouse-down; the dispatch is proved in the plain window below.
    /// T5/T7 (Etan QA 2026-11-09, reversing 2.3 U5): with the teleprompter open the right wing is time + meter only,
    /// as when recording, and the live red Stop is the eye row's terminal control.
    func testReadingAloudWithTheTeleprompterShowsTheTimeAndTheStopInTheEyeRow() {
        let state = makeSpeakingState()
        let group = VoiceBarPresentation.teleprompterLowerGroupCount(canReplay: state.canReplay)
        let host = makeHost(
            state: state,
            configuration: BarViewClickabilityTests.readingConfiguration(lowerGroup: group, lowerSurfaceIsInteractive: true)
        )
        XCTAssertEqual(host.layout.presentation.visualState, .teleprompter)
        let geometry = host.layout.presentation.geometry
        XCTAssertEqual(geometry.leadingWingWidth, VoiceBarPresentation.readingTransportWingWidth, accuracy: 0.001)
        XCTAssertEqual(geometry.trailingWingWidth, VoiceBarNotchContract.recordingTrailingWingWidth, accuracy: 0.001)
        let pause = host.controlRects[BarViewClickabilityTests.pauseIndex]
        let point = NSPoint(x: pause.midX, y: pause.midY)
        guard let target = host.host.hitTest(point), let down = event(.leftMouseDown, at: point, in: host.panel) else {
            return XCTFail("No Pause hit target")
        }
        XCTAssertTrue(target.acceptsFirstMouse(for: down))
        // The rects end with the group, then the terminal slot, then the interactive body.
        let stopRect = host.controlRects[host.controlRects.count - 2]
        let stopSlot = NSPoint(x: stopRect.midX, y: stopRect.midY)
        XCTAssertLessThan(stopSlot.y, pause.minY, "Stop sits below the top row, in the eye row")
        XCTAssertTrue(host.layout.containsInteractiveContent(stopSlot), "the eye-row Stop's slot is live")
        guard let stopTarget = host.host.hitTest(stopSlot), let stopDown = event(.leftMouseDown, at: stopSlot, in: host.panel)
        else { return XCTFail("No Stop hit target") }
        assertDrawnControlsSitOnTheirHitRects(host, ["Next read", "Pause speech", "Previous read", "Playback speed"],
                                              leading: true)
        assertDrawnControlsSitOnTheirHitRects(host, ["Hide teleprompter", "Stop speaking"], at: [
            host.controlRects[host.controlRects.count - 3], stopRect])
        XCTAssertTrue(stopTarget.acceptsFirstMouse(for: stopDown))
    }

    /// 2.3 U5 moved the live Stop into the wing (U2's handoff note). Clicked in a plain non-key window, so key-ness
    /// cannot mask the dispatch: the first click on the rendered wing Stop stops the read with the teleprompter open.
    /// (R0856-10's key-focus trap was `.focusable(true)` on the Stop; the wing Stop is not focusable.)
    /// T7: the first click on the rendered eye-row Stop stops the read with the teleprompter open.
    func testTheEyeRowStopStopsTheReadWhileTheTeleprompterIsOpen() {
        let state = makeSpeakingState()
        let router = Spy()
        let bar = NSHostingView(rootView: BarView(state: state, commandRouter: router,
                                                  onOpenSettings: {}, onOpenHistory: {}))
        bar.frame = NSRect(origin: .zero, size: bar.fittingSize)
        let window = NSWindow(contentRect: bar.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = bar
        window.setFrameOrigin(NSPoint(x: -100_000, y: -100_000))
        window.orderBack(nil)
        windows.append(window)
        bar.layoutSubtreeIfNeeded()
        let presentation = VoiceBarPresentation.notchPresentation(from: VoiceBarNotchOperationalInput(
            mode: .speaking, hasTeleprompterText: true, readQueueLeadingSlotCount: 1))
        XCTAssertEqual(presentation.visualState, .teleprompter)
        let geometry = presentation.geometry
        // The eye row's terminal slot: one pitch right of the centred Replay + eye group, 20 pt above the bottom.
        let originX = (bar.bounds.width - geometry.totalWidth) / 2
        let stopMidX = originX + geometry.totalWidth / 2 + VoiceBarPresentation.teleprompterTerminalOffset(
            groupControlCount: VoiceBarPresentation.teleprompterLowerGroupCount(canReplay: state.canReplay))
        let eyeRowMidY = bar.bounds.minY + VoiceBarPresentation.teleprompterLowerControlBottomInset
            + VoiceBarNotchContract.material.compactControlSize / 2
        for dx in stride(from: CGFloat(-6), through: 6, by: 3) {
            let point = NSPoint(x: stopMidX + dx, y: eyeRowMidY)
            guard let down = event(.leftMouseDown, at: point, in: window),
                  let up = event(.leftMouseUp, at: point, in: window) else { return XCTFail("events") }
            window.sendEvent(down)
            window.sendEvent(up)
        }
        XCTAssertFalse(router.calls.isEmpty, "the eye-row Stop dispatches on its first click")
        XCTAssertEqual(Set(router.calls), ["stop"])
    }

    // MARK: - Helpers

    private func makeState() -> VoiceState {
        let state = VoiceState()
        state.isConnected = true
        state.hotkeyEnabled = true
        state.isCollapsed = false
        return state
    }

    private func makeSpeakingState() -> VoiceState {
        let state = makeState()
        state.handleEvent(["type": "state", "state": "speaking", "text": "A synthetic read for the wing tests.",
                           "request_id": "r-A", "playback_id": "p-1", "generation": 1])
        return state
    }

    private func makeHost(
        state: VoiceState,
        hovered: Bool = false,
        configuration: VoiceBarNotchInteractionConfiguration,
        callbacks: Callbacks = Callbacks()
    ) -> Host {
        let presentation = VoiceBarPresentation.notchPresentation(
            from: VoiceBarNotchOperationalInput(
                mode: state.mode,
                showsRecordingHold: state.mode == .recording && state.recordingMode == "vad",
                showsRecordingPause: state.mode == .recording && state.recordingMode == "ptt",
                hasTeleprompterText: state.teleprompterText != nil,
                isTeleprompterDismissed: state.isTeleprompterDismissed,
                isTeleprompterReadback: state.isTeleprompterReadback,
                isPlaybackPaused: state.isPlaybackPaused,
                readQueueLeadingSlotCount: VoiceBarPresentation.playbackLeadingSlotCount(for: state),
                isHovered: hovered,
                isCollapsed: state.isCollapsed
            )
        )
        let canvas = VoiceBarNotchMorphCanvasLayout.resolve(for: presentation)
        let layout = VoiceBarPanelLayout.make(
            presentation: presentation,
            interactionConfiguration: configuration,
            canvasGeometry: canvas.canvasGeometry
        )
        let router = Spy()
        let host = PillHostingView(
            rootView: BarView(
                state: state,
                commandRouter: router,
                onOpenSettings: { callbacks.calls.append("settings") },
                onOpenHistory: { callbacks.calls.append("history-window") },
                includesPanelOutsets: true,
                onOpenMicrophonePicker: { callbacks.calls.append("microphones") },
                onOpenSetupSettings: { callbacks.calls.append("setup") }
            )
        )
        host.frame = NSRect(origin: .zero, size: layout.panelSize)
        host.activeHitTestProvider = { layout.containsInteractiveContent($0) }
        host.renderedSurfaceHitTestProvider = { layout.containsVisibleSurface($0) }
        let panel = FloatingPillPanel(content: host)
        panel.activeHitTestProvider = { layout.containsInteractiveContent($0) }
        panel.contextMenuHitTestProvider = { layout.containsVisibleSurface($0) }
        panel.isPillDragEnabled = false
        panel.setFrameOrigin(NSPoint(x: -100_000, y: -100_000))
        panel.orderBack(nil)
        windows.append(panel)
        host.layoutSubtreeIfNeeded()
        let region = VoiceBarNotchHitRegion(geometry: presentation.geometry, configuration: configuration)
        let rects = region.rects.map {
            $0.offsetBy(dx: layout.visibleContentRect.minX, dy: layout.visibleContentRect.minY)
        }
        return Host(host: host, panel: panel, layout: layout, controlRects: rects, router: router)
    }

    /// Both wings are the fixed width, every control sits inside its wing, and the right wing has at most two.
    /// The drawn control (its native tooltip view) sits exactly on the hit rect the panel registers for it.
    private func assertDrawnControlsSitOnTheirHitRects(_ host: Host, _ labels: [String], leading: Bool = false,
                                                       at rects: [CGRect]? = nil,
                                                       file: StaticString = #filePath, line: UInt = #line) {
        func all(_ view: NSView) -> [NSView] { view.subviews + view.subviews.flatMap(all) }
        let targets = rects ?? Array(host.controlRects.prefix(labels.count))
        for (label, rect) in zip(labels, targets) {
            guard let drawn = all(host.host).first(where: { $0.toolTip == label && !$0.visibleRect.isEmpty }) else {
                XCTFail("\(label) is not drawn", file: file, line: line); continue
            }
            let frame = drawn.convert(drawn.bounds, to: nil)
            XCTAssertEqual(frame.minX, rect.minX, accuracy: 0.5, "\(label) x", file: file, line: line)
            XCTAssertEqual(frame.width, rect.width, accuracy: 0.5, "\(label) width", file: file, line: line)
            XCTAssertEqual(frame.midY, rect.midY, accuracy: 0.5, "\(label) y", file: file, line: line)
        }
    }

    private func assertFixedWings(
        _ host: Host,
        leading: Int,
        trailing: Int,
        trailingWidth: CGFloat = VoiceBarNotchContract.fixedWingWidth,
        leadingWidth: CGFloat = VoiceBarNotchContract.fixedWingWidth,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let geometry = host.layout.presentation.geometry
        let fixed = leadingWidth
        XCTAssertEqual(geometry.leadingWingWidth, fixed, accuracy: 0.001, "left wing", file: file, line: line)
        XCTAssertEqual(geometry.trailingWingWidth, trailingWidth, accuracy: 0.001, "right wing", file: file, line: line)
        let origin = host.layout.visibleContentRect.origin
        let left = CGRect(x: origin.x + geometry.coreOriginX - fixed, y: -1_000, width: fixed, height: 2_000)
        let right = CGRect(x: origin.x + geometry.coreOriginX + geometry.coreWidth, y: -1_000, width: trailingWidth,
                           height: 2_000)
        let inLeft = host.controlRects.filter { left.contains($0) }.count
        let inRight = host.controlRects.filter { right.contains($0) }.count
        XCTAssertEqual(inLeft, leading, "left-wing controls", file: file, line: line)
        XCTAssertEqual(inRight, trailing, "right-wing controls", file: file, line: line)
        XCTAssertLessThanOrEqual(inRight, 2, "never a third right-wing control", file: file, line: line)
        XCTAssertEqual(host.controlRects.count, leading + trailing, "every control is in a wing", file: file, line: line)
    }

    /// PILL1: the hit view at the control accepts the first mouse-down on the non-key panel; the click leaves the
    /// panel non-key and the frontmost app unchanged.
    private func firstClick(_ host: Host, control index: Int, file: StaticString = #filePath, line: UInt = #line) {
        guard index < host.controlRects.count else {
            return XCTFail("No control \(index)", file: file, line: line)
        }
        let rect = host.controlRects[index]
        let point = NSPoint(x: rect.midX, y: rect.midY)
        let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
        XCTAssertFalse(host.panel.isKeyWindow, "not key before the click", file: file, line: line)
        guard let target = host.host.hitTest(point),
              let down = event(.leftMouseDown, at: point, in: host.panel),
              let up = event(.leftMouseUp, at: point, in: host.panel) else {
            return XCTFail("No hit target at \(point)", file: file, line: line)
        }
        XCTAssertTrue(target.acceptsFirstMouse(for: down), "\(type(of: target)) must accept the first mouse-down",
                      file: file, line: line)
        host.panel.sendEvent(down)
        host.panel.sendEvent(up)
        XCTAssertFalse(host.panel.isKeyWindow, "a first click does not make the panel key", file: file, line: line)
        XCTAssertEqual(NSWorkspace.shared.frontmostApplication?.processIdentifier, frontmost,
                       "a first click leaves the frontmost app unchanged", file: file, line: line)
    }

    private func event(_ type: NSEvent.EventType, at point: NSPoint, in window: NSWindow) -> NSEvent? {
        NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                           timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                           context: nil, eventNumber: 1, clickCount: 1, pressure: 0)
    }

    /// The History button's tooltip names its action: "History", then "Close history" once the panel is open.
    private func hasTooltip(_ host: Host, _ text: String) -> Bool {
        host.host.layoutSubtreeIfNeeded()
        func walk(_ view: NSView) -> Bool {
            view.toolTip == text || view.subviews.contains(where: walk)
        }
        return walk(host.host)
    }

    private func drainMain() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }
}
