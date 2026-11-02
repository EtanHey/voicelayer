import AppKit
import SwiftUI
@testable import VoiceBarUI
import XCTest

@MainActor
final class BarViewClickabilityTests: XCTestCase {
    func testQueuedSpeechKeepsTeleprompterMountedInTheLowerSurface() throws {
        let source = try barViewSource()
        let start = try XCTUnwrap(source.range(of: "private var notchLowerContent"))
        let end = try XCTUnwrap(source.range(of: "private var notchTeleprompterTimeline"))
        let lowerContent = source[start.lowerBound ..< end.lowerBound]

        XCTAssertTrue(lowerContent.contains("notchTeleprompterTimeline"))
        XCTAssertFalse(lowerContent.contains("queueVisualization"))
        XCTAssertFalse(lowerContent.contains("state.queueItems.count > 1"))
    }

    private var windows: [NSWindow] = []

    /// XCTest keeps every test-case instance alive until the process ends, so windows this
    /// suite orders in would otherwise stay on screen (animating) for the whole run. On CI all
    /// bundles share one xctest process, and leaked recording panels starved later suites'
    /// main-queue drains.
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

    final class SpyCommandRouter: BarCommandRouting {
        var cancelCount = 0
        var stopCount = 0
        var primaryTapCount = 0
        var replayCount = 0

        func handleCancel() {
            cancelCount += 1
        }

        func handleStop() {
            stopCount += 1
        }

        func handlePrimaryTap() {
            primaryTapCount += 1
        }

        func handleReplay() {
            replayCount += 1
        }

        func handleRetranscribeHistoryEntry(recordingPath: String) {}
    }

    func testBarViewKeepsTheMergedW2WaveformTruthCallSites() throws {
        let source = try barViewSource()

        XCTAssertTrue(source.contains("recordingLevel: { state.recordingWaveformLevel }"))
        XCTAssertTrue(source.contains("isListening: !state.speechDetected"))
        XCTAssertEqual(source.components(separatedBy: "state.playbackAudioLevel()").count - 1, 1)
        XCTAssertEqual(source.components(separatedBy: "VoiceBarNotchWaveform(").count - 1, 1)
        XCTAssertFalse(source.contains("recordingWaveformLevels"))
        XCTAssertFalse(source.contains("transcribingWaveformLevels"))
        XCTAssertTrue(source.contains("case .transcribing:"))
        XCTAssertTrue(source.contains("commandRouter.handleCancel()"))
    }

    func testIdleLauncherUsesHistoryAndSettingsSymbolsAndKeepsRouterActions() throws {
        let source = try barViewSource()
        let trailing = try XCTUnwrap(source.range(of: "private var notchTrailingContent"))
        let compact = try XCTUnwrap(source.range(of: "private var notchCompactStatusContent"))
        let launcher = source[trailing.lowerBound ..< compact.lowerBound]
        XCTAssertTrue(launcher.contains("historyButton"))
        XCTAssertTrue(launcher.contains("settingsButton"))
        XCTAssertFalse(launcher.contains("vocabularyButton"))
        XCTAssertTrue(source.contains("notchButton(icon: \"gearshape\", accessibilityLabel: \"Settings\")"))
        XCTAssertTrue(source.contains("onOpenSettings()"))
        XCTAssertTrue(source.contains("commandRouter.handlePrimaryTap()"))
        XCTAssertTrue(source.contains("commandRouter.handleStop()"))
        XCTAssertTrue(source.contains("commandRouter.handleCancel()"))
        XCTAssertTrue(source.contains("state.setRecordingHold(!state.isRecordingHoldEngaged)"))
    }

    func testStopControlRestoresTheCircularContainerAndCentersTheSquare() throws {
        let stop = VoiceBarNotchControlOptics.resolve(for: "stop.fill")
        let replay = VoiceBarNotchControlOptics.resolve(for: "arrow.counterclockwise")
        let eye = VoiceBarNotchControlOptics.resolve(for: "eye")
        let eyeSlash = VoiceBarNotchControlOptics.resolve(for: "eye.slash")

        XCTAssertEqual(stop.pointSize, 8)
        XCTAssertEqual(stop.offsetX, 0)
        XCTAssertEqual(stop.offsetY, 0)
        XCTAssertEqual(eye.pointSize, eyeSlash.pointSize)
        XCTAssertEqual(eye.pointSize, 12)
        XCTAssertEqual(replay.pointSize, 12)

        let source = try barViewSource()
        let buttonStart = try XCTUnwrap(source.range(of: "private func notchButton"))
        let buttonSource = source[buttonStart.lowerBound...]
        XCTAssertTrue(buttonSource.contains("VoiceBarNotchControlOptics.resolve(for: icon)"))
        XCTAssertTrue(buttonSource.contains(": notchPrimaryLabelColor"))
        XCTAssertTrue(source.contains("notchPalette.primary.color"))
        XCTAssertFalse(source.contains("Color(nsColor: .labelColor)"))
        XCTAssertTrue(buttonSource.contains("icon == \"stop.fill\""))
        XCTAssertTrue(buttonSource.contains("VoiceBarPillControlButton("))
        XCTAssertTrue(source.contains(".frame(width: Self.hitDiameter, height: Self.hitDiameter)"))
        XCTAssertTrue(source.contains(".contentShape(Circle())"))
        XCTAssertTrue(source.contains(".padding(-Self.hitOverhang)"))
        XCTAssertTrue(source.contains("if isDestructive {"))
    }

    func testNativeNotchShellUsesApprovedBoundsForPrimaryStates() {
        let idle = VoiceState()
        idle.mode = .idle
        idle.isConnected = true
        idle.isCollapsed = false
        XCTAssertEqual(
            makeHost(state: idle, router: SpyCommandRouter()).bounds.size,
            NSSize(width: 306, height: 32),
            "visible idle must hold the launcher envelope through its collapse grace window"
        )

        idle.isCollapsed = true
        XCTAssertEqual(
            makeHost(state: idle, router: SpyCommandRouter()).bounds.size,
            NSSize(width: 185, height: 32)
        )

        let hover = VoiceState()
        hover.mode = .idle
        hover.isConnected = true
        hover.isCollapsed = false
        hover.isHovering = true
        XCTAssertEqual(
            makeHost(state: hover, router: SpyCommandRouter()).bounds.size,
            NSSize(width: 306, height: 32)
        )

        let recording = VoiceState()
        recording.mode = .recording
        recording.recordingMode = "vad"
        recording.isConnected = true
        recording.isCollapsed = false
        XCTAssertEqual(
            makeHost(state: recording, router: SpyCommandRouter()).bounds.size,
            NSSize(width: 363, height: 32)
        )

        let teleprompter = VoiceState()
        teleprompter.isConnected = true
        teleprompter.isCollapsed = false
        teleprompter.handleEvent([
            "type": "state",
            "state": "speaking",
            "text": "Native teleprompter geometry",
        ])
        XCTAssertEqual(
            makeHost(state: teleprompter, router: SpyCommandRouter()).bounds.size,
            NSSize(width: 465, height: 228)
        )
    }

    func testRecordingCancelAndStopControlsReceiveClicks() {
        let state = VoiceState()
        state.mode = .recording
        state.isConnected = true
        state.isCollapsed = false

        let router = SpyCommandRouter()
        let host = makeHost(state: state, router: router)

        click(host, at: recordingCancelButtonCenter(in: host))
        click(host, at: recordingStopButtonCenter(in: host))

        XCTAssertEqual(router.cancelCount, 1)
        XCTAssertEqual(router.stopCount, 1)
        XCTAssertEqual(router.primaryTapCount, 0)
    }

    func testVADRecordingHoldControlReceivesClickAndSendsCommand() {
        let state = VoiceState()
        state.mode = .recording
        state.recordingMode = "vad"
        state.isConnected = true
        state.isCollapsed = false
        var sentCommand: [String: Any]?
        state.sendCommand = { sentCommand = $0 }

        let router = SpyCommandRouter()
        let host = makeHost(state: state, router: router)

        click(host, at: recordingHoldButtonCenter(in: host))

        XCTAssertEqual(sentCommand?["cmd"] as? String, "set_recording_hold")
        XCTAssertEqual(sentCommand?["engaged"] as? Bool, true)
        XCTAssertTrue(state.isRecordingHoldEngaged)
    }

    func testPTTRecordingDoesNotExposeTheVADHoldControl() {
        let state = VoiceState()
        state.mode = .recording
        state.recordingMode = "ptt"
        state.isConnected = true
        state.isCollapsed = false
        var sentCommands: [[String: Any]] = []
        state.sendCommand = { sentCommands.append($0) }

        let router = SpyCommandRouter()
        _ = makeHost(state: state, router: router)

        XCTAssertTrue(sentCommands.isEmpty)
        XCTAssertFalse(state.isRecordingHoldEngaged)
        XCTAssertEqual(router.cancelCount, 0)
        XCTAssertEqual(router.stopCount, 0)
    }

    func testIdlePillBackgroundTapDoesNotRoutePrimaryAction() {
        let state = VoiceState()
        state.mode = .idle
        state.isConnected = true
        state.isCollapsed = false

        let router = SpyCommandRouter()
        let host = makeHost(state: state, router: router)

        click(host, at: NSPoint(x: host.bounds.midX, y: host.bounds.midY))

        XCTAssertEqual(router.primaryTapCount, 0)
        XCTAssertEqual(router.cancelCount, 0)
        XCTAssertEqual(router.stopCount, 0)
    }

    func testReadbackReplayControlFitsInsidePillAndReceivesClickWithAllAccessories() {
        let state = VoiceState()
        state.isConnected = true
        state.isCollapsed = false
        state.recentTranscriptions = ["Previous transcript"]
        state.transcriptionVocabularyTerms = ["VoiceLayer"]
        state.handleEvent([
            "type": "state",
            "state": "speaking",
            "text": "Retained readback with every trailing control",
        ])
        state.handleEvent([
            "type": "state",
            "state": "idle",
            "source": "playback",
        ])

        let router = SpyCommandRouter()
        let host = makeHost(state: state, router: router)

        XCTAssertGreaterThan(host.bounds.width, Theme.pillSpeakingQueueWidth)
        click(host, at: readbackReplayButtonCenter(in: host))

        XCTAssertEqual(router.replayCount, 1)
        XCTAssertEqual(router.primaryTapCount, 0)
    }

    func testReadbackHideShowAndDismissControlsRemainInTheTeleprompterSurface() {
        let state = VoiceState()
        state.isConnected = true
        state.isCollapsed = false
        state.handleEvent([
            "type": "state",
            "state": "speaking",
            "text": "Retained native readback",
        ])
        state.handleEvent([
            "type": "state",
            "state": "idle",
            "source": "playback",
        ])

        let host = makeHost(state: state, router: SpyCommandRouter())

        click(host, at: readbackVisibilityButtonCenter(in: host))
        XCTAssertTrue(state.isTeleprompterDismissed)

        click(host, at: readbackVisibilityButtonCenter(in: host))
        XCTAssertFalse(state.isTeleprompterDismissed)

        click(host, at: readbackDismissButtonCenter(in: host))
        XCTAssertFalse(state.isTeleprompterReadback)
        XCTAssertNil(state.teleprompterText)
    }

    func testHiddenLiveTeleprompterKeepsAReachableShowControlInCompactStatus() {
        let state = VoiceState()
        state.isConnected = true
        state.isCollapsed = false
        state.handleEvent([
            "type": "state",
            "state": "speaking",
            "text": "Show this live teleprompter again",
        ])
        state.dismissTeleprompter()
        XCTAssertTrue(state.isTeleprompterDismissed)

        let host = makeHost(state: state, router: SpyCommandRouter())
        clickFirstTeleprompterShow(in: host, state: state)

        XCTAssertFalse(state.isTeleprompterDismissed)
    }

    func testPauseControlLeftOfTheCoreSendsPauseThenResume() {
        let state = VoiceState()
        state.isConnected = true
        state.isCollapsed = false
        state.handleEvent(["type": "state", "state": "speaking", "text": "Pause me on the left"])
        var sent: [[String: Any]] = []
        state.sendCommand = { sent.append($0) }
        let router = SpyCommandRouter()

        // Teleprompter: the control sits in the new leading wing, inside the live hit region. (Any synthesized
        // click into a mounted teleprompter makes the test app active, Stop and the eye included, so the click
        // itself is exercised in the compact layouts below.)
        let teleprompter = makeInteractivePanelHost(
            state: state,
            router: router,
            configuration: VoiceBarNotchInteractionConfiguration(
                leadingControlCount: 1,
                lowerControlCount: 2,
                lowerSurfaceIsInteractive: true
            )
        )
        let leadingWing = teleprompter.layout.presentation.geometry.leadingWingWidth
        XCTAssertEqual(leadingWing, VoiceBarNotchContract.compactIndicatorLaneWidth)
        let pauseRect = teleprompter.controlRects[0]
        let pausePoint = NSPoint(x: pauseRect.midX, y: pauseRect.midY)
        XCTAssertLessThan(pauseRect.maxX, teleprompter.layout.visibleContentRect.minX
            + teleprompter.layout.presentation.geometry.coreOriginX)
        XCTAssertTrue(teleprompter.layout.containsInteractiveContent(pausePoint))
        XCTAssertNotNil(teleprompter.host.hitTest(pausePoint))

        // A hidden-but-playing read: pause on the left, the eye and Stop on the right.
        state.dismissTeleprompter()
        let speaking = makeInteractivePanelHost(
            state: state,
            router: router,
            configuration: VoiceBarNotchInteractionConfiguration(
                leadingControlCount: 1,
                trailingControlCountFromOuter: 2,
                trailingOuterInset: WaveformLayout.outerInset
            )
        )
        XCTAssertEqual(speaking.layout.presentation.visualState, .compactStatus)
        let compactPause = speaking.controlRects[0]
        click(speaking.host, at: NSPoint(x: compactPause.midX, y: compactPause.midY))
        XCTAssertEqual(sent.last?["cmd"] as? String, "pause")
        XCTAssertNotNil(sent.last?["playback_elapsed_ms"] as? Int)
        XCTAssertEqual(router.stopCount, 0)

        state.handleEvent([
            "type": "playback_state", "state": "paused", "playback_id": "p-1", "generation": 2,
            "offset_ms": 900, "chunk_offset_ms": 900,
        ])
        let paused = makeInteractivePanelHost(
            state: state,
            router: router,
            configuration: VoiceBarNotchInteractionConfiguration(
                leadingControlCount: 1,
                trailingControlCountFromOuter: 1,
                trailingOuterInset: WaveformLayout.outerInset
            )
        )
        XCTAssertEqual(paused.layout.presentation.visualState, .compactStatus)
        let playRect = paused.controlRects[0]
        click(paused.host, at: NSPoint(x: playRect.midX, y: playRect.midY))
        XCTAssertEqual(sent.last?["cmd"] as? String, "resume")
        XCTAssertEqual(sent.last?["playback_id"] as? String, "p-1")
        XCTAssertEqual(sent.last?["generation"] as? Int, 2)
        XCTAssertEqual(router.stopCount, 0)
    }

    func testNextControlBesidePauseSendsReadNextForTheCurrentRead() {
        let state = VoiceState()
        state.isConnected = true
        state.isCollapsed = false
        state.handleEvent(["type": "state", "state": "speaking", "text": "First queued read", "request_id": "r-A"])
        state.handleEvent(["type": "read_queue", "count": 2, "current_request_id": "r-A"])
        state.dismissTeleprompter()
        var sent: [[String: Any]] = []
        state.sendCommand = { sent.append($0) }
        let router = SpyCommandRouter()
        let speaking = makeInteractivePanelHost(
            state: state,
            router: router,
            configuration: VoiceBarNotchInteractionConfiguration(
                leadingControlCount: 3,
                trailingControlCountFromOuter: 2,
                trailingOuterInset: WaveformLayout.outerInset
            )
        )
        XCTAssertEqual(speaking.layout.presentation.visualState, .compactStatus)
        XCTAssertEqual(speaking.layout.presentation.geometry.leadingWingWidth,
                       VoiceBarPresentation.playbackLeadingWingWidth(slotCount: 3))
        // From the core outward: the "+2" count, Next, then pause.
        let next = speaking.controlRects[1]
        click(speaking.host, at: NSPoint(x: next.midX, y: next.midY))
        XCTAssertEqual(sent.last?["cmd"] as? String, "read_next")
        XCTAssertEqual(sent.last?["request_id"] as? String, "r-A")
        let pause = speaking.controlRects[2]
        click(speaking.host, at: NSPoint(x: pause.midX, y: pause.midY))
        XCTAssertEqual(sent.last?["cmd"] as? String, "pause")
        XCTAssertEqual(router.stopCount, 0)
    }

    // MARK: - PILL1-a: the first click on a pill whose app is inactive reaches the control

    /// While the panel is not key, AppKit asks the hit view whether the first mouse-down may act. Every control's
    /// real SwiftUI hit target must accept it. On the compact panel (Pause, Play, Next, Stop) that click dispatches
    /// its command exactly once, leaves the panel non-key and keeps the frontmost app; the readback row (Replay,
    /// Hide) proves hit acceptance on the panel and its one dispatch on a plain non-key window (see below).
    func testEveryPillControlAcceptsTheFirstClickWhileThePanelIsNotKey() {
        // Pause on the left and Stop (outermost) on the right of a hidden-but-playing read.
        var speaking = makeSpeakingPanel(count: 0)
        firstClick(speaking.panel, control: 0)
        XCTAssertEqual(speaking.sent.cmds, ["pause"])
        firstClick(speaking.panel, control: 1)
        XCTAssertEqual(speaking.router.stopCount, 1)

        // Play on a paused read.
        speaking = makeSpeakingPanel(count: 0, paused: true)
        firstClick(speaking.panel, control: 0)
        XCTAssertEqual(speaking.sent.cmds, ["resume"])
        XCTAssertEqual(speaking.router.stopCount, 0)

        // Next, from the core outward after the "+1" count.
        speaking = makeSpeakingPanel(count: 1)
        firstClick(speaking.panel, control: 1)
        XCTAssertEqual(speaking.sent.cmds, ["read_next"])
        XCTAssertEqual(speaking.sent.commands.last?["request_id"] as? String, "r-A")
        XCTAssertEqual(speaking.router.stopCount, 0)

        // Replay and Hide in a retained readback's teleprompter row. A click there makes the production panel key
        // (becomesKeyOnlyIfNeeded, unchanged here), which HYG2's offscreen isolation forbids in tests, so the real
        // panel proves their hit targets accept the first mouse-down and a non-key window proves one dispatch each.
        let readback = makeReadbackPanel()
        XCTAssertNotNil(acceptedFirstMousePoint(readback.panel, control: 0))
        XCTAssertNotNil(acceptedFirstMousePoint(readback.panel, control: 1))
        let host = makeHost(state: readback.state, router: readback.router)
        click(host, at: readbackReplayButtonCenter(in: host))
        XCTAssertEqual(readback.router.replayCount, 1)
        click(host, at: readbackVisibilityButtonCenter(in: host))
        XCTAssertTrue(readback.state.isTeleprompterDismissed)
        XCTAssertEqual(readback.router.replayCount, 1)
        XCTAssertEqual(readback.router.stopCount, 0)
    }

    private final class SentCommands {
        var commands: [[String: Any]] = []
        var cmds: [String] {
            commands.compactMap { $0["cmd"] as? String }
        }
    }

    private typealias InteractivePanelHost = (
        host: PillHostingView<BarView>,
        panel: FloatingPillPanel,
        layout: VoiceBarPanelLayout,
        controlRects: [CGRect]
    )

    /// A hidden-but-playing read in compact status: pause/play (and Next with "+N") on the left, Stop and,
    /// while playing, the eye on the right — the configuration VoiceBarApp builds for this state.
    private func makeSpeakingPanel(count: Int, paused: Bool = false) -> (
        panel: InteractivePanelHost,
        sent: SentCommands,
        router: SpyCommandRouter
    ) {
        let state = VoiceState()
        state.isConnected = true
        state.isCollapsed = false
        state.handleEvent(["type": "state", "state": "speaking", "text": "First click read", "request_id": "r-A",
                           "playback_id": "p-1", "generation": 1])
        if count > 0 {
            state.handleEvent(["type": "read_queue", "count": count, "current_request_id": "r-A"])
        }
        if paused {
            state.handleEvent(["type": "playback_state", "state": "paused", "playback_id": "p-1", "generation": 2,
                               "offset_ms": 900, "chunk_offset_ms": 900])
        }
        state.dismissTeleprompter()
        let sent = SentCommands()
        state.sendCommand = { sent.commands.append($0) }
        let router = SpyCommandRouter()
        let panel = makeInteractivePanelHost(
            state: state,
            router: router,
            configuration: VoiceBarNotchInteractionConfiguration(
                leadingControlCount: VoiceBarPresentation.readQueueControl(for: state)?.leadingSlotCount ?? 1,
                trailingControlCountFromOuter: paused ? 1 : 2,
                trailingOuterInset: WaveformLayout.outerInset
            )
        )
        XCTAssertEqual(panel.layout.presentation.visualState, .compactStatus)
        return (panel, sent, router)
    }

    private func makeReadbackPanel() -> (panel: InteractivePanelHost, state: VoiceState, router: SpyCommandRouter) {
        let state = VoiceState()
        state.isConnected = true
        state.isCollapsed = false
        state.handleEvent(["type": "state", "state": "speaking", "text": "Retained first-click readback"])
        state.handleEvent(["type": "state", "state": "idle", "source": "playback"])
        XCTAssertTrue(state.canReplay)
        let router = SpyCommandRouter()
        // Replay, Hide and Dismiss: the configuration VoiceBarApp builds for a retained readback.
        let panel = makeInteractivePanelHost(
            state: state,
            router: router,
            configuration: VoiceBarNotchInteractionConfiguration(lowerControlCount: 3)
        )
        XCTAssertEqual(panel.layout.presentation.visualState, .teleprompter)
        return (panel, state, router)
    }

    /// Returns the control's center when the real SwiftUI hit target there accepts a first mouse-down on the
    /// non-key panel; nil (after recording the failure) otherwise.
    private func acceptedFirstMousePoint(
        _ panelHost: InteractivePanelHost,
        control index: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> NSPoint? {
        let rect = panelHost.controlRects[index]
        let point = NSPoint(x: rect.midX, y: rect.midY)
        XCTAssertFalse(panelHost.panel.isKeyWindow, "the pill is not key before its first click", file: file, line: line)
        guard let target = panelHost.host.hitTest(point),
              let down = mouseEvent(type: .leftMouseDown, at: point, windowNumber: panelHost.panel.windowNumber)
        else {
            XCTFail("Expected a hit target at \(point)", file: file, line: line)
            return nil
        }
        guard target.acceptsFirstMouse(for: down) else {
            XCTFail("\(type(of: target)) must accept the first mouse-down", file: file, line: line)
            return nil
        }
        return point
    }

    private func firstClick(
        _ panelHost: InteractivePanelHost,
        control index: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
        guard let point = acceptedFirstMousePoint(panelHost, control: index, file: file, line: line) else { return }
        click(panelHost.host, at: point)
        XCTAssertFalse(panelHost.panel.isKeyWindow, "a first click does not make the pill key", file: file, line: line)
        XCTAssertEqual(NSWorkspace.shared.frontmostApplication?.processIdentifier, frontmost,
                       "a first click leaves the frontmost app unchanged", file: file, line: line)
    }

    func testIdleMicButtonRoutesPrimaryAction() {
        let state = VoiceState()
        state.mode = .idle
        state.isConnected = true
        state.isCollapsed = false
        state.isHovering = true

        let router = SpyCommandRouter()
        let host = makeHost(state: state, router: router)

        clickFirstPrimaryTap(in: host, router: router)

        XCTAssertEqual(router.primaryTapCount, 1)
        XCTAssertEqual(router.cancelCount, 0)
        XCTAssertEqual(router.stopCount, 0)
    }

    /// #137 review MUST-FIX 1: P05's 26 pt system is for the pill controls only. The voice_speak
    /// surface (teleprompter controls, the speaking wing's eye + Stop, and the non-button status
    /// glyph) keeps the pre-P05 compact optics, or eye and Stop crowd the waveform.
    func testVoiceSpeakSurfaceKeepsPreP05CompactOptics() throws {
        XCTAssertEqual(VoiceBarNotchControlOptics.legacyCompact(for: "eye").pointSize, 8.5)
        XCTAssertEqual(VoiceBarNotchControlOptics.legacyCompact(for: "eye.slash").pointSize, 8.5)
        XCTAssertEqual(VoiceBarNotchControlOptics.legacyCompact(for: "arrow.counterclockwise").pointSize, 9.5)
        XCTAssertEqual(VoiceBarNotchControlOptics.legacyCompact(for: "stop.fill").pointSize, 8)
        XCTAssertEqual(VoiceBarNotchControlOptics.legacyCompact(for: "speaker.wave.2.fill").pointSize, 10)
        XCTAssertEqual(VoiceBarNotchControlOptics.legacyCompact(for: "bolt.horizontal.circle.fill").pointSize, 10)

        let source = try barViewSource()
        let speakingStart = try XCTUnwrap(source.range(of: "private var notchSpeakingTrailingContent"))
        let waveformStart = try XCTUnwrap(source.range(of: "private var notchWaveform"))
        let speaking = String(source[speakingStart.lowerBound..<waveformStart.lowerBound])
        XCTAssertFalse(speaking.contains("notchButton("))
        XCTAssertEqual(speaking.components(separatedBy: "notchTeleprompterButton(").count - 1, 2)
        XCTAssertTrue(speaking.contains("icon: \"eye\""))
        XCTAssertTrue(speaking.contains("icon: \"stop.fill\""))

        let teleprompterStart = try XCTUnwrap(source.range(of: "private func notchTeleprompterButton"))
        XCTAssertTrue(source[teleprompterStart.lowerBound...]
            .contains("VoiceBarNotchControlOptics.legacyCompact(for: icon)"))
    }

    func testIdleStatusMicReusesLauncherMicOpticsAndPrimaryForeground() throws {
        let source = try barViewSource()
        let statusStart = try XCTUnwrap(source.range(of: "private var statusIcon"))
        let imageStart = try XCTUnwrap(source.range(of: "private var statusIconImage"))
        let iconNameStart = try XCTUnwrap(
            source.range(of: "private var iconName", range: imageStart.upperBound ..< source.endIndex)
        )
        let statusIconImage = source[imageStart.lowerBound ..< iconNameStart.lowerBound]

        // Only non-idle, non-error modes reach statusIconImage (speaker, bolt, waveform); the mic
        // is always the notchButton pinned below, so it shares the launcher mic's optics.
        XCTAssertTrue(
            statusIconImage.contains("VoiceBarNotchControlOptics.legacyCompact(for: iconName)"),
            "the non-button status glyph keeps its pre-P05 compact size (#137 review)"
        )
        XCTAssertTrue(
            statusIconImage.contains("state.mode == .idle ? notchPrimaryLabelColor"),
            "the neutral hotkey-transition mic must use the same appearance-aware primary foreground as the launcher mic"
        )
        let statusIcon = source[statusStart.lowerBound ..< imageStart.lowerBound]
        XCTAssertTrue(
            statusIcon.contains("notchButton("),
            "launcher and quick-F5 must mount the same 20pt mic control instead of 20pt and 26pt variants"
        )
    }

    func testRecordingLeadingWingOwnsProminentStopCancelAndOptionalHold() throws {
        let source = try barViewSource()
        let leadingStart = try XCTUnwrap(source.range(of: "private var notchLeadingContent"))
        let trailingStart = try XCTUnwrap(
            source.range(of: "private var notchTrailingContent", range: leadingStart.upperBound ..< source.endIndex)
        )
        let leading = source[leadingStart.lowerBound ..< trailingStart.lowerBound]
        let recordingStart = try XCTUnwrap(leading.range(of: "case .recording:"))
        let statusStart = try XCTUnwrap(
            leading.range(of: "case .compactStatus, .teleprompter:", range: recordingStart.upperBound ..< leading.endIndex)
        )
        let recording = leading[recordingStart.lowerBound ..< statusStart.lowerBound]

        XCTAssertTrue(recording.contains("HStack(spacing:"))
        let stop = try XCTUnwrap(recording.range(of: "accessibilityLabel: \"Stop recording\""))
        let cancel = try XCTUnwrap(recording.range(of: "accessibilityLabel: \"Cancel recording\""))
        let hold = try XCTUnwrap(recording.range(of: "if let recordingHoldControl"))
        XCTAssertLessThan(stop.lowerBound, cancel.lowerBound)
        XCTAssertLessThan(cancel.lowerBound, hold.lowerBound)
        XCTAssertTrue(recording.contains("isDestructive: true"))
        XCTAssertFalse(recording.contains("Image(systemName: \"mic.fill\")"))
        XCTAssertFalse(recording.contains("PulsingDot()"))
    }

    func testRecordingTrailingWingContainsOnlyTheSharedWaveform() throws {
        let source = try barViewSource()
        let trailingStart = try XCTUnwrap(source.range(of: "private var notchTrailingContent"))
        let compactStart = try XCTUnwrap(
            source.range(
                of: "private var notchCompactStatusContent",
                range: trailingStart.upperBound ..< source.endIndex
            )
        )
        let trailing = source[trailingStart.lowerBound ..< compactStart.lowerBound]
        let recordingStart = try XCTUnwrap(trailing.range(of: "case .recording:"))
        let statusStart = try XCTUnwrap(
            trailing.range(of: "case .compactStatus, .teleprompter:", range: recordingStart.upperBound ..< trailing.endIndex)
        )
        let recording = trailing[recordingStart.lowerBound ..< statusStart.lowerBound]

        XCTAssertTrue(recording.contains("notchWaveform"))
        XCTAssertFalse(recording.contains("notchButton"))
        XCTAssertFalse(recording.contains("recordingHoldControl"))
    }

    func testTeleprompterContentFadesWithTheMorphInsteadOfHoldingAHollowShell() throws {
        let source = try barViewSource()
        let lowerContentStart = try XCTUnwrap(source.range(of: "private var notchLowerContent"))
        let scheduleStart = try XCTUnwrap(
            source.range(
                of: "private func scheduleMorphTeleprompterContent",
                range: lowerContentStart.upperBound ..< source.endIndex
            )
        )
        let queueBadgeStart = try XCTUnwrap(
            source.range(
                of: "private var queueBadge",
                range: scheduleStart.upperBound ..< source.endIndex
            )
        )
        let lowerContent = source[lowerContentStart.lowerBound ..< scheduleStart.lowerBound]
        let schedule = source[scheduleStart.lowerBound ..< queueBadgeStart.lowerBound]

        XCTAssertTrue(source.contains("@State private var isMorphTeleprompterContentPresented"))
        XCTAssertTrue(schedule.contains("scheduleMorphTeleprompterContent"))
        XCTAssertFalse(source.contains("@State private var morphTeleprompterContentTask"))
        XCTAssertFalse(schedule.contains("Task.sleep"))
        XCTAssertFalse(schedule.contains("morphDescriptor.totalDuration"))
        XCTAssertTrue(schedule.contains("VoiceBarNotchContract.motion.panelDelay"))
        XCTAssertTrue(lowerContent.contains("if isMorphTeleprompterContentPresented"))
        XCTAssertTrue(lowerContent.contains(".transition(.opacity)"))
    }

    func testStatusLabelDoesNotCrossFadeOldAndNewTextInTheSameFrame() throws {
        let source = try barViewSource()
        let statusStart = try XCTUnwrap(source.range(of: "private var statusLabel"))
        let textStart = try XCTUnwrap(
            source.range(of: "private var statusText", range: statusStart.upperBound ..< source.endIndex)
        )
        let statusLabel = source[statusStart.lowerBound ..< textStart.lowerBound]

        XCTAssertFalse(statusLabel.contains("replacesWingText"))
        XCTAssertFalse(statusLabel.contains("Details below"))
        XCTAssertFalse(statusLabel.contains("\"Error\""))
        XCTAssertFalse(statusLabel.contains(".contentTransition(.opacity)"))
        XCTAssertTrue(statusLabel.contains(".transaction"))
        XCTAssertTrue(statusLabel.contains("transaction.animation = nil"))
    }

    func testTranscribingNotchDropsTheRedundantDefaultLabel() throws {
        let source = try barViewSource()
        let leadingStart = try XCTUnwrap(source.range(of: "private var notchLeadingContent"))
        let trailingStart = try XCTUnwrap(
            source.range(of: "private var notchTrailingContent", range: leadingStart.upperBound ..< source.endIndex)
        )
        let leading = source[leadingStart.lowerBound ..< trailingStart.lowerBound]

        XCTAssertTrue(leading.contains("if notchPresentation.visualState == .compactStatus, state.mode == .transcribing"))
        XCTAssertTrue(leading.contains("ProcessingSpinner()"))
        XCTAssertFalse(leading.contains("statusLabel"))
    }

    func testTranscribingKeepsTheWaveformTrailingAndMorphsTheLeadingIndicator() throws {
        let source = try barViewSource()
        let leadingStart = try XCTUnwrap(source.range(of: "private var notchLeadingContent"))
        let trailingStart = try XCTUnwrap(
            source.range(of: "private var notchTrailingContent", range: leadingStart.upperBound ..< source.endIndex)
        )
        let compactStart = try XCTUnwrap(
            source.range(
                of: "private var notchCompactStatusContent",
                range: trailingStart.upperBound ..< source.endIndex
            )
        )
        let leading = source[leadingStart.lowerBound ..< trailingStart.lowerBound]
        let trailing = source[trailingStart.lowerBound ..< compactStart.lowerBound]

        XCTAssertTrue(leading.contains("ProcessingSpinner()"))
        XCTAssertFalse(leading.contains("WaveformView("))
        XCTAssertTrue(trailing.contains("notchWaveform"))
        XCTAssertTrue(source.contains("VoiceBarNotchWaveform("))
    }

    func testQueuedSpeechUsesOnlyASmallBadgeBesideTeleprompterControls() throws {
        let source = try barViewSource()

        XCTAssertTrue(source.contains("if state.queuedSpeakCount > 0"))
        XCTAssertTrue(source.contains("Text(\"+\\(state.queuedSpeakCount) queued\")"))
        XCTAssertFalse(source.contains("private var queueVisualization"))
    }

    func testOpenPopoversKeepTheLauncherMountedAfterPointerExit() throws {
        let source = try barViewSource()

        XCTAssertTrue(source
            .contains("private var keepsLauncherMounted: Bool {\n        isHistoryPresented\n    }"))
        XCTAssertTrue(source.contains("synchronizeLauncherRetention()"))
    }

    /// Spec §4: the Transcription Vocabulary notch panel is removed; the gear opens Settings › Dictionary.
    func testNotchNoLongerCarriesTheVocabularyPanel() throws {
        let source = try barViewSource()

        XCTAssertFalse(source.contains("vocabularyButton"))
        XCTAssertFalse(source.contains("vocabularyPopover"))
        XCTAssertFalse(source.contains("isVocabularyPresented"))
        XCTAssertFalse(source.contains("accessibilityLabel: \"Dictionary\""))
    }

    func testSettingsButtonMountsOnlyInHoveredLauncher() throws {
        let source = try barViewSource()
        let leadingStart = try XCTUnwrap(source.range(of: "private var notchLeadingContent"))
        let trailingStart = try XCTUnwrap(source.range(of: "private var notchTrailingContent"))
        let compactStart = try XCTUnwrap(
            source.range(
                of: "private var notchCompactStatusContent",
                range: trailingStart.upperBound ..< source.endIndex
            )
        )
        let trailing = String(source[trailingStart.lowerBound ..< compactStart.lowerBound])
        let hover = try XCTUnwrap(
            trailing.components(separatedBy: "case .hoverLauncher, .history:").dropFirst().first?
                .components(separatedBy: "case .recording:").first
        )
        let active = try XCTUnwrap(trailing.components(separatedBy: "case .recording:").dropFirst().first)
        let leading = String(source[leadingStart.lowerBound ..< trailingStart.lowerBound])
        let teleprompterLeading = try XCTUnwrap(
            leading.components(separatedBy: "case .compactStatus, .teleprompter:").dropFirst().first
        )

        XCTAssertTrue(hover.contains("historyButton"))
        XCTAssertTrue(hover.contains("settingsButton"))
        XCTAssertFalse(hover.contains("vocabularyButton"))
        XCTAssertFalse(active.contains("historyButton"))
        XCTAssertFalse(active.contains("settingsButton"))
        // P16: a speaking teleprompter's left holds pause/play, and nothing else.
        XCTAssertTrue(teleprompterLeading.contains("playbackPauseButton"))
        XCTAssertFalse(teleprompterLeading.contains("settingsButton"))
        XCTAssertFalse(teleprompterLeading.contains("Dictionary"))
    }

    /// #137 review N3: a BarView site that forgets the handler must not compile into a dead gear.
    func testOpenSettingsHandlerIsRequired() throws {
        let source = try barViewSource()

        XCTAssertTrue(source.contains("onOpenSettings: @escaping () -> Void,\n"))
        XCTAssertFalse(source.contains("onOpenSettings: @escaping () -> Void = {}"))
    }

    func testSettingsButtonCallsTheExistingOpenSettingsHandler() {
        let state = VoiceState()
        state.mode = .idle
        state.isConnected = true
        state.isCollapsed = false
        state.isHovering = true
        let router = SpyCommandRouter()
        var opened = 0
        let (host, _, _, controlRects) = makeInteractivePanelHost(
            state: state,
            router: router,
            configuration: VoiceBarNotchInteractionConfiguration(
                leadingControlCount: 1, trailingControlCountFromCore: 2
            ),
            onOpenSettings: { opened += 1 }
        )
        click(host, at: topEdgePoint(of: controlRects[2]))
        XCTAssertEqual(opened, 1)
        XCTAssertEqual(router.primaryTapCount, 0)
    }

    func testPillButtonRingClicksReachHandlersWithoutChangingDragRegion() {
        let ringOffsets: [(CGFloat, CGFloat)] = [(12, 0), (-12, 0), (0, 12), (0, -12)]
        for (name, index) in [("Stop", 2), ("Cancel", 1), ("Lock", 0), ("Mic", 0), ("Settings", 2)] {
            for (dx, dy) in ringOffsets {
                let state = VoiceState()
                state.isConnected = true
                state.isCollapsed = false
                state.mode = name == "Mic" || name == "Settings" ? .idle : .recording
                state.isHovering = state.mode == .idle
                state.recordingMode = state.mode == .recording ? "vad" : nil
                let router = SpyCommandRouter()
                var holdCommands = 0
                state.sendCommand = { command in
                    if command["cmd"] as? String == "set_recording_hold" { holdCommands += 1 }
                }
                var settingsOpens = 0
                let configuration = state.mode == .recording
                    ? VoiceBarNotchInteractionConfiguration(leadingControlCount: 3)
                    : VoiceBarNotchInteractionConfiguration(
                        leadingControlCount: 1, trailingControlCountFromCore: 2
                    )
                let (host, panel, _, rects) = makeInteractivePanelHost(
                    state: state, router: router, configuration: configuration,
                    onOpenSettings: { settingsOpens += 1 }
                )
                let rect = rects[index]
                let point = NSPoint(x: rect.midX + dx, y: rect.midY + dy)
                XCTAssertFalse(panel.startsDrag(at: point), "\(name) ring must not expand drag interception")
                click(host, at: point)
                let fired: Int = switch name {
                case "Stop": router.stopCount
                case "Cancel": router.cancelCount
                case "Lock": holdCommands
                case "Mic": router.primaryTapCount
                default: settingsOpens
                }
                XCTAssertEqual(fired, 1, "\(name) ring click at \(dx), \(dy)")
            }
        }
    }

    func testProductNotchShellDoesNotMountAKeyboardFocusHighlightSurface() throws {
        let source = try barViewSource()

        XCTAssertFalse(source.contains("@FocusState"))
        XCTAssertFalse(source.contains(".focusable()"))
        XCTAssertFalse(source.contains(".focused("))
    }

    func testBarViewDoesNotOwnRetainedReadbackDismissal() throws {
        let source = try barViewSource()

        XCTAssertFalse(source.contains("presentationModel?.updateRetainedReadback"))
        XCTAssertFalse(source.contains("private func updateRetainedReadbackLifecycle"))
    }

    func testErrorStatusIconRoutesPrimaryAction() {
        let state = VoiceState()
        state.mode = .error
        state.isConnected = true
        state.isCollapsed = false

        let router = SpyCommandRouter()
        let host = makeHost(state: state, router: router)

        clickFirstPrimaryTap(in: host, router: router)

        XCTAssertEqual(router.primaryTapCount, 1)
        XCTAssertEqual(router.cancelCount, 0)
        XCTAssertEqual(router.stopCount, 0)
    }

    func testDraggingFromRecordingStopButtonDoesNotClickStop() {
        let state = VoiceState()
        state.mode = .recording
        state.isConnected = true
        state.isCollapsed = false

        let router = SpyCommandRouter()
        let host = makeHost(state: state, router: router)
        let start = recordingStopButtonCenter(in: host)
        let end = NSPoint(x: start.x + 24, y: start.y + 2)

        drag(host, from: start, to: end)

        XCTAssertEqual(router.stopCount, 0)
        XCTAssertEqual(router.cancelCount, 0)
        XCTAssertEqual(router.primaryTapCount, 0)
    }

    func testPanelAppKitMouseEventsAdmitTheRenderedRecordingSurface() {
        let state = VoiceState()
        state.mode = .recording
        state.recordingMode = "vad"
        state.isConnected = true
        state.isCollapsed = false
        var sentCommand: [String: Any]?
        state.sendCommand = { sentCommand = $0 }
        let router = SpyCommandRouter()
        let (host, panel, layout, controlRects) = makeInteractivePanelHost(
            state: state,
            router: router,
            configuration: VoiceBarNotchInteractionConfiguration(leadingControlCount: 3)
        )

        XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel))
        XCTAssertFalse(panel.canBecomeMain)
        click(host, at: topEdgePoint(of: controlRects[2]))
        click(host, at: topEdgePoint(of: controlRects[1]))
        click(host, at: topEdgePoint(of: controlRects[0]))

        XCTAssertEqual(router.stopCount, 1)
        XCTAssertEqual(router.cancelCount, 1)
        XCTAssertEqual(sentCommand?["cmd"] as? String, "set_recording_hold")
        XCTAssertEqual(sentCommand?["engaged"] as? Bool, true)

        let gapBesideStop = NSPoint(x: controlRects[2].maxX + 3, y: controlRects[2].midY)
        let transparentMargin = NSPoint(x: 1, y: 1)
        let waveform = NSPoint(
            x: layout.visibleContentRect.minX + layout.presentation.geometry.coreOriginX
                + layout.presentation.geometry.coreWidth + WaveformLayout.coreGap + 10,
            y: controlRects[2].midY
        )
        XCTAssertTrue(layout.containsVisibleSurface(gapBesideStop))
        XCTAssertNotNil(host.hitTest(gapBesideStop))
        XCTAssertFalse(layout.containsVisibleSurface(transparentMargin))
        XCTAssertNil(host.hitTest(transparentMargin))
        XCTAssertTrue(layout.containsVisibleSurface(waveform))
        XCTAssertNotNil(host.hitTest(waveform))
        XCTAssertFalse(panel.startsDrag(at: gapBesideStop))
        XCTAssertTrue(panel.shouldHandleContextMenu(at: waveform))
    }

    func testTeleprompterAppKitMouseEventsAdmitItsRenderedBodyForContextMenu() {
        let state = VoiceState()
        state.isConnected = true
        state.isCollapsed = false
        state.handleEvent([
            "type": "state",
            "state": "speaking",
            "text": "The terminal remains interactive behind this read-along surface.",
        ])
        let router = SpyCommandRouter()
        let (host, panel, layout, controlRects) = makeInteractivePanelHost(
            state: state,
            router: router,
            configuration: VoiceBarNotchInteractionConfiguration(lowerControlCount: 3)
        )
        let bodyPoint = NSPoint(
            x: layout.visibleContentRect.midX,
            y: layout.visibleContentRect.minY + 120
        )
        // Left of P16's pause wing, where the old Dictionary lane hung below the top row.
        let formerDictionaryLane = NSPoint(
            x: layout.visibleContentRect.minX + layout.presentation.geometry.coreOriginX
                - VoiceBarNotchContract.compactIndicatorLaneWidth - 20,
            y: layout.visibleContentRect.minY + 212
        )

        XCTAssertFalse(controlRects.isEmpty)
        for rect in controlRects {
            let point = topEdgePoint(of: rect)
            XCTAssertTrue(layout.containsInteractiveContent(point))
            XCTAssertTrue(layout.containsVisibleSurface(point))
            XCTAssertNotNil(host.hitTest(point))
        }
        XCTAssertTrue(layout.containsVisibleSurface(bodyPoint))
        XCTAssertNotNil(host.hitTest(bodyPoint))
        XCTAssertFalse(layout.containsVisibleSurface(formerDictionaryLane))
        XCTAssertNil(host.hitTest(formerDictionaryLane))
        XCTAssertFalse(panel.startsDrag(at: bodyPoint))
        XCTAssertFalse(panel.shouldHandleContextMenu(at: formerDictionaryLane))
    }

    func testPanelRightMouseDownOpensContextMenuOnRenderedRecordingWing() throws {
        let state = VoiceState()
        state.mode = .recording
        state.recordingMode = "vad"
        state.isConnected = true
        state.isCollapsed = false
        let (host, panel, layout, controlRects) = makeInteractivePanelHost(
            state: state,
            router: SpyCommandRouter(),
            configuration: VoiceBarNotchInteractionConfiguration(leadingControlCount: 3)
        )
        let wingPoint = NSPoint(
            x: layout.visibleContentRect.minX + layout.presentation.geometry.coreOriginX
                + layout.presentation.geometry.coreWidth + WaveformLayout.coreGap + 10,
            y: controlRects[0].midY
        )
        let menu = NSMenu(title: "VoiceBar acceptance")
        menu.addItem(withTitle: "Context menu opened", action: nil, keyEquivalent: "")
        panel.contextMenuProvider = { menu }
        let beganTracking = expectation(
            forNotification: NSMenu.didBeginTrackingNotification,
            object: menu
        )
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            menu.cancelTracking()
        }
        let event = try XCTUnwrap(
            mouseEvent(
                type: .rightMouseDown,
                at: wingPoint,
                windowNumber: panel.windowNumber
            )
        )

        XCTAssertNotNil(host.hitTest(wingPoint))
        XCTAssertTrue(panel.shouldHandleContextMenu(at: wingPoint))
        panel.sendEvent(event)
        wait(for: [beganTracking], timeout: 1)
    }

    private func makeHost(
        state: VoiceState,
        router: SpyCommandRouter,
        presentationModel: VoiceBarNotchPresentationModel? = nil
    ) -> NSHostingView<BarView> {
        let host = NSHostingView(
            rootView: BarView(
                state: state,
                commandRouter: router,
                onOpenSettings: {}, onOpenHistory: {},
                presentationModel: presentationModel
            )
        )
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        let window = NSWindow(
            contentRect: host.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -100_000, y: -100_000))
        window.orderBack(nil)
        windows.append(window)
        host.layoutSubtreeIfNeeded()
        return host
    }

    private func topEdgePoint(of rect: CGRect) -> NSPoint {
        NSPoint(x: rect.midX, y: rect.maxY - 1)
    }

    private func makeInteractivePanelHost(
        state: VoiceState,
        router: SpyCommandRouter,
        configuration: VoiceBarNotchInteractionConfiguration,
        onOpenSettings: @escaping () -> Void = {}
    ) -> (
        host: PillHostingView<BarView>,
        panel: FloatingPillPanel,
        layout: VoiceBarPanelLayout,
        controlRects: [CGRect]
    ) {
        let presentation = VoiceBarPresentation.notchPresentation(
            from: VoiceBarNotchOperationalInput(
                mode: state.mode,
                showsRecordingHold: state.mode == .recording && state.recordingMode == "vad",
                hasTeleprompterText: state.teleprompterText != nil,
                isTeleprompterDismissed: state.isTeleprompterDismissed,
                isTeleprompterReadback: state.isTeleprompterReadback,
                isPlaybackPaused: state.isPlaybackPaused,
                readQueueLeadingSlotCount: VoiceBarPresentation.readQueueControl(for: state)?.leadingSlotCount ?? 1,
                isCollapsed: state.isCollapsed
            )
        )
        let canvas = VoiceBarNotchMorphCanvasLayout.resolve(for: presentation)
        let layout = VoiceBarPanelLayout.make(
            presentation: presentation,
            interactionConfiguration: configuration,
            canvasGeometry: canvas.canvasGeometry
        )
        let host = PillHostingView(
            rootView: BarView(
                state: state,
                commandRouter: router,
                onOpenSettings: onOpenSettings,
                onOpenHistory: {},
                includesPanelOutsets: true
            )
        )
        host.frame = NSRect(origin: .zero, size: layout.panelSize)
        host.activeHitTestProvider = { layout.containsInteractiveContent($0) }
        host.renderedSurfaceHitTestProvider = { layout.containsVisibleSurface($0) }
        let panel = FloatingPillPanel(content: host)
        panel.activeHitTestProvider = { layout.containsInteractiveContent($0) }
        panel.contextMenuHitTestProvider = { layout.containsVisibleSurface($0) }
        panel.setFrameOrigin(NSPoint(x: -100_000, y: -100_000))
        panel.orderBack(nil)
        windows.append(panel)
        host.layoutSubtreeIfNeeded()
        let region = VoiceBarNotchHitRegion(
            geometry: presentation.geometry,
            configuration: configuration
        )
        let controlRects = region.rects.map {
            $0.offsetBy(dx: layout.visibleContentRect.minX, dy: layout.visibleContentRect.minY)
        }
        return (host, panel, layout, controlRects)
    }

    private func recordingCancelButtonCenter(in host: NSView) -> NSPoint {
        NSPoint(
            x: host.bounds.minX + 50,
            y: host.bounds.midY
        )
    }

    private func recordingHoldButtonCenter(in host: NSView) -> NSPoint {
        NSPoint(x: host.bounds.minX + 76, y: host.bounds.midY)
    }

    private func recordingStopButtonCenter(in host: NSView) -> NSPoint {
        NSPoint(x: host.bounds.minX + 24, y: host.bounds.midY)
    }

    private func readbackReplayButtonCenter(in host: NSView) -> NSPoint {
        NSPoint(x: host.bounds.midX - 28, y: 23)
    }

    private func readbackVisibilityButtonCenter(in host: NSView) -> NSPoint {
        NSPoint(x: host.bounds.midX, y: 23)
    }

    private func readbackDismissButtonCenter(in host: NSView) -> NSPoint {
        NSPoint(x: host.bounds.midX + 28, y: 23)
    }

    private func statusIconCenter(in host: NSView) -> NSPoint {
        NSPoint(x: host.bounds.minX + 14 + 3 + 8 + 9, y: host.bounds.midY)
    }

    private func click(_ host: NSView, at point: NSPoint, inHostCoordinates: Bool = false) {
        guard host.hitTest(point) != nil else {
            XCTFail("Expected a hit-test target at \(point)")
            return
        }

        let eventPoint = inHostCoordinates ? host.convert(point, to: nil) : point
        guard let window = host.window,
              let downEvent = mouseEvent(type: .leftMouseDown, at: eventPoint, windowNumber: window.windowNumber),
              let upEvent = mouseEvent(type: .leftMouseUp, at: eventPoint, windowNumber: window.windowNumber) else {
            XCTFail("Expected to create mouse events")
            return
        }

        window.sendEvent(downEvent)
        window.sendEvent(upEvent)
    }

    private func clickFirstPrimaryTap(in host: NSView, router: SpyCommandRouter) {
        // Expanded feedback adds a selectable lower band. The primary action stays
        // in the top row; probing the whole host's midpoint enters text selection.
        let y = host.isFlipped ? host.bounds.minY + VoiceBarNotchContract.topHeight / 2
            : host.bounds.maxY - VoiceBarNotchContract.topHeight / 2
        var x = host.bounds.minX
        while x <= host.bounds.midX {
            let before = router.primaryTapCount
            click(host, at: NSPoint(x: x, y: y), inHostCoordinates: true)
            if router.primaryTapCount > before {
                return
            }
            x += 4
        }
        XCTFail("Expected to find a clickable status icon in the leading half of the pill; bounds=\(host.bounds)")
    }

    private func clickFirstTeleprompterShow(in host: NSView, state: VoiceState) {
        var x = host.bounds.midX
        while x <= host.bounds.maxX {
            click(host, at: NSPoint(x: x, y: host.bounds.midY))
            if !state.isTeleprompterDismissed {
                return
            }
            x += 4
        }
        XCTFail("Expected a clickable Show teleprompter control in compact speaking status; bounds=\(host.bounds)")
    }

    private func drag(_ host: NSView, from start: NSPoint, to end: NSPoint) {
        guard host.hitTest(start) != nil else {
            XCTFail("Expected a hit-test target at \(start)")
            return
        }

        guard let window = host.window,
              let downEvent = mouseEvent(type: .leftMouseDown, at: start, windowNumber: window.windowNumber),
              let dragEvent = mouseEvent(type: .leftMouseDragged, at: end, windowNumber: window.windowNumber),
              let upEvent = mouseEvent(type: .leftMouseUp, at: end, windowNumber: window.windowNumber) else {
            XCTFail("Expected to create mouse events")
            return
        }

        window.sendEvent(downEvent)
        window.sendEvent(dragEvent)
        window.sendEvent(upEvent)
    }

    private func mouseEvent(type: NSEvent.EventType, at point: NSPoint, windowNumber: Int) -> NSEvent? {
        NSEvent.mouseEvent(
            with: type,
            location: point,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 0
        )
    }

    private func barViewSource() throws -> String {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: packageRoot
                .appendingPathComponent("Sources")
                .appendingPathComponent("VoiceBarUI")
                .appendingPathComponent("BarView.swift"),
            encoding: .utf8
        )
    }
}

private extension CGRect {
    var center: CGPoint {
        CGPoint(x: midX, y: midY)
    }
}
