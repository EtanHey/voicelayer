import AppKit
@testable import VoiceBar
@testable import VoiceBarUI
import XCTest

final class AppLifecycleTests: XCTestCase {
    private final class PointerProbe: @unchecked Sendable {
        var isInside = true
    }

    @MainActor
    func testPanelMousePassthroughCapturesRenderedSurfaceButNotCanvasMargins() {
        let presentation = VoiceBarPresentation.notchPresentation(
            from: VoiceBarNotchOperationalInput(mode: .idle, isHovered: true)
        )
        let canvas = VoiceBarNotchMorphCanvasLayout.resolve(for: presentation)
        let layout = VoiceBarPanelLayout.make(
            presentation: presentation,
            interactionConfiguration: VoiceBarNotchInteractionConfiguration(
                leadingControlCount: 1,
                trailingControlCountFromCore: 2
            ),
            canvasGeometry: canvas.canvasGeometry
        )
        let panel = NSPanel(
            contentRect: CGRect(origin: .zero, size: layout.panelSize),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )

        AppDelegate.applyPanelMouseEventPassthrough(
            panel,
            layout: layout,
            pointer: CGPoint(x: 1, y: 1),
            isIsolatedCapture: false
        )
        XCTAssertTrue(panel.ignoresMouseEvents)

        AppDelegate.applyPanelMouseEventPassthrough(
            panel,
            layout: layout,
            pointer: CGPoint(
                x: layout.visibleContentRect.minX + 24,
                y: layout.visibleContentRect.minY + 16
            ),
            isIsolatedCapture: false
        )
        XCTAssertFalse(panel.ignoresMouseEvents)

        AppDelegate.applyPanelMouseEventPassthrough(
            panel,
            layout: layout,
            pointer: CGPoint(
                x: layout.visibleContentRect.minX + presentation.geometry.coreMidX,
                y: layout.visibleContentRect.minY + 16
            ),
            isIsolatedCapture: false
        )
        XCTAssertFalse(panel.ignoresMouseEvents)

        AppDelegate.applyPanelMouseEventPassthrough(
            panel,
            layout: layout,
            pointer: CGPoint(x: 1, y: 1),
            isIsolatedCapture: true
        )
        XCTAssertFalse(panel.ignoresMouseEvents)
    }

    @MainActor
    func testPanelMousePassthroughKeepsAVisibleSurfaceEligibleAcrossControlChanges() {
        let presentation = VoiceBarPresentation.notchPresentation(
            from: VoiceBarNotchOperationalInput(mode: .idle, isHovered: true)
        )
        let controlLayout = VoiceBarPanelLayout.make(
            presentation: presentation,
            interactionConfiguration: VoiceBarNotchInteractionConfiguration(
                leadingControlCount: 1,
                trailingControlCountFromCore: 2
            )
        )
        let idleLayout = VoiceBarPanelLayout.make(
            presentation: presentation,
            interactionConfiguration: .none
        )
        let pointer = CGPoint(
            x: controlLayout.visibleContentRect.minX + 282,
            y: controlLayout.visibleContentRect.minY + 16
        )
        let panel = NSPanel(
            contentRect: CGRect(origin: .zero, size: controlLayout.panelSize),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )

        AppDelegate.applyPanelMouseEventPassthrough(
            panel,
            layout: controlLayout,
            pointer: pointer,
            isIsolatedCapture: false
        )
        XCTAssertFalse(panel.ignoresMouseEvents)

        AppDelegate.applyPanelMouseEventPassthrough(
            panel,
            layout: idleLayout,
            pointer: pointer,
            isIsolatedCapture: false
        )
        XCTAssertFalse(panel.ignoresMouseEvents)
    }

    func testInteractionConfigurationTracksMountedOperationalControls() {
        let state = VoiceState()

        XCTAssertEqual(
            AppDelegate.notchInteractionConfiguration(for: state, visualState: .idle),
            .none
        )

        XCTAssertEqual(
            AppDelegate.notchInteractionConfiguration(for: state, visualState: .hoverLauncher),
            VoiceBarNotchInteractionConfiguration(
                leadingControlCount: 1,
                trailingControlCountFromCore: 2
            )
        )

        state.mode = .recording
        state.recordingMode = "ptt"
        XCTAssertEqual(
            AppDelegate.notchInteractionConfiguration(for: state, visualState: .recording),
            VoiceBarNotchInteractionConfiguration(leadingControlCount: 2)
        )
        state.recordingMode = "vad"
        XCTAssertEqual(
            AppDelegate.notchInteractionConfiguration(for: state, visualState: .recording),
            VoiceBarNotchInteractionConfiguration(leadingControlCount: 3)
        )

        state.mode = .transcribing
        XCTAssertEqual(
            AppDelegate.notchInteractionConfiguration(for: state, visualState: .compactStatus),
            VoiceBarNotchInteractionConfiguration(
                trailingControlCountFromOuter: 1,
                trailingOuterInset: WaveformLayout.outerInset
            )
        )

        state.mode = .speaking
        state.canReplay = true
        XCTAssertEqual(
            AppDelegate.notchInteractionConfiguration(for: state, visualState: .teleprompter),
            VoiceBarNotchInteractionConfiguration(
                lowerControlCount: 3
            )
        )
    }

    @MainActor
    func testPanelContextMenuUsesRenderedSurfaceWhileDragUsesExactControls() {
        let layout = VoiceBarPanelLayout.make(
            presentation: VoiceBarPresentation.notchPresentation(
                from: VoiceBarNotchOperationalInput(mode: .idle, isHovered: true)
            ),
            interactionConfiguration: VoiceBarNotchInteractionConfiguration(
                leadingControlCount: 1,
                trailingControlCountFromCore: 2
            )
        )
        let panel = FloatingPillPanel(content: NSView(frame: CGRect(origin: .zero, size: layout.panelSize)))
        panel.activeHitTestProvider = { layout.containsInteractiveContent($0) }
        panel.contextMenuHitTestProvider = { layout.containsVisibleSurface($0) }
        let mic = CGPoint(
            x: layout.visibleContentRect.minX + 24,
            y: layout.visibleContentRect.minY + 16
        )
        let glass = CGPoint(
            x: layout.visibleContentRect.minX + layout.presentation.geometry.coreMidX,
            y: layout.visibleContentRect.minY + 16
        )

        XCTAssertTrue(panel.startsDrag(at: mic))
        XCTAssertTrue(panel.shouldHandleContextMenu(at: mic))
        XCTAssertFalse(panel.startsDrag(at: glass))
        XCTAssertTrue(layout.containsVisibleSurface(glass))
        XCTAssertTrue(panel.shouldHandleContextMenu(at: glass))
        XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel))
        XCTAssertFalse(panel.canBecomeMain)
    }

    @MainActor
    func testEveryNotchStateAdmitsRenderedPixelsButRejectsTransparentMargins() {
        for visualState in VoiceBarNotchVisualState.allCases {
            let presentation = VoiceBarNotchPresentation.resolve(
                hasTeleprompter: visualState == .teleprompter,
                isRecording: visualState == .recording,
                hasCompactStatus: visualState == .compactStatus,
                isHovered: visualState == .hoverLauncher,
                isKeyboardFocused: false
            )
            let layout = VoiceBarPanelLayout.make(presentation: presentation)
            let panel = FloatingPillPanel(
                content: NSView(frame: CGRect(origin: .zero, size: layout.panelSize))
            )
            panel.activeHitTestProvider = { layout.containsInteractiveContent($0) }
            panel.contextMenuHitTestProvider = { layout.containsVisibleSurface($0) }
            let renderedCore = CGPoint(
                x: layout.visibleContentRect.minX + presentation.geometry.coreMidX,
                y: layout.visibleContentRect.minY + presentation.geometry.lowerSurfaceHeight
                    + (presentation.geometry.topHeight / 2)
            )
            let transparentMargin = CGPoint(x: 1, y: 1)

            XCTAssertTrue(layout.containsVisibleSurface(renderedCore), "state=\(visualState)")
            XCTAssertTrue(panel.shouldHandleContextMenu(at: renderedCore), "state=\(visualState)")
            XCTAssertFalse(layout.containsVisibleSurface(transparentMargin), "state=\(visualState)")
            XCTAssertFalse(panel.shouldHandleContextMenu(at: transparentMargin), "state=\(visualState)")
        }
    }

    func testGlobalPointerProcessingRepositionsBeforeEvaluatingLocalHitState() throws {
        let source = try voiceBarAppSource()
        let handlerStart = try XCTUnwrap(source.range(of: "private func handleMouseMoved()"))
        let handlerEnd = try XCTUnwrap(
            source.range(
                of: "private func synchronizePanelMouseEventPassthrough",
                range: handlerStart.upperBound ..< source.endIndex
            )
        )
        let handler = source[handlerStart.lowerBound ..< handlerEnd.lowerBound]
        let reposition = try XCTUnwrap(handler.range(of: "positionPanel(panel, on:"))
        let localPoint = try XCTUnwrap(handler.range(of: "panel.convertPoint(fromScreen:"))
        let pointerUpdate = try XCTUnwrap(handler.range(of: "panelPointerMovementHandler(localPoint)"))

        XCTAssertLessThan(reposition.lowerBound, localPoint.lowerBound)
        XCTAssertLessThan(localPoint.lowerBound, pointerUpdate.lowerBound)
    }

    func testProductSurfaceControlsCannotReachApplicationTermination() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let uiSourceDirectory = repoRoot.appendingPathComponent("flow-bar/Sources/VoiceBarUI")
        let uiSources = try FileManager.default.contentsOfDirectory(
            at: uiSourceDirectory,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "swift" && $0.lastPathComponent != "VoiceBarMenu.swift" }
        let surfaceSources = uiSources + [
            repoRoot.appendingPathComponent("flow-bar/Sources/VoiceBar/VoiceBarCommandRouter.swift"),
        ]

        for sourceURL in surfaceSources {
            let source = try String(contentsOf: sourceURL, encoding: .utf8)
            XCTAssertFalse(
                source.contains("NSApplication.shared.terminate") ||
                    source.contains("NSApp.terminate") ||
                    source.contains("Quit VoiceBar"),
                "product-surface controls must dismiss/cancel/stop without quitting: \(sourceURL.lastPathComponent)"
            )
        }

        let menuBarSource = try String(
            contentsOf: repoRoot.appendingPathComponent("flow-bar/Sources/VoiceBarUI/VoiceBarMenu.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(menuBarSource.contains("Quit VoiceBar"), "the menu-bar quit remains the user exit path")
    }

    func testIsolatedQARejectsExternalQuitUntilVoiceBarAuthorizesItsOwnExit() {
        var policy = VoiceBarTerminationPolicy()

        XCTAssertEqual(
            policy.reply(enforcesSingleton: false),
            .terminateCancel,
            "a canonical launch must not evict an isolated proof process via Quit AppleEvent"
        )

        policy.authorize(.menuBar)
        XCTAssertEqual(policy.reply(enforcesSingleton: false), .terminateNow)
        XCTAssertEqual(
            policy.reply(enforcesSingleton: false),
            .terminateCancel,
            "application-owned authorization is single-use"
        )

        policy.authorize(.internalFailure)
        XCTAssertEqual(policy.reply(enforcesSingleton: false), .terminateNow)
    }

    func testCanonicalResidentStillAcceptsExternalSingletonTermination() {
        var policy = VoiceBarTerminationPolicy()

        XCTAssertEqual(policy.reply(enforcesSingleton: true), .terminateNow)
    }

    func testAppTerminationUsesPreparedMicShutdownAndIsolatedDeregistration() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repoRoot.appendingPathComponent("flow-bar/Sources/VoiceBar/VoiceBarApp.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("private func performTerminationCleanup()"))
        XCTAssertTrue(source.contains("VoiceBarInstanceIsolationRegistry.unregister"))
        XCTAssertTrue(source.contains("audioLevelMonitor.shutdown()"))
        XCTAssertTrue(source.contains("signal(SIGTERM, SIG_IGN)"))
        XCTAssertTrue(source.contains("requestTermination(.internalFailure)"))
    }

    func testParallelQARegistersItsExactPIDBeforeShowingAnOffscreenSurface() throws {
        let source = try voiceBarAppSource()
        let guardStart = try XCTUnwrap(source.range(of: "private func enforceCanonicalSingleInstance()"))
        let electionStart = try XCTUnwrap(
            source.range(
                of: "private func performCanonicalSingleInstanceElection",
                range: guardStart.upperBound ..< source.endIndex
            )
        )
        let guardSource = source[guardStart.lowerBound ..< electionStart.lowerBound]

        XCTAssertTrue(guardSource.contains("registerCurrentIsolatedInstance()"))
        XCTAssertTrue(guardSource.contains("guard defaultsEnforceSingleton else"))
        XCTAssertTrue(source.contains("VoiceBarInstanceIsolationRegistry.register("))
        XCTAssertTrue(source.contains("isolatedInstanceMarkerPID = myPID"))
    }

    // MARK: - Context menu snooze toggle

    func testContextMenuShowsHideWhenNotSnoozed() {
        let controller = PillContextMenuController()
        controller.isSnoozedProvider = { false }

        let menu = controller.makeMenu()
        let titles = (0 ..< menu.numberOfItems).compactMap { menu.item(at: $0)?.title }

        XCTAssertTrue(titles.contains("Hide for 1 hour"))
        XCTAssertFalse(titles.contains("Show VoiceBar"))
    }

    func testContextMenuShowsUnsnoozeWhenSnoozed() {
        let controller = PillContextMenuController()
        controller.isSnoozedProvider = { true }

        let menu = controller.makeMenu()
        let titles = (0 ..< menu.numberOfItems).compactMap { menu.item(at: $0)?.title }

        XCTAssertTrue(titles.contains("Show VoiceBar"))
        XCTAssertFalse(titles.contains("Hide for 1 hour"))
    }

    // MARK: - VoiceState snooze/unsnooze

    func testSnoozeSetsModeToDisconnected() {
        let state = VoiceState()
        state.mode = .idle

        state.snooze()

        XCTAssertEqual(state.mode, .disconnected)
    }

    func testUnsnoozeRestoresIdleMode() {
        let state = VoiceState()
        state.snooze()
        XCTAssertEqual(state.mode, .disconnected)

        state.unsnooze()

        XCTAssertEqual(state.mode, .idle)
    }

    func testUnsnoozeDoesNothingIfNotSnoozed() {
        let state = VoiceState()
        state.mode = .recording

        state.unsnooze()

        XCTAssertEqual(state.mode, .recording, "unsnooze should only act on .disconnected")
    }

    // MARK: - LaunchAgent plist validation

    func testLaunchAgentPlistExistsInRepo() {
        // Verify the fixed plist template is shipped in the repo
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // VoiceBarTests/
            .deletingLastPathComponent() // Tests/
            .deletingLastPathComponent() // flow-bar/
            .deletingLastPathComponent() // voicelayer root
        let plistPath = repoRoot
            .appendingPathComponent("launchd")
            .appendingPathComponent("com.voicelayer.voicebar.plist")
            .path

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: plistPath),
            "LaunchAgent plist should exist at launchd/com.voicelayer.voicebar.plist"
        )
    }

    func testLaunchAgentPlistUsesSuccessfulExitKeepAlive() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let plistURL = repoRoot
            .appendingPathComponent("launchd")
            .appendingPathComponent("com.voicelayer.voicebar.plist")

        let data = try Data(contentsOf: plistURL)
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
        guard let dict = plist as? [String: Any] else {
            XCTFail("Plist is not a dictionary")
            return
        }

        // KeepAlive should be a dict with SuccessfulExit, NOT a plain bool
        guard let keepAlive = dict["KeepAlive"] as? [String: Any] else {
            XCTFail("KeepAlive should be a dictionary, not a boolean — plain true causes respawn on Quit")
            return
        }

        let successfulExit = keepAlive["SuccessfulExit"] as? Bool
        XCTAssertEqual(successfulExit, false, "SuccessfulExit:false means only restart on crash, not clean quit")
    }

    func testF5HidutilLaunchAgentRunsMergeHelper() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let plistURL = repoRoot
            .appendingPathComponent("launchd")
            .appendingPathComponent("com.voicelayer.f5-to-f18-hidutil.plist")

        let data = try Data(contentsOf: plistURL)
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
        let dict = try XCTUnwrap(plist as? [String: Any])
        let args = try XCTUnwrap(dict["ProgramArguments"] as? [String])

        XCTAssertEqual(dict["Label"] as? String, "com.voicelayer.f5-to-f18-hidutil")
        XCTAssertEqual(args.prefix(2), ["/bin/sh", "-c"])

        let command = try XCTUnwrap(args.last)
        XCTAssertTrue(
            command.contains("apply-voicebar-f5-hidutil.sh"),
            "LaunchAgent should run the helper that preserves non-VoiceBar hidutil mappings"
        )
    }

    func testF5HidutilHelperMapsBothF5AndDictationToF18() throws {
        // Architecture: VoiceBar owns BOTH source keys. The physical F5
        // (0x70000003E) AND the Apple Dictation consumer key (0xC000000CF) are
        // remapped to F18 (0x70000006D). F5 -> F18 is REQUIRED so a bare F5
        // press reaches VoiceBar (listening for F18) instead of falling through
        // to macOS Dictation after a reboot.
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let helperURL = repoRoot
            .appendingPathComponent("scripts")
            .appendingPathComponent("apply-voicebar-f5-hidutil.sh")

        let helper = try String(contentsOf: helperURL)
        XCTAssertTrue(
            helper.contains("30064771134"),
            "F5 source must be remapped to F18"
        )
        XCTAssertTrue(
            helper.contains("51539607759"),
            "Apple Dictation source must be remapped to F18"
        )
        XCTAssertTrue(
            helper.contains("30064771181"),
            "F18 destination must be present"
        )
        // Both the F5 and Dictation entries are appended after the preserved
        // user mappings — two pushes total (osascript path shown; node path
        // mirrors it).
        let pushCount = helper.components(separatedBy: "preserved.push").count - 1
        XCTAssertGreaterThanOrEqual(
            pushCount,
            2,
            "helper must push BOTH F5 -> F18 and Dictation -> F18 entries"
        )
    }

    func testHidutilMappingParserDetectsDictationToF18Relay() throws {
        let mapping: [String: Any] = [
            "UserKeyMapping": [
                [
                    "HIDKeyboardModifierMappingSrc": 51_539_607_759,
                    "HIDKeyboardModifierMappingDst": 30_064_771_181,
                ],
            ],
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: mapping,
            format: .xml,
            options: 0
        )

        XCTAssertTrue(
            AppDelegate.hidutilMappingContains(
                data,
                source: 51_539_607_759,
                destination: 30_064_771_181
            )
        )
        XCTAssertFalse(
            AppDelegate.hidutilMappingContains(
                data,
                source: 30_064_771_134,
                destination: 30_064_771_181
            )
        )
    }

    func testHidutilRelayMappingStatusDetectsBothF5AndDictationRelay() throws {
        // Both F5 -> F18 and Dictation -> F18 present: the fully-configured
        // relay. F5 -> F18 is the required (not stale) entry.
        let mapping: [String: Any] = [
            "UserKeyMapping": [
                [
                    "HIDKeyboardModifierMappingSrc": 51_539_607_759,
                    "HIDKeyboardModifierMappingDst": 30_064_771_181,
                ],
                [
                    "HIDKeyboardModifierMappingSrc": 30_064_771_134,
                    "HIDKeyboardModifierMappingDst": 30_064_771_181,
                ],
            ],
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: mapping,
            format: .xml,
            options: 0
        )

        let status = AppDelegate.hidutilRelayMappingStatus(data)

        XCTAssertTrue(status.dictationMappingActive)
        XCTAssertTrue(status.f5MappingActive)
    }

    func testHidutilRelayMappingStatusFlagsMissingF5Relay() throws {
        // Dictation -> F18 present but F5 -> F18 missing: the post-reboot broken
        // state the fix guards against. f5MappingActive must be false so the
        // relay is reported as needing attention.
        let mapping: [String: Any] = [
            "UserKeyMapping": [
                [
                    "HIDKeyboardModifierMappingSrc": 51_539_607_759,
                    "HIDKeyboardModifierMappingDst": 30_064_771_181,
                ],
            ],
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: mapping,
            format: .xml,
            options: 0
        )

        let status = AppDelegate.hidutilRelayMappingStatus(data)

        XCTAssertTrue(status.dictationMappingActive)
        XCTAssertFalse(status.f5MappingActive)
    }

    func testBundleMetadataUsesSingleVoiceBarAppName() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let plistURL = repoRoot
            .appendingPathComponent("flow-bar")
            .appendingPathComponent("bundle")
            .appendingPathComponent("Info.plist")

        let data = try Data(contentsOf: plistURL)
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
        let dict = try XCTUnwrap(plist as? [String: Any])

        XCTAssertEqual(dict["CFBundleName"] as? String, "VoiceBar")
        XCTAssertEqual(dict["CFBundleDisplayName"] as? String, "VoiceBar")
        XCTAssertEqual(
            dict["NSMicrophoneUsageDescription"] as? String,
            "VoiceBar needs microphone access for voice recording"
        )
    }

    func testHotkeyEventFromSameSourceIsAllowedWhenNoOverlapExists() {
        let now = 10.0

        XCTAssertFalse(
            shouldIgnoreHotkeyEvent(
                source: .legacySocket,
                gestureState: .idle,
                activeHotkeySource: nil,
                lastHotkeyActivityAt: nil,
                lastHotkeyActivitySource: nil,
                now: now
            )
        )
        XCTAssertFalse(
            shouldIgnoreHotkeyEvent(
                source: .native,
                gestureState: .idle,
                activeHotkeySource: nil,
                lastHotkeyActivityAt: nil,
                lastHotkeyActivitySource: nil,
                now: now
            )
        )
    }

    func testHotkeyEventFromOtherSourceIsIgnoredWhileGestureIsActive() {
        let now = 10.0

        XCTAssertTrue(
            shouldIgnoreHotkeyEvent(
                source: .legacySocket,
                gestureState: .pressing,
                activeHotkeySource: .native,
                lastHotkeyActivityAt: nil,
                lastHotkeyActivitySource: nil,
                now: now
            )
        )
        XCTAssertTrue(
            shouldIgnoreHotkeyEvent(
                source: .native,
                gestureState: .holding,
                activeHotkeySource: .legacySocket,
                lastHotkeyActivityAt: nil,
                lastHotkeyActivitySource: nil,
                now: now
            )
        )
    }

    func testHotkeyEventFromOwningSourceIsAllowedWhileGestureIsActive() {
        let now = 10.0

        XCTAssertFalse(
            shouldIgnoreHotkeyEvent(
                source: .legacySocket,
                gestureState: .waitingForDoubleTap,
                activeHotkeySource: .legacySocket,
                lastHotkeyActivityAt: nil,
                lastHotkeyActivitySource: nil,
                now: now
            )
        )
        XCTAssertFalse(
            shouldIgnoreHotkeyEvent(
                source: .native,
                gestureState: .holding,
                activeHotkeySource: .native,
                lastHotkeyActivityAt: nil,
                lastHotkeyActivitySource: nil,
                now: now
            )
        )
    }

    func testHotkeyEventFromOtherSourceIsIgnoredShortlyAfterRecentAcceptedActivity() {
        let now = 10.0

        XCTAssertTrue(
            shouldIgnoreHotkeyEvent(
                source: .legacySocket,
                gestureState: .idle,
                activeHotkeySource: nil,
                lastHotkeyActivityAt: 9.5,
                lastHotkeyActivitySource: .native,
                now: now
            )
        )
        XCTAssertTrue(
            shouldIgnoreHotkeyEvent(
                source: .native,
                gestureState: .idle,
                activeHotkeySource: nil,
                lastHotkeyActivityAt: 9.5,
                lastHotkeyActivitySource: .legacySocket,
                now: now
            )
        )
    }

    func testHotkeyEventFromSameRecentSourceIsNotIgnored() {
        XCTAssertFalse(
            shouldIgnoreHotkeyEvent(
                source: .native,
                gestureState: .idle,
                activeHotkeySource: .native,
                lastHotkeyActivityAt: 10.0,
                lastHotkeyActivitySource: .native,
                now: 10.2
            )
        )
        XCTAssertFalse(
            shouldIgnoreHotkeyEvent(
                source: .legacySocket,
                gestureState: .idle,
                activeHotkeySource: nil,
                lastHotkeyActivityAt: 10.0,
                lastHotkeyActivitySource: .legacySocket,
                now: 10.2
            )
        )
    }

    func testSimulatePastePostsRealCommandKeyEventsAroundV() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = repoRoot
            .appendingPathComponent("flow-bar")
            .appendingPathComponent("Sources")
            .appendingPathComponent("VoiceBar")
            .appendingPathComponent("VoiceBarApp.swift")

        let source = try String(contentsOf: sourceURL)
        XCTAssertTrue(source.contains("let commandKey: CGKeyCode = 0x37"))
        XCTAssertTrue(source.contains("CGEventFlags.maskCommand.rawValue | 0x000008"))
        XCTAssertTrue(source.contains("commandDown.post(tap: .cghidEventTap)"))
        XCTAssertTrue(source.contains("commandUp.post(tap: .cghidEventTap)"))

        let commandDownRange = try XCTUnwrap(source.range(of: "commandDown.post(tap: .cghidEventTap)"))
        let vDownRange = try XCTUnwrap(source.range(of: "vDown.post(tap: .cghidEventTap)"))
        let vUpRange = try XCTUnwrap(source.range(of: "vUp.post(tap: .cghidEventTap)"))
        let commandUpRange = try XCTUnwrap(source.range(of: "commandUp.post(tap: .cghidEventTap)"))
        XCTAssertLessThan(commandDownRange.lowerBound, vDownRange.lowerBound)
        XCTAssertLessThan(vDownRange.lowerBound, vUpRange.lowerBound)
        XCTAssertLessThan(vUpRange.lowerBound, commandUpRange.lowerBound)
    }

    func testSettingsWindowWiresHistoryAndVisibilityActions() throws {
        let source = try voiceBarAppSource()

        XCTAssertTrue(source.contains("historyPage: { limit in SettingsHistoryArchive.loadPage(limit: limit) }"))
        XCTAssertFalse(source.contains("historyGroups: { SettingsHistoryArchive.load() }"))
        XCTAssertTrue(source.contains("voiceState.copyTranscript(text)"))
        XCTAssertTrue(source.contains("voiceState.repasteTranscript(text, source: \"settings_history\")"))
        XCTAssertTrue(source.contains("voiceState.retranscribeHistoryEntry(recordingPath: recordingPath)"))
        XCTAssertTrue(source.contains("isVoiceBarHidden: { [weak self] in"))
        XCTAssertTrue(source.contains("onHideVoiceBar: { [weak self] in"))
        XCTAssertTrue(source.contains("snoozeForOneHour()"))
        XCTAssertTrue(source.contains("onShowVoiceBar: { [weak self] in"))
        XCTAssertTrue(source.contains("unsnoozeNow()"))
    }

    func testDictionaryAddWindowIsStandaloneAndClosable() throws {
        let source = try voiceBarAppSource()

        XCTAssertFalse(
            source.contains("panel.beginSheet(sheet)"),
            "Add-to-Dictionary must not attach a large sheet to the tiny nonactivating pill panel"
        )
        XCTAssertTrue(source.contains("sheet.styleMask = [.titled, .closable]"))
        XCTAssertTrue(source.contains("sheet.makeKeyAndOrderFront(nil)"))
    }

    @MainActor
    func testReadbackWatchdogDismissesOutsideTheVisibleNotchSurface() async {
        var dismissCount = 0
        let coordinator = RetainedReadbackDismissalCoordinator(
            delay: .milliseconds(20)
        )

        coordinator.synchronize(
            isReadback: true,
            isPointerInsideVisibleSurface: { false }
        ) {
            dismissCount += 1
        }
        try? await Task.sleep(for: .milliseconds(40))

        XCTAssertEqual(dismissCount, 1)
    }

    @MainActor
    func testRepeatedUnattendedReadbackSynchronizationDoesNotRestartGraceWindow() async {
        var dismissCount = 0
        let coordinator = RetainedReadbackDismissalCoordinator(
            delay: .milliseconds(100)
        )
        let synchronize = {
            coordinator.synchronize(
                isReadback: true,
                isPointerInsideVisibleSurface: { false }
            ) {
                dismissCount += 1
            }
        }

        synchronize()
        try? await Task.sleep(for: .milliseconds(70))
        synchronize()
        try? await Task.sleep(for: .milliseconds(60))

        XCTAssertEqual(
            dismissCount,
            1,
            "Repeated W2 idle/readback broadcasts must not postpone unattended auto-dismiss"
        )
    }

    @MainActor
    func testReadbackWatchdogPersistsInsideThenDismissesAfterPointerLeaves() async {
        let pointer = PointerProbe()
        var dismissCount = 0
        let coordinator = RetainedReadbackDismissalCoordinator(
            delay: .milliseconds(20)
        )

        coordinator.synchronize(
            isReadback: true,
            isPointerInsideVisibleSurface: { pointer.isInside }
        ) {
            dismissCount += 1
        }
        try? await Task.sleep(for: .milliseconds(35))
        XCTAssertEqual(dismissCount, 0)

        pointer.isInside = false
        try? await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(dismissCount, 1)
    }

    @MainActor
    func testReadbackWatchdogStartsAFreshGraceWindowAfterObservingPointerExit() async {
        let pointer = PointerProbe()
        var dismissCount = 0
        let coordinator = RetainedReadbackDismissalCoordinator(
            delay: .milliseconds(80)
        )

        coordinator.synchronize(
            isReadback: true,
            isPointerInsideVisibleSurface: { pointer.isInside }
        ) {
            dismissCount += 1
        }
        try? await Task.sleep(for: .milliseconds(60))
        pointer.isInside = false

        try? await Task.sleep(for: .milliseconds(45))
        XCTAssertEqual(
            dismissCount,
            0,
            "A read-back that was hovered must not inherit the current polling deadline after exit"
        )

        try? await Task.sleep(for: .milliseconds(75))
        XCTAssertEqual(dismissCount, 1)
    }

    func testReadbackPointerCheckRejectsScreenPointOutsidePanelBeforeConversion() {
        var didConvert = false

        let isInside = RetainedReadbackPointerPolicy.isInsideVisibleSurface(
            screenPoint: CGPoint(x: 900, y: 700),
            panelFrame: CGRect(x: 100, y: 100, width: 500, height: 200),
            convertFromScreen: { point in
                didConvert = true
                return point
            },
            containsLocalPoint: { _ in true }
        )

        XCTAssertFalse(isInside)
        XCTAssertFalse(didConvert)
    }

    func testReadbackPointerCheckConvertsAndChecksPointInsidePanelFrame() {
        let isInside = RetainedReadbackPointerPolicy.isInsideVisibleSurface(
            screenPoint: CGPoint(x: 320, y: 180),
            panelFrame: CGRect(x: 100, y: 100, width: 500, height: 200),
            convertFromScreen: { _ in CGPoint(x: 220, y: 80) },
            containsLocalPoint: { $0 == CGPoint(x: 220, y: 80) }
        )

        XCTAssertTrue(isInside)
    }

    func testVoiceModeChangesSynchronizeRetainedReadbackLifecycle() throws {
        let source = try voiceBarAppSource()

        XCTAssertTrue(source.contains("private func synchronizeRetainedReadbackLifecycle()"))
        XCTAssertTrue(source.contains("retainedReadbackDismissalCoordinator.synchronize("))
        XCTAssertTrue(source.contains("isPointerInsideVisibleNotchSurface"))
        XCTAssertTrue(source.contains("voiceState.dismissRetainedTeleprompter()"))

        let modeHandler = try XCTUnwrap(source.range(of: "private func handleVoiceModeChange"))
        let synchronizeCall = try XCTUnwrap(
            source.range(
                of: "synchronizeRetainedReadbackLifecycle()",
                range: modeHandler.lowerBound ..< source.endIndex
            )
        )
        let switchRange = try XCTUnwrap(
            source.range(
                of: "switch mode",
                range: modeHandler.lowerBound ..< source.endIndex
            )
        )
        XCTAssertLessThan(synchronizeCall.lowerBound, switchRange.lowerBound)
    }

    func testInitialVisibleIdleStartsItsCollapseCountdownAfterPanelInstallation() throws {
        let source = try voiceBarAppSource()
        let panelInstalled = try XCTUnwrap(source.range(of: "panel = pill"))
        let countdown = try XCTUnwrap(
            source.range(
                of: "voiceState.beginIdleCollapseCountdown()",
                range: panelInstalled.upperBound ..< source.endIndex
            )
        )

        XCTAssertGreaterThan(countdown.lowerBound, panelInstalled.lowerBound)
    }

    func testProductHoverUsesSeparateExpansionAndRetentionGeometry() throws {
        let appSource = try voiceBarAppSource()
        let barSource = try voiceBarUISource(named: "BarView.swift")
        let panelSource = try voiceBarUISource(named: "FloatingPanel.swift")

        XCTAssertTrue(appSource.contains("hosting.hoverExpansionHitTestProvider"))
        XCTAssertTrue(appSource.contains("containsHoverExpansion(point)"))
        XCTAssertTrue(appSource.contains("hosting.hoverRetentionHitTestProvider"))
        XCTAssertTrue(appSource.contains("containsHoverRetention(point)"))
        XCTAssertTrue(appSource.contains("containsInteractiveContent(point)"))
        XCTAssertTrue(appSource.contains("containsVisibleSurface($0)"))
        XCTAssertFalse(appSource.contains("containsActiveContent("))
        XCTAssertTrue(appSource.contains("hosting.onHoverChanged"))
        XCTAssertTrue(appSource.contains("voiceState.setHoveringFromDebouncedPointer(hovering)"))
        XCTAssertTrue(barSource.contains("guard !includesPanelOutsets else { return }"))
        XCTAssertTrue(panelSource.contains("VoiceBarHoverHysteresis"))
        XCTAssertTrue(panelSource.contains("acceptsMouseMovedEvents = true"))
        XCTAssertTrue(panelSource.contains(".nonactivatingPanel"))
        XCTAssertFalse(
            panelSource.split(separator: "\n").contains { line in
                let code = line.trimmingCharacters(in: .whitespaces)
                return !code.hasPrefix("//") && code.contains("makeKey(")
            }
        )
    }

    func testIsolatedContextMenuProbeChecksEveryAppKitDeliveryGate() throws {
        let source = try voiceBarAppSource()
        let methodStart = try XCTUnwrap(
            source.range(of: "private func runIsolatedContextMenuProbe")
        )
        let methodEnd = try XCTUnwrap(
            source.range(
                of: "private func snoozeForOneHour()",
                range: methodStart.upperBound ..< source.endIndex
            )
        )
        let method = source[methodStart.lowerBound ..< methodEnd.lowerBound]

        XCTAssertTrue(method.contains("applyPanelMouseEventPassthrough("))
        XCTAssertTrue(method.contains("panel.ignoresMouseEvents"))
        XCTAssertTrue(method.contains("contentView.hitTest(renderedCore)"))
        XCTAssertTrue(method.contains("contentView.hitTest(transparentMargin)"))
        XCTAssertTrue(method.contains("panel.shouldHandleContextMenu(at: renderedCore)"))
        XCTAssertTrue(method.contains("window_event_gate=passed"))
    }

    func testIsolatedVerticalHitProbeUsesRealMouseMovementAndTopEdgeClicks() throws {
        let source = try voiceBarAppSource()
        let methodStart = try XCTUnwrap(
            source.range(of: "private func runIsolatedVerticalHitProbe")
        )
        let methodEnd = try XCTUnwrap(
            source.range(
                of: "private func snoozeForOneHour()",
                range: methodStart.upperBound ..< source.endIndex
            )
        )
        let method = source[methodStart.lowerBound ..< methodEnd.lowerBound]

        XCTAssertTrue(method.contains("hosting.mouseMoved(with:"))
        XCTAssertTrue(method.contains("synchronizePanelMouseEventPassthrough("))
        XCTAssertTrue(method.contains("isIsolatedCapture: false"))
        XCTAssertTrue(method.contains("panel.ignoresMouseEvents"))
        XCTAssertTrue(method.contains("panel.sendEvent(downEvent)"))
        XCTAssertTrue(method.contains("panel.sendEvent(upEvent)"))
        XCTAssertTrue(method.contains("surface_vertical_boundary=passed"))
        XCTAssertTrue(method.contains("recording_control_top_clicks=3"))
    }

    func testFlatDisplayUsesCenteredVirtualNotchInsteadOfSavedPillPlacement() throws {
        let source = try voiceBarAppSource()

        XCTAssertTrue(source.contains("visibleFrame: screen.visibleFrame"))
        XCTAssertTrue(source.contains("virtualNotchIdleCoreHeight:"))
        XCTAssertFalse(source.contains("screenGeometry?.kind == .flatDisplayFallback"))

        let applyStart = try XCTUnwrap(source.range(of: "private func applyPanelLayout(animated:"))
        let applyEnd = try XCTUnwrap(
            source.range(
                of: "private func commitNotchContentThenApplyPanelLayout",
                range: applyStart.upperBound ..< source.endIndex
            )
        )
        let applyMethod = source[applyStart.lowerBound ..< applyEnd.lowerBound]
        XCTAssertEqual(applyMethod.components(separatedBy: "windowFrame(anchoredTo:").count - 1, 1)
        XCTAssertFalse(applyMethod.contains("PillResizePlan.makeAnchored"))

        let positionStart = try XCTUnwrap(source.range(of: "private func positionPanel("))
        let positionEnd = try XCTUnwrap(
            source.range(
                of: "private static func screenContainingMouse",
                range: positionStart.upperBound ..< source.endIndex
            )
        )
        let positionMethod = source[positionStart.lowerBound ..< positionEnd.lowerBound]
        XCTAssertEqual(positionMethod.components(separatedBy: "windowFrame(anchoredTo:").count - 1, 1)
        XCTAssertFalse(positionMethod.contains("panel.positionOnScreen"))
    }

    func testScreenParameterChangesReResolveTargetScreenBeforeLayout() throws {
        let source = try voiceBarAppSource()
        let observerStart = try XCTUnwrap(
            source.range(of: "forName: NSApplication.didChangeScreenParametersNotification")
        )
        let observerEnd = try XCTUnwrap(
            source.range(of: "func applicationWillTerminate", range: observerStart.upperBound ..< source.endIndex)
        )
        let observer = source[observerStart.lowerBound ..< observerEnd.lowerBound]
        let reapplyStart = try XCTUnwrap(source.range(of: "private func reapplyAnchoredPanelPosition()"))
        let reapplyEnd = try XCTUnwrap(
            source.range(of: "// MARK: - Drag persistence", range: reapplyStart.upperBound ..< source.endIndex)
        )
        let reapply = source[reapplyStart.lowerBound ..< reapplyEnd.lowerBound]

        XCTAssertTrue(observer.contains("reapplyAnchoredPanelPosition()"))
        XCTAssertTrue(reapply.contains("positionPanel(panel, on:"))
    }

    func testGlobalPointerMovementReevaluatesMenuBarPresentationGeometry() throws {
        let source = try voiceBarAppSource()
        let methodStart = try XCTUnwrap(source.range(of: "private func handleMouseMoved()"))
        let methodEnd = try XCTUnwrap(
            source.range(
                of: "private func synchronizePanelMouseEventPassthrough(",
                range: methodStart.upperBound ..< source.endIndex
            )
        )
        let method = source[methodStart.lowerBound ..< methodEnd.lowerBound]

        XCTAssertTrue(method.contains("Self.notchScreenGeometry(for: targetScreen)"))
        XCTAssertTrue(method.contains("lastAppliedNotchScreenGeometry"))
        XCTAssertTrue(method.contains("positionPanel(panel, on: targetScreen)"))
    }

    func testPhysicalAndVirtualNotchesAreBothFixedAnchors() throws {
        let source = try voiceBarAppSource()
        let methodStart = try XCTUnwrap(source.range(of: "private func configurePanelDragging("))
        let methodEnd = try XCTUnwrap(
            source.range(of: "private func logDiagnostic", range: methodStart.upperBound ..< source.endIndex)
        )
        let method = source[methodStart.lowerBound ..< methodEnd.lowerBound]

        XCTAssertTrue(method.contains("panel.isPillDragEnabled = false"))
        XCTAssertTrue(method.contains("panel.isMovableByWindowBackground = false"))
    }

    func testPointerAwareCoordinatorIsTheOnlyRetainedReadbackDismissalOwner() throws {
        let appSource = try voiceBarAppSource()
        let barSource = try voiceBarUISource(named: "BarView.swift")
        let modelSource = try voiceBarUISource(named: "VoiceBarNotchPresentationModel.swift")
        let coordinatorSource = try voiceBarSource(named: "RetainedReadbackDismissalCoordinator.swift")

        XCTAssertTrue(appSource.contains("retainedReadbackDismissalCoordinator.synchronize("))
        XCTAssertTrue(appSource.contains("voiceState.dismissRetainedTeleprompter()"))
        XCTAssertFalse(barSource.contains("presentationModel?.updateRetainedReadback"))
        XCTAssertFalse(modelSource.contains("updateRetainedReadback("))
        XCTAssertTrue(coordinatorSource.contains("deinit"))
        XCTAssertTrue(coordinatorSource.contains("dismissalTask?.cancel()"))
    }

    func testReadbackWatchdogClearsStaleHoverBeforeDismissing() throws {
        let source = try voiceBarAppSource()
        let synchronizeStart = try XCTUnwrap(
            source.range(of: "private func synchronizeRetainedReadbackLifecycle()")
        )
        let synchronizeEnd = try XCTUnwrap(
            source.range(
                of: "private var isPointerInsideVisibleNotchSurface",
                range: synchronizeStart.upperBound ..< source.endIndex
            )
        )
        let bodyRange = synchronizeStart.lowerBound ..< synchronizeEnd.lowerBound
        let clearHover = try XCTUnwrap(
            source.range(of: "voiceState.setHovering(false)", range: bodyRange)
        )
        let dismiss = try XCTUnwrap(
            source.range(of: "voiceState.dismissRetainedTeleprompter()", range: bodyRange)
        )

        XCTAssertLessThan(clearHover.lowerBound, dismiss.lowerBound)
    }

    func testEveryPanelLayoutInvalidatesThenRecertifiesBackingScale() throws {
        let source = try voiceBarAppSource()
        let layoutStart = try XCTUnwrap(
            source.range(of: "private func applyPanelLayout(animated: Bool)")
        )
        let firstRenderStart = try XCTUnwrap(
            source.range(
                of: "private func completePanelFirstRender",
                range: layoutStart.upperBound ..< source.endIndex
            )
        )
        let layoutBody = source[layoutStart.lowerBound ..< firstRenderStart.lowerBound]

        XCTAssertTrue(
            layoutBody.contains("schedulePanelBackingScaleRecertification(reason: \"layout_changed\")"),
            "every mode/layout render must replace the initial scale receipt"
        )

        let scheduleStart = try XCTUnwrap(
            source.range(of: "private func schedulePanelBackingScaleRecertification")
        )
        let scheduler = source[scheduleStart.lowerBound...]
        let invalidation = try XCTUnwrap(
            scheduler.range(of: "writeFirstRenderScaleReceipt(ready: false")
        )
        let nextLayoutTurn = try XCTUnwrap(
            scheduler.range(of: "DispatchQueue.main.async", range: invalidation.upperBound ..< scheduler.endIndex)
        )
        let recertification = try XCTUnwrap(
            scheduler.range(
                of: "completePanelBackingScaleRecertification(",
                range: nextLayoutTurn.upperBound ..< scheduler.endIndex
            )
        )

        XCTAssertLessThan(invalidation.lowerBound, nextLayoutTurn.lowerBound)
        XCTAssertLessThan(nextLayoutTurn.lowerBound, recertification.lowerBound)
    }

    func testScreenAndBackingScaleChangesInvalidateThenRecertifyReceipt() throws {
        let source = try voiceBarAppSource()
        let backingStart = try XCTUnwrap(
            source.range(of: "func windowDidChangeBackingProperties")
        )
        let screenStart = try XCTUnwrap(
            source.range(
                of: "func windowDidChangeScreen",
                range: backingStart.upperBound ..< source.endIndex
            )
        )
        let nextFunction = try XCTUnwrap(
            source.range(
                of: "private func currentPanelLayout",
                range: screenStart.upperBound ..< source.endIndex
            )
        )
        let backingBody = source[backingStart.lowerBound ..< screenStart.lowerBound]
        let screenBody = source[screenStart.lowerBound ..< nextFunction.lowerBound]

        XCTAssertTrue(
            backingBody.contains(
                "schedulePanelBackingScaleRecertification(reason: \"backing_properties_changed\")"
            ),
            "backing-scale changes must invalidate the prior display receipt before recertifying"
        )
        XCTAssertTrue(
            screenBody.contains(
                "schedulePanelBackingScaleRecertification(reason: \"screen_changed\")"
            ),
            "screen changes must invalidate the prior display receipt before recertifying"
        )
    }

    func testPlaybackEdgeFlushesEmptyContentBeforeCollapsingTheGlassHost() throws {
        let source = try voiceBarAppSource()

        XCTAssertTrue(source.contains(".stagesContentBeforeGlass(from: previousVoiceMode, to: mode)"))
        XCTAssertTrue(source.contains("await Task.yield()"))
        XCTAssertTrue(source.contains("contentView?.displayIfNeeded()"))
        XCTAssertTrue(source.contains("VoiceBarNotchPlaybackEdgeCommitPolicy.glassRemovalDelay"))
        XCTAssertTrue(source.contains("playbackEdgeLayoutTask?.cancel()"))
    }

    private func voiceBarAppSource() throws -> String {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = repoRoot
            .appendingPathComponent("flow-bar")
            .appendingPathComponent("Sources")
            .appendingPathComponent("VoiceBar")
            .appendingPathComponent("VoiceBarApp.swift")
        return try String(contentsOf: sourceURL)
    }

    private func voiceBarSource(named name: String) throws -> String {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: repoRoot
                .appendingPathComponent("flow-bar")
                .appendingPathComponent("Sources")
                .appendingPathComponent("VoiceBar")
                .appendingPathComponent(name),
            encoding: .utf8
        )
    }

    private func voiceBarUISource(named name: String) throws -> String {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: repoRoot
                .appendingPathComponent("flow-bar")
                .appendingPathComponent("Sources")
                .appendingPathComponent("VoiceBarUI")
                .appendingPathComponent(name),
            encoding: .utf8
        )
    }
}
