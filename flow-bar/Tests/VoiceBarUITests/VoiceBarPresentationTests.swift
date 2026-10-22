@testable import VoiceBarUI
import XCTest
import AppKit
import SwiftUI
import QuartzCore
import OffscreenTestSupport

final class VoiceBarPresentationTests: XCTestCase {
    @MainActor
    func testBusyNoteHasReadablePixelsOnBothWallpaperPolarities() throws {
        var hostedSkip: XCTSkip?
        for light in [false, true] {
            for white in [false, true] {
                let state = VoiceState()
                state.mode = .recording
                state.hotkeyEnabled = true
                state.isConnected = true
                state.recordingMode = "ptt"
                state.sendCommand = { _ in XCTFail("contrast fixture must send no command") }
                state.selectionTextCaptureHandler = { _ in XCTFail("contrast fixture must not capture") }
                let name = "contrast-\(light ? "light" : "dark")-\(white ? "white" : "black")"
                let before = try renderSelectionFooter(state, name: name + "-before", light: light,
                                                       backdrop: white ? .white : .black)
                let busy = try renderSelectionFooter(state, name: name + "-busy", light: light,
                    backdrop: white ? .white : .black, afterMount: { state.speakSelection() })
                var readableChangedPixels = 0
                for y in 0..<busy.bitmap.pixelsHigh {
                    for x in 0..<busy.bitmap.pixelsWide {
                        let a = try XCTUnwrap(before.bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
                        let b = try XCTUnwrap(busy.bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
                        let ratio = VoiceBarContrast.ratio(
                            foreground: VoiceBarRGB(red: b.redComponent, green: b.greenComponent, blue: b.blueComponent),
                            background: VoiceBarRGB(red: a.redComponent, green: a.greenComponent, blue: a.blueComponent))
                        if ratio >= VoiceBarContrast.minimumTextRatio { readableChangedPixels += 1 }
                    }
                }
                XCTAssertEqual(before.size, busy.size)
                XCTAssertEqual(busy.presentation.geometry.leadingWingWidth, before.presentation.geometry.leadingWingWidth)
                XCTAssertEqual(busy.presentation.geometry.trailingWingWidth, before.presentation.geometry.trailingWingWidth)
                // Same policy as PasteFeedbackLayoutTests: GitHub's hosted runners draw text over the notch
                // glass at a luminance range of ~11, so only there an unreadable render skips.
                if readableChangedPixels <= 50, ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] == "true" {
                    hostedSkip = hostedSkip ?? XCTSkip("hosted runner render: \(name) has \(readableChangedPixels) readable pixels")
                } else {
                    XCTAssertGreaterThan(readableChangedPixels, 50, "Busy copy must remain visible: \(name)")
                }
            }
        }
        if let hostedSkip { throw hostedSkip }
    }

    @MainActor
    func testEndedBusyRequestDoesNotRenderInANewPreview() throws {
        let state = VoiceState()
        state.hotkeyEnabled = true
        state.isConnected = true
        state.hotkeyPhase = .pressing
        state.sendCommand = { _ in XCTFail("UI lifecycle must send no command") }
        state.selectionTextCaptureHandler = { _ in XCTFail("UI lifecycle must not capture") }
        let before = try renderSelectionFooter(state, name: "new-session-before")
        state.speakSelection()
        state.hotkeyPhase = .idle
        state.hotkeyPhase = .pressing
        let next = try renderSelectionFooter(state, name: "new-session-after")
        XCTAssertEqual(before.pixels, next.pixels, "No new Option+F5 request in this preview")
        XCTAssertEqual(before.size, next.size)
    }

    func testBusyNoteTracksTheCurrentBusyContextAndStaysAbsentInIdle() {
        for (mode, phase, message) in [(VoiceMode.recording, HotkeyPhase.holding, "Busy recording. Selection not read"),
                                       (.transcribing, .idle, "Busy transcribing. Selection not read"),
                                       (.idle, .pressing, "Busy with F5. Selection not read")] {
            XCTAssertEqual(VoiceBarPresentation.selectionBusyNote(isRequested: true, mode: mode, hotkeyPhase: phase), message)
            XCTAssertNil(VoiceBarPresentation.selectionBusyNote(isRequested: false, mode: mode, hotkeyPhase: phase))
        }
        XCTAssertNil(VoiceBarPresentation.selectionBusyNote(isRequested: true, mode: .idle, hotkeyPhase: .idle))
        XCTAssertNil(VoiceBarPresentation.selectionBusyNote(isRequested: true, mode: .speaking, hotkeyPhase: .idle))
    }

    /// NOTCH1: the note renders inside the notch, which grows a band under its top row; the top row
    /// (waveform, timer, controls) keeps its exact shell.
    @MainActor
    func testBusySelectionRendersInsideTheGrownNotchWithoutMovingTheTopRow() throws {
        for light in [false, true] {
            for (mode, phase, name) in [(VoiceMode.recording, HotkeyPhase.idle, "recording"),
                                        (.transcribing, .idle, "transcribing"),
                                        (.idle, .pressing, "preview-pressing"),
                                        (.idle, .holding, "preview-holding"),
                                        (.idle, .awaitingSecondTap, "preview-second-tap")] {
                let state = VoiceState(recentTranscriptionsLoader: { [] }, recentTranscriptionsSaver: { _ in },
                                       recentTranscriptionEntriesLoader: { [] }, recentTranscriptionEntriesSaver: { _ in })
                state.mode = mode
                state.hotkeyPhase = phase
                state.hotkeyEnabled = true
                state.isConnected = true
                state.recordingMode = "ptt"
                state.sendCommand = { _ in XCTFail("busy UI must send no command") }
                state.selectionTextCaptureHandler = { _ in XCTFail("busy UI must post no Copy") }
                let before = try renderSelectionFooter(state, name: name + (light ? "-light" : "-dark") + "-before", light: light)
                let busy = try renderSelectionFooter(state, name: name + (light ? "-light" : "-dark") + "-busy",
                                                     light: light, afterMount: { state.speakSelection() })
                XCTAssertNotEqual(before.pixels, busy.pixels, "busy feedback must reach the note band: \(name)")
                XCTAssertEqual(before.size, busy.size)
                XCTAssertEqual(busy.presentation.visualState, before.presentation.visualState)
                let top = before.presentation.geometry, grown = busy.presentation.geometry
                XCTAssertEqual(grown.topHeight, top.topHeight, "no top-row jump: \(name)")
                XCTAssertEqual(grown.leadingWingWidth, top.leadingWingWidth, "no top-row jump: \(name)")
                XCTAssertEqual(grown.trailingWingWidth, top.trailingWingWidth, "no top-row jump: \(name)")
                XCTAssertEqual(grown.lowerSurfaceHeight,
                               top.lowerSurfaceHeight + VoiceBarNotchContract.transientNoteBandHeight)
                XCTAssertEqual(state.mode, mode)
                XCTAssertEqual(state.hotkeyPhase, phase)
            }
        }
    }

    @MainActor
    func testBusyNoteClearsFromTheRenderedNotchAfterTwoSeconds() async throws {
        let state = VoiceState()
        state.mode = .recording
        state.hotkeyEnabled = true
        state.isConnected = true
        state.recordingMode = "ptt"
        state.sendCommand = { _ in XCTFail("expiry must not send commands") }
        state.selectionTextCaptureHandler = { _ in XCTFail("expiry must not capture") }
        let timerStarted = expectation(description: "busy note timer armed")
        let ticks = AsyncStream<Void>.makeStream()
        state.selectionBusyNoteSleep = { duration in
            XCTAssertEqual(duration, .seconds(2))
            timerStarted.fulfill()
            for await _ in ticks.stream { break }
        }
        defer { ticks.continuation.finish() }
        let before = try renderSelectionFooter(state, name: "expiry-before")
        let busy = try renderSelectionFooter(state, name: "expiry-busy", afterMount: { state.speakSelection() })
        XCTAssertNotEqual(before.pixels, busy.pixels)
        await fulfillment(of: [timerStarted], timeout: 5)
        XCTAssertTrue(state.showsSelectionBusyNote, "expiry is controlled by the injected timer")
        ticks.continuation.yield(())
        let expired = await settle { !state.showsSelectionBusyNote }
        XCTAssertTrue(expired, "the timer completion clears the observable note")
        let cleared = try renderSelectionFooter(state, name: "expiry-cleared")
        XCTAssertEqual(before.pixels, cleared.pixels)
        XCTAssertEqual(before.presentation, cleared.presentation)
        XCTAssertEqual(state.mode, .recording)
    }

    private final class SelectionFixturePanel: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
        override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    }

    private final class SelectionFixtureRouter: BarCommandRouting {
        func handlePrimaryTap() {}
        func handleCancel() {}
        func handleStop() {}
        func handleReplay() {}
        func handleRetranscribeHistoryEntry(recordingPath: String) {}
    }

    @MainActor
    private func renderSelectionFooter(_ state: VoiceState, name: String, light: Bool = false, backdrop: Color? = nil,
                                       afterMount: (() -> Void)? = nil) throws
        -> (pixels: Data, size: CGSize, presentation: VoiceBarNotchPresentation, bitmap: NSBitmapImageRep) {
        // Match the test process before BarView captures its initial appearance, so the
        // appearance reader does not need to mutate SwiftUI state during its first update.
        let app = NSApplication.shared
        let previousAppearance = app.appearance
        app.appearance = NSAppearance(named: light ? .aqua : .darkAqua)
        defer { app.appearance = previousAppearance }
        func resolvedPresentation(note: String?) -> VoiceBarNotchPresentation {
            let status = VoiceBarPresentation.liveStatusText(mode: state.mode, transcript: state.transcript,
                confirmationText: state.confirmationText, hotkeyPhase: state.hotkeyPhase,
                hotkeyEnabled: state.hotkeyEnabled, errorMessage: nil, commandModeState: nil, activeClipMarker: nil)
            return VoiceBarPresentation.notchPresentation(from: VoiceBarNotchOperationalInput(
                mode: state.mode, hotkeyPhase: state.hotkeyPhase, statusText: status, transientNote: note))
        }
        // NOTCH1: size every render for the grown notch (as the panel is while a busy note shows), so
        // before / busy / cleared renders compare the same pixels.
        let grown = resolvedPresentation(note: VoiceBarPresentation.selectionBusyNote(
            isRequested: true, mode: state.mode, hotkeyPhase: state.hotkeyPhase))
        let canvas = VoiceBarNotchMorphCanvasLayout.resolve(for: grown)
        let size = VoiceBarPanelLayout.make(presentation: grown, canvasGeometry: canvas.canvasGeometry).panelSize
        let host = NSHostingView(rootView: ZStack(alignment: .topLeading) {
            backdrop ?? (light ? Color(red: 0.88, green: 0.89, blue: 0.91) : Color(red: 0.16, green: 0.17, blue: 0.19))
            BarView(state: state, commandRouter: SelectionFixtureRouter(), onOpenSettings: {}, onOpenHistory: {},
                    includesPanelOutsets: true)
        }.frame(width: size.width, height: size.height).transaction { $0.disablesAnimations = true; $0.animation = nil })
        host.frame = NSRect(origin: .zero, size: size)
        host.appearance = NSAppearance(named: light ? .aqua : .darkAqua)
        let panel = SelectionFixturePanel(contentRect: NSRect(x: -20000, y: -20000, width: size.width, height: size.height),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.hasShadow = false
        panel.isExcludedFromWindowsMenu = true
        panel.hidesOnDeactivate = false
        panel.contentView = host
        panel.appearance = host.appearance
        // The merged HYG2 test policy is installed before any fixture window exists.
        XCTAssertTrue(VLOffscreenPolicyInstalled())
        defer { panel.contentView = nil }
        XCTAssertLessThan(panel.frame.maxX, 0)
        XCTAssertFalse(panel.isKeyWindow)
        XCTAssertFalse(panel.isMainWindow)
        // AppKit layout alone does not drain SwiftUI's scheduled observation update. Cross a
        // main RunLoop barrier before flushing drawing, with both animation systems disabled.
        func flushRender() {
            var reachedBarrier = false
            RunLoop.main.perform { reachedBarrier = true }
            while !reachedBarrier {
                RunLoop.main.run(mode: .default, before: .distantFuture)
            }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0
                context.allowsImplicitAnimation = false
                host.layoutSubtreeIfNeeded()
                panel.update()
                host.display()
            }
            CATransaction.flush()
        }
        flushRender()
        let initialFrame = panel.frame
        if let afterMount {
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) { afterMount() }
            flushRender()
        }
        XCTAssertEqual(panel.frame, initialFrame)
        // The note band, inside the black pill directly under the top row.
        let band = try XCTUnwrap(grown.transientNoteRect)
        let bandTop = band.minY
        let footer = NSRect(x: 0, y: host.isFlipped ? bandTop : host.bounds.height - bandTop - band.height,
                            width: host.bounds.width, height: band.height)
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: footer))
        host.cacheDisplay(in: footer, to: bitmap)
        let bytes = try XCTUnwrap(bitmap.bitmapData)
        if let output = ProcessInfo.processInfo.environment["VOICEBAR_P2B_SHOTS_DIR"] {
            let directory = URL(fileURLWithPath: output, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let full = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: full)
            try XCTUnwrap(full.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent(name + ".png"))
        }
        return (Data(bytes: bytes, count: bitmap.bytesPerRow * bitmap.pixelsHigh), size,
                resolvedPresentation(note: state.selectionFeedbackNote), bitmap)
    }

    func testNotchPresentationGivesLiveAndRetainedTeleprompterPrecedence() {
        XCTAssertEqual(
            VoiceBarPresentation.notchPresentation(
                from: VoiceBarNotchOperationalInput(
                    mode: .speaking,
                    hasTeleprompterText: true
                )
            ).visualState,
            .teleprompter
        )
        XCTAssertEqual(
            VoiceBarPresentation.notchPresentation(
                from: VoiceBarNotchOperationalInput(
                    mode: .idle,
                    hasTeleprompterText: true,
                    isTeleprompterDismissed: true,
                    isTeleprompterReadback: true
                )
            ).visualState,
            .teleprompter
        )
    }

    func testIdleTransientStatusTemporarilyReplacesRetainedReadback() {
        let presentation = VoiceBarPresentation.notchPresentation(
            from: VoiceBarNotchOperationalInput(
                mode: .idle,
                hasTeleprompterText: true,
                isTeleprompterReadback: true,
                confirmationText: "Copied"
            )
        )

        XCTAssertEqual(presentation.visualState, .compactStatus)
    }

    func testNotchPresentationMapsRecordingAndAllCompatibilityModes() {
        XCTAssertEqual(
            VoiceBarPresentation.notchPresentation(
                from: VoiceBarNotchOperationalInput(mode: .recording)
            ).visualState,
            .recording
        )

        for mode in [VoiceMode.transcribing, .speaking, .error, .disconnected] {
            XCTAssertEqual(
                VoiceBarPresentation.notchPresentation(
                    from: VoiceBarNotchOperationalInput(mode: mode)
                ).visualState,
                .compactStatus,
                "Expected compatibility shell for \(mode)"
            )
        }
    }

    func testTranscribingKeepsItsSharedWaveformEnvelopeAcrossStatusStrings() {
        let baseline = VoiceBarPresentation.notchPresentation(
            from: VoiceBarNotchOperationalInput(
                mode: .transcribing,
                statusText: "Transcribing..."
            )
        )
        let warmup = VoiceBarPresentation.notchPresentation(
            from: VoiceBarNotchOperationalInput(
                mode: .transcribing,
                statusText: "Loading speech model"
            )
        )
        XCTAssertEqual(baseline.geometry.leadingWingWidth, 47.5)
        XCTAssertEqual(baseline.geometry.trailingWingWidth, 104)
        XCTAssertEqual(baseline.geometry.topHeight, 32)
        XCTAssertEqual(warmup.geometry.leadingWingWidth, baseline.geometry.leadingWingWidth)
        XCTAssertEqual(warmup.geometry.trailingWingWidth, baseline.geometry.trailingWingWidth)
    }

    func testCompactStatesAndRecordingWingsFitTheirIndependentPayloads() {
        let launcher = VoiceBarPresentation.notchPresentation(
            from: VoiceBarNotchOperationalInput(mode: .idle, isHovered: true)
        )
        let quickTap = VoiceBarPresentation.notchPresentation(
            from: VoiceBarNotchOperationalInput(
                mode: .idle,
                hotkeyPhase: .awaitingSecondTap,
                statusText: VoiceBarPresentation.tapAgainToLockHint
            )
        )
        let recording = VoiceBarPresentation.notchPresentation(
            from: VoiceBarNotchOperationalInput(mode: .recording)
        )
        let processing = VoiceBarPresentation.notchPresentation(
            from: VoiceBarNotchOperationalInput(mode: .transcribing)
        )

        for presentation in [launcher, quickTap, processing] {
            XCTAssertEqual(presentation.geometry.leadingWingWidth, 47.5)
        }
        XCTAssertEqual(launcher.geometry.trailingWingWidth, 73.5)
        XCTAssertEqual(recording.geometry.leadingWingWidth, 73.5)
        XCTAssertEqual(recording.geometry.trailingWingWidth, 78)
        XCTAssertEqual(processing.geometry.trailingWingWidth, 104)
        XCTAssertEqual(
            quickTap.geometry.trailingWingWidth,
            min(
                WaveformLayout.coreGap + WaveformLayout.outerInset +
                    Theme.intrinsicPillStatusWidth(for: VoiceBarPresentation.tapAgainToLockHint) +
                    VoiceBarNotchContract.compactStatusTrailingSafetyInset,
                VoiceBarNotchContract.morphCanvasWingCapacity
            )
        )
        XCTAssertGreaterThan(processing.geometry.trailingWingWidth, recording.geometry.trailingWingWidth)
    }

    func testRecordingWingFitsMountedControlsInsteadOfKeepingAGhostTail() {
        let pushToTalk = VoiceBarPresentation.notchPresentation(
            from: VoiceBarNotchOperationalInput(
                mode: .recording,
                showsRecordingHold: false
            )
        )
        let vad = VoiceBarPresentation.notchPresentation(
            from: VoiceBarNotchOperationalInput(
                mode: .recording,
                showsRecordingHold: true
            )
        )

        XCTAssertEqual(pushToTalk.geometry.leadingWingWidth, 73.5)
        XCTAssertEqual(pushToTalk.geometry.trailingWingWidth, 78)
        XCTAssertEqual(vad.geometry.leadingWingWidth, 99.5)
        XCTAssertEqual(vad.geometry.trailingWingWidth, 78)
        XCTAssertEqual(vad.geometry.leadingWingWidth - pushToTalk.geometry.leadingWingWidth, 26)
    }

    func testTextBearingCompactStatusKeepsTrailingSafetyPaddingInsideStableCanvas() {
        let text = "But I don't understand why"
        let presentation = VoiceBarPresentation.notchPresentation(
            from: VoiceBarNotchOperationalInput(
                mode: .idle,
                confirmationText: text,
                statusText: text
            )
        )
        let material = VoiceBarNotchContract.material

        let contentFitWidth =
            VoiceBarNotchContract.compactCoreContentInset +
            material.compactContentInset +
            Theme.intrinsicPillStatusWidth(for: text) +
            VoiceBarNotchContract.compactStatusTrailingSafetyInset

        XCTAssertGreaterThan(
            contentFitWidth,
            VoiceBarNotchContract.morphCanvasWingCapacity
        )
        XCTAssertEqual(
            presentation.geometry.trailingWingWidth,
            VoiceBarNotchContract.morphCanvasWingCapacity
        )
    }

    func testNotchPresentationMapsIdleTransientSurfacesToCompactStatus() {
        let inputs: [VoiceBarNotchOperationalInput] = [
            VoiceBarNotchOperationalInput(mode: .idle, confirmationText: "Pasted"),
            VoiceBarNotchOperationalInput(
                mode: .idle,
                commandModeState: CommandModeState(
                    phase: .applying,
                    operation: "replace_selection",
                    prompt: "Rewrite"
                )
            ),
            VoiceBarNotchOperationalInput(
                mode: .idle,
                activeClipMarker: ClipMarkerState(
                    id: "clip-1",
                    label: "Action item",
                    source: "command",
                    status: "marked"
                )
            ),
            VoiceBarNotchOperationalInput(mode: .idle, queueDepth: 1),
            VoiceBarNotchOperationalInput(mode: .idle, keepsPasteFlowEnvelope: true),
            VoiceBarNotchOperationalInput(mode: .idle, hotkeyPhase: .pressing),
        ]

        for input in inputs {
            XCTAssertEqual(
                VoiceBarPresentation.notchPresentation(from: input).visualState,
                .compactStatus
            )
        }
    }

    func testCollapsedIdleOverridesEveryTransientEnvelopeUntilActivityReturns() {
        let inputs = [
            VoiceBarNotchOperationalInput(
                mode: .idle,
                confirmationText: "Pasted",
                isCollapsed: true
            ),
            VoiceBarNotchOperationalInput(
                mode: .idle,
                queueDepth: 1,
                isCollapsed: true
            ),
            VoiceBarNotchOperationalInput(
                mode: .idle,
                keepsPasteFlowEnvelope: true,
                isCollapsed: true
            ),
        ]

        for input in inputs {
            XCTAssertEqual(
                VoiceBarPresentation.notchPresentation(from: input).visualState,
                .idle
            )
        }
    }

    func testHoverActivityReopensAPreviouslyCollapsedIdlePresentation() {
        XCTAssertEqual(
            VoiceBarPresentation.notchPresentation(
                from: VoiceBarNotchOperationalInput(
                    mode: .idle,
                    isHovered: true,
                    isCollapsed: true
                )
            ).visualState,
            .hoverLauncher
        )
    }

    func testNotchPresentationHoldsPlainIdleThroughTheCollapseGraceWindow() {
        XCTAssertEqual(
            VoiceBarPresentation.notchPresentation(
                from: VoiceBarNotchOperationalInput(mode: .idle, isHovered: true)
            ).visualState,
            .hoverLauncher
        )
        XCTAssertEqual(
            VoiceBarPresentation.notchPresentation(
                from: VoiceBarNotchOperationalInput(mode: .idle, isKeyboardFocused: true)
            ).visualState,
            .hoverLauncher
        )
        XCTAssertEqual(
            VoiceBarPresentation.notchPresentation(
                from: VoiceBarNotchOperationalInput(mode: .idle)
            ).visualState,
            .hoverLauncher
        )
    }

    func testHiddenReadbackKeepsTeleprompterEnvelopeForRestoreControls() {
        XCTAssertTrue(
            VoiceBarPresentation.reservesTeleprompterEnvelope(
                hasText: true,
                isDismissed: true,
                isReadback: true
            )
        )
        XCTAssertFalse(
            VoiceBarPresentation.reservesTeleprompterEnvelope(
                hasText: true,
                isDismissed: true,
                isReadback: false
            )
        )
    }

    func testRecordingContentShowsWaveformWithoutListeningLabelByDefault() {
        XCTAssertEqual(
            VoiceBarPresentation.recordingContent(hotkeyPhase: .idle),
            VoiceBarRecordingContent(
                statusText: "",
                showsWaveform: true,
                usesPulsingLabelOpacity: false
            )
        )
    }

    func testRecordingContentShowsOnlyWaveformWhileHolding() {
        XCTAssertEqual(
            VoiceBarPresentation.recordingContent(hotkeyPhase: .holding),
            VoiceBarRecordingContent(
                statusText: "",
                showsWaveform: true,
                usesPulsingLabelOpacity: false
            )
        )
    }

    func testRecordingHoldControlIsVADOnlyAndAccessible() {
        XCTAssertNil(
            VoiceBarPresentation.recordingHoldControl(
                mode: .idle,
                recordingMode: "vad",
                isEngaged: false
            )
        )
        XCTAssertNil(
            VoiceBarPresentation.recordingHoldControl(
                mode: .recording,
                recordingMode: "ptt",
                isEngaged: false
            )
        )
        XCTAssertEqual(
            VoiceBarPresentation.recordingHoldControl(
                mode: .recording,
                recordingMode: "vad",
                isEngaged: false
            ),
            VoiceBarRecordingHoldControl(
                iconName: "lock.fill",
                accessibilityLabel: "Lock recording",
                accessibilityHint: "Keep recording through silence",
                isSelected: false
            )
        )
        XCTAssertEqual(
            VoiceBarPresentation.recordingHoldControl(
                mode: .recording,
                recordingMode: "vad",
                isEngaged: true
            ),
            VoiceBarRecordingHoldControl(
                iconName: "lock.fill",
                accessibilityLabel: "Unlock recording",
                accessibilityHint: "Resume automatic silence stop",
                isSelected: true
            )
        )
    }

    func testQueuePreviewSummarizesCurrentNextAndOverflow() {
        let preview = VoiceBarPresentation.queuePreview(from: [
            QueueItemState(
                text: "Current line",
                voice: "jenny",
                priority: "normal",
                isCurrent: true,
                progress: 0.35
            ),
            QueueItemState(
                text: "Queued line",
                voice: "jenny",
                priority: "high",
                isCurrent: false,
                progress: 0
            ),
            QueueItemState(
                text: "Third line",
                voice: "jenny",
                priority: "normal",
                isCurrent: false,
                progress: 0
            ),
            QueueItemState(
                text: "Fourth line",
                voice: "jenny",
                priority: "low",
                isCurrent: false,
                progress: 0
            ),
        ])

        XCTAssertEqual(preview.currentText, "Current line")
        XCTAssertEqual(preview.nextText, "Queued line")
        XCTAssertEqual(preview.overflowCount, 2)
        XCTAssertEqual(preview.progress, 0.35, accuracy: 0.001)
    }

    func testIdleStatusTextUsesHotkeyHintsBeforeReady() {
        XCTAssertEqual(
            VoiceBarPresentation.idleStatusText(
                transcript: "",
                confirmationText: nil,
                hotkeyPhase: .pressing,
                hotkeyEnabled: true
            ),
            "Hold to talk"
        )

        XCTAssertEqual(
            VoiceBarPresentation.idleStatusText(
                transcript: "",
                confirmationText: nil,
                hotkeyPhase: .holding,
                hotkeyEnabled: true
            ),
            "Release to send"
        )

        XCTAssertEqual(
            VoiceBarPresentation.idleStatusText(
                transcript: "",
                confirmationText: nil,
                hotkeyPhase: .awaitingSecondTap,
                hotkeyEnabled: true
            ),
            "Tap again to lock"
        )
    }

    func testIdleStatusTextFallsBackToConfirmationTranscriptAndReady() {
        XCTAssertEqual(
            VoiceBarPresentation.idleStatusText(
                transcript: "latest transcript line",
                confirmationText: "Pasted",
                hotkeyPhase: .idle,
                hotkeyEnabled: true
            ),
            "Pasted"
        )

        XCTAssertEqual(
            VoiceBarPresentation.idleStatusText(
                transcript: "one two three four",
                confirmationText: nil,
                hotkeyPhase: .idle,
                hotkeyEnabled: true
            ),
            "F5 to talk"
        )

        XCTAssertEqual(
            VoiceBarPresentation.idleStatusText(
                transcript: "",
                confirmationText: nil,
                hotkeyPhase: .idle,
                hotkeyEnabled: true
            ),
            "F5 to talk"
        )

        XCTAssertEqual(
            VoiceBarPresentation.idleStatusText(
                transcript: "",
                confirmationText: nil,
                hotkeyPhase: .idle,
                hotkeyEnabled: false
            ),
            "Enable hotkey"
        )
    }

    func testLiveStatusTextUsesFallbackLabelDuringTranscribing() {
        XCTAssertEqual(
            VoiceBarPresentation.liveStatusText(
                mode: .transcribing,
                transcript: "ignored",
                confirmationText: nil,
                hotkeyPhase: .idle,
                hotkeyEnabled: true,
                errorMessage: nil,
                transcribingStatusText: nil,
                commandModeState: nil,
                activeClipMarker: nil
            ),
            "Transcribing..."
        )
    }

    func testLiveStatusTextUsesFallbackLabelWhenTranscribingStatusIsWhitespace() {
        XCTAssertEqual(
            VoiceBarPresentation.liveStatusText(
                mode: .transcribing,
                transcript: "ignored",
                confirmationText: nil,
                hotkeyPhase: .idle,
                hotkeyEnabled: true,
                errorMessage: nil,
                transcribingStatusText: "   \n",
                commandModeState: nil,
                activeClipMarker: nil
            ),
            "Transcribing..."
        )
    }

    func testLiveStatusTextCanSurfaceTranscribingWarmupLabel() {
        XCTAssertEqual(
            VoiceBarPresentation.liveStatusText(
                mode: .transcribing,
                transcript: "",
                confirmationText: nil,
                hotkeyPhase: .idle,
                hotkeyEnabled: true,
                errorMessage: nil,
                transcribingStatusText: "Loading speech model",
                commandModeState: nil,
                activeClipMarker: nil
            ),
            "Loading speech model"
        )
    }

    func testDisconnectedStatusDoesNotShowHotkeyPrompts() {
        XCTAssertEqual(
            VoiceBarPresentation.liveStatusText(
                mode: .disconnected,
                transcript: "",
                confirmationText: nil,
                hotkeyPhase: .awaitingSecondTap,
                hotkeyEnabled: true,
                errorMessage: nil,
                transcribingStatusText: nil,
                commandModeState: nil,
                activeClipMarker: nil
            ),
            "Disconnected"
        )
    }

    func testErrorStatusNormalizesRawBusyError() {
        XCTAssertEqual(
            VoiceBarPresentation.liveStatusText(
                mode: .error,
                transcript: "",
                confirmationText: nil,
                hotkeyPhase: .idle,
                hotkeyEnabled: true,
                errorMessage: " busy ",
                transcribingStatusText: nil,
                commandModeState: nil,
                activeClipMarker: nil
            ),
            "Busy"
        )
    }

    func testNativeBackgroundDraggingIsDisabledAcrossVoiceStates() {
        XCTAssertFalse(VoiceBarPresentation.isPanelDraggable(mode: .idle))
        XCTAssertFalse(VoiceBarPresentation.isPanelDraggable(mode: .error))
        XCTAssertFalse(VoiceBarPresentation.isPanelDraggable(mode: .disconnected))
        XCTAssertFalse(VoiceBarPresentation.isPanelDraggable(mode: .recording))
        XCTAssertFalse(VoiceBarPresentation.isPanelDraggable(mode: .transcribing))
        XCTAssertFalse(VoiceBarPresentation.isPanelDraggable(mode: .speaking))
    }

    func testTranscriptPreviewUsesConfirmationTextOnlyWhenIdleAndUnclaimed() {
        XCTAssertEqual(
            VoiceBarPresentation.transcriptPreviewText(
                mode: .idle,
                confirmationText: " Copied ",
                commandModeState: nil,
                activeClipMarker: nil
            ),
            "Copied"
        )

        XCTAssertNil(
            VoiceBarPresentation.transcriptPreviewText(
                mode: .transcribing,
                confirmationText: "Copied",
                commandModeState: nil,
                activeClipMarker: nil
            )
        )

        XCTAssertNil(
            VoiceBarPresentation.transcriptPreviewText(
                mode: .idle,
                confirmationText: "Copied",
                commandModeState: CommandModeState(
                    phase: .done,
                    operation: "replace_selection",
                    prompt: nil
                ),
                activeClipMarker: nil
            )
        )

        XCTAssertNil(
            VoiceBarPresentation.transcriptPreviewText(
                mode: .idle,
                confirmationText: "Copied",
                commandModeState: nil,
                activeClipMarker: ClipMarkerState(
                    id: "clip-1",
                    label: "Action item",
                    source: "command",
                    status: "marked"
                )
            )
        )
    }

    func testTranscriptPreviewLayoutKeepsShortConfirmationsCompact() {
        let short = VoiceBarPresentation.transcriptPreviewLayout(for: "Short sentence into an input.")

        XCTAssertEqual(short.height, Theme.pillCompactHeight)
        XCTAssertEqual(short.lineLimit, 1)
        XCTAssertFalse(short.isMultiline)
    }

    func testTranscriptPreviewLayoutUsesTwoLinesForLongConfirmations() {
        let long = VoiceBarPresentation.transcriptPreviewLayout(
            for: "This is a long transcript preview that should be allowed to wrap onto two lines instead of making the short confirmation state feel oversized."
        )

        XCTAssertEqual(long.height, Theme.pillTranscriptPreviewHeight)
        XCTAssertEqual(long.lineLimit, 2)
        XCTAssertTrue(long.isMultiline)
    }

    func testLiveStatusTextPrefersCommandModeAndClipMarkerStatus() {
        XCTAssertEqual(
            VoiceBarPresentation.liveStatusText(
                mode: .idle,
                transcript: "",
                confirmationText: nil,
                hotkeyPhase: .idle,
                hotkeyEnabled: true,
                errorMessage: nil,
                transcribingStatusText: nil,
                commandModeState: CommandModeState(
                    phase: .applying,
                    operation: "replace_selection",
                    prompt: "Rewrite selection"
                ),
                activeClipMarker: nil
            ),
            "Command: Rewrite selection"
        )

        XCTAssertEqual(
            VoiceBarPresentation.liveStatusText(
                mode: .idle,
                transcript: "",
                confirmationText: nil,
                hotkeyPhase: .idle,
                hotkeyEnabled: true,
                errorMessage: nil,
                transcribingStatusText: nil,
                commandModeState: nil,
                activeClipMarker: ClipMarkerState(
                    id: "clip-1",
                    label: "Action item",
                    source: "command",
                    status: "marked"
                )
            ),
            "Clip marked: Action item"
        )
    }

    func testHotkeyPermissionHintIsSpecificToMissingPermission() {
        XCTAssertEqual(
            VoiceBarPresentation.hotkeyPermissionHint(
                hotkeyEnabled: false,
                missingPermissions: [.inputMonitoring]
            ),
            "Hotkey: enable Input Monitoring"
        )

        XCTAssertEqual(
            VoiceBarPresentation.hotkeyPermissionHint(
                hotkeyEnabled: false,
                missingPermissions: [.accessibility]
            ),
            "Hotkey: enable Accessibility"
        )
    }

    func testHotkeyPermissionHintHandlesBothPermissions() {
        XCTAssertEqual(
            VoiceBarPresentation.hotkeyPermissionHint(
                hotkeyEnabled: false,
                missingPermissions: [.inputMonitoring, .accessibility]
            ),
            "Hotkey: enable Accessibility + Input Monitoring"
        )
    }
}
