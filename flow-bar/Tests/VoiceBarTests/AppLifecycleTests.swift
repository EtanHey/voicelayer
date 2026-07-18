@testable import VoiceBar
@testable import VoiceBarUI
import XCTest

final class AppLifecycleTests: XCTestCase {
    private final class PointerProbe: @unchecked Sendable {
        var isInside = true
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
        try? await Task.sleep(for: .milliseconds(30))
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
}
