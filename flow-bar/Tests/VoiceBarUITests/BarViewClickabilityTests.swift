import AppKit
import SwiftUI
@testable import VoiceBarUI
import XCTest

@MainActor
final class BarViewClickabilityTests: XCTestCase {
    private var windows: [NSWindow] = []

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

    func testStopControlRestoresTheCircularContainerAndCentersTheSquare() throws {
        let stop = VoiceBarNotchControlOptics.resolve(for: "stop.fill")
        let replay = VoiceBarNotchControlOptics.resolve(for: "arrow.counterclockwise")
        let eye = VoiceBarNotchControlOptics.resolve(for: "eye")
        let eyeSlash = VoiceBarNotchControlOptics.resolve(for: "eye.slash")

        XCTAssertEqual(stop.pointSize, 8)
        XCTAssertEqual(stop.offsetX, 0)
        XCTAssertEqual(stop.offsetY, 0)
        XCTAssertEqual(eye.pointSize, eyeSlash.pointSize)
        XCTAssertLessThan(eye.pointSize, replay.pointSize)

        let source = try barViewSource()
        let buttonStart = try XCTUnwrap(source.range(of: "private func notchButton"))
        let buttonSource = source[buttonStart.lowerBound...]
        XCTAssertTrue(buttonSource.contains("VoiceBarNotchControlOptics.resolve(for: icon)"))
        XCTAssertTrue(buttonSource.contains(": notchPrimaryLabelColor"))
        XCTAssertTrue(source.contains("notchPalette.primary.color"))
        XCTAssertFalse(source.contains("Color(nsColor: .labelColor)"))
        XCTAssertTrue(buttonSource.contains("icon == \"stop.fill\""))
        XCTAssertTrue(buttonSource.contains("Circle()"))
        XCTAssertTrue(buttonSource.contains("compactControlSize"))
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

    func testIdleStatusMicReusesLauncherMicOpticsAndPrimaryForeground() throws {
        let source = try barViewSource()
        let statusStart = try XCTUnwrap(source.range(of: "private var statusIcon"))
        let imageStart = try XCTUnwrap(source.range(of: "private var statusIconImage"))
        let iconNameStart = try XCTUnwrap(
            source.range(of: "private var iconName", range: imageStart.upperBound ..< source.endIndex)
        )
        let statusIconImage = source[imageStart.lowerBound ..< iconNameStart.lowerBound]

        XCTAssertTrue(
            statusIconImage.contains("VoiceBarNotchControlOptics.resolve(for: iconName)"),
            "the hotkey-transition mic must use the same optical sizing contract as the launcher mic"
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
            leading.range(of: "case .compactStatus:", range: recordingStart.upperBound ..< leading.endIndex)
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
            trailing.range(of: "case .compactStatus:", range: recordingStart.upperBound ..< trailing.endIndex)
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

        XCTAssertTrue(leading.contains("if state.mode == .transcribing"))
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

    func testQueuedSpeechUsesTheExistingQueuePreviewInTheNativeShell() throws {
        let source = try barViewSource()

        XCTAssertTrue(source.contains("if state.queueItems.count > 1"))
        XCTAssertTrue(source.contains("VoiceBarPresentation.queuePreview(from: state.queueItems)"))
    }

    func testOpenPopoversKeepTheLauncherMountedAfterPointerExit() throws {
        let source = try barViewSource()

        XCTAssertTrue(source
            .contains("private var keepsLauncherMounted: Bool {\n        isHistoryPresented || isVocabularyPresented"))
        XCTAssertTrue(source.contains("vocabularyButton"))
        XCTAssertTrue(source.contains("accessibilityLabel: \"Dictionary\""))
        XCTAssertTrue(source.contains("synchronizeLauncherRetention()"))
    }

    func testDictionaryButtonMountsOnlyInHoveredLauncher() throws {
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
            trailing.components(separatedBy: "case .hoverLauncher:").dropFirst().first?
                .components(separatedBy: "case .recording:").first
        )
        let active = try XCTUnwrap(trailing.components(separatedBy: "case .recording:").dropFirst().first)
        let leading = String(source[leadingStart.lowerBound ..< trailingStart.lowerBound])
        let teleprompterLeading = try XCTUnwrap(
            leading.components(separatedBy: "case .teleprompter:").dropFirst().first
        )

        XCTAssertTrue(hover.contains("historyButton"))
        XCTAssertTrue(hover.contains("vocabularyButton"))
        XCTAssertFalse(active.contains("historyButton"))
        XCTAssertFalse(active.contains("vocabularyButton"))
        XCTAssertTrue(teleprompterLeading.contains("EmptyView()"))
        XCTAssertFalse(teleprompterLeading.contains("vocabularyButton"))
        XCTAssertFalse(teleprompterLeading.contains("Dictionary"))
    }

    func testDictionaryPopoverOpensBelowTheTopEdgeNotch() throws {
        let source = try barViewSource()
        let buttonStart = try XCTUnwrap(source.range(of: "private var vocabularyButton"))
        let popoverStart = try XCTUnwrap(
            source.range(of: "private var vocabularyPopover", range: buttonStart.upperBound ..< source.endIndex)
        )
        let button = source[buttonStart.lowerBound ..< popoverStart.lowerBound]

        XCTAssertTrue(button.contains(".popover(isPresented: $isVocabularyPresented, arrowEdge: .top)"))
        XCTAssertFalse(button.contains("arrowEdge: .bottom"))
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

    func testPanelAppKitMouseEventsHitOnlyMountedControls() {
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
        click(host, at: controlRects[2].center)
        click(host, at: controlRects[1].center)
        click(host, at: controlRects[0].center)

        XCTAssertEqual(router.stopCount, 1)
        XCTAssertEqual(router.cancelCount, 1)
        XCTAssertEqual(sentCommand?["cmd"] as? String, "set_recording_hold")
        XCTAssertEqual(sentCommand?["engaged"] as? Bool, true)

        let gapBesideStop = NSPoint(x: controlRects[2].maxX + 3, y: controlRects[2].midY)
        let belowStop = NSPoint(x: controlRects[2].midX, y: controlRects[2].minY - 2)
        let waveform = NSPoint(
            x: layout.visibleContentRect.minX + layout.presentation.geometry.coreOriginX
                + layout.presentation.geometry.coreWidth + WaveformLayout.coreGap + 10,
            y: controlRects[2].midY
        )
        XCTAssertNil(host.hitTest(gapBesideStop))
        XCTAssertNil(host.hitTest(belowStop))
        XCTAssertNil(host.hitTest(waveform))
        XCTAssertFalse(panel.startsDrag(at: gapBesideStop))
        XCTAssertFalse(panel.shouldHandleContextMenu(at: waveform))
    }

    func testTeleprompterAppKitMouseEventsPassThroughItsBody() {
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
        let formerDictionaryLane = NSPoint(
            x: layout.visibleContentRect.minX + 108,
            y: layout.visibleContentRect.minY + 212
        )

        XCTAssertFalse(controlRects.isEmpty)
        XCTAssertNotNil(host.hitTest(controlRects[0].center))
        XCTAssertNil(host.hitTest(bodyPoint))
        XCTAssertNil(host.hitTest(formerDictionaryLane))
        XCTAssertFalse(panel.startsDrag(at: bodyPoint))
        XCTAssertFalse(panel.shouldHandleContextMenu(at: formerDictionaryLane))
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

    private func makeInteractivePanelHost(
        state: VoiceState,
        router: SpyCommandRouter,
        configuration: VoiceBarNotchInteractionConfiguration
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
                includesPanelOutsets: true
            )
        )
        host.frame = NSRect(origin: .zero, size: layout.panelSize)
        host.activeHitTestProvider = { layout.containsInteractiveContent($0) }
        let panel = FloatingPillPanel(content: host)
        panel.activeHitTestProvider = { layout.containsInteractiveContent($0) }
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

    private func click(_ host: NSView, at point: NSPoint) {
        guard host.hitTest(point) != nil else {
            XCTFail("Expected a hit-test target at \(point)")
            return
        }

        guard let window = host.window,
              let downEvent = mouseEvent(type: .leftMouseDown, at: point, windowNumber: window.windowNumber),
              let upEvent = mouseEvent(type: .leftMouseUp, at: point, windowNumber: window.windowNumber) else {
            XCTFail("Expected to create mouse events")
            return
        }

        window.sendEvent(downEvent)
        window.sendEvent(upEvent)
    }

    private func clickFirstPrimaryTap(in host: NSView, router: SpyCommandRouter) {
        var x = host.bounds.minX
        while x <= host.bounds.midX {
            let before = router.primaryTapCount
            click(host, at: NSPoint(x: x, y: host.bounds.midY))
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
