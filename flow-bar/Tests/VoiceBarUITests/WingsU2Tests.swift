import AppKit
import SwiftUI
@testable import VoiceBarUI
import XCTest

/// 2.3 lane U2 guards: fixed 73.5 + 73.5 pt wings (the 3-wings mock), the controls each state carries, the
/// microphone list and the mutually exclusive notch surfaces (formal/notch-surfaces).
@MainActor
final class WingsU2Tests: XCTestCase {
    private func resolve(
        _ mode: VoiceMode,
        hovered: Bool = false,
        showsRecordingHold: Bool = false,
        hasTeleprompterText: Bool = false,
        isTeleprompterDismissed: Bool = false,
        historyOpen: Bool = false,
        readQueueLeadingSlotCount: Int = 1
    ) -> VoiceBarNotchPresentation {
        var input = VoiceBarNotchOperationalInput(
            mode: mode,
            showsRecordingHold: showsRecordingHold,
            hasTeleprompterText: hasTeleprompterText,
            isTeleprompterDismissed: isTeleprompterDismissed,
            readQueueLeadingSlotCount: readQueueLeadingSlotCount,
            statusText: "",
            isHovered: hovered,
            isCollapsed: false
        )
        input.isHistoryPanelOpen = historyOpen
        return VoiceBarPresentation.notchPresentation(from: input)
    }

    // MARK: - Fixed wings

    func testTheFixedWingIsTodaysTwoControlWing() {
        XCTAssertEqual(VoiceBarNotchContract.fixedWingWidth, 73.5, accuracy: 0.001,
                       "13.5 core inset + two 20 pt controls + 6 pt spacing + 14 pt outer inset")
        XCTAssertEqual(VoiceBarNotchContract.hoverLauncherTrailingWingWidth, VoiceBarNotchContract.fixedWingWidth)
        XCTAssertEqual(VoiceBarNotchContract.recordingLeadingWingWidth, VoiceBarNotchContract.fixedWingWidth)
    }

    func testEveryMockedStateKeepsBothWingsAtTheFixedWidth() {
        let fixed = VoiceBarNotchContract.fixedWingWidth
        let states: [(String, VoiceBarNotchPresentation, VoiceBarNotchVisualState)] = [
            ("idle launcher", resolve(.idle, hovered: true), .hoverLauncher),
            ("history", resolve(.idle, hovered: true, historyOpen: true), .history),
            ("recording (F5)", resolve(.recording), .recording),
            ("transcribing", resolve(.transcribing), .compactStatus),
            ("reading aloud, collapsed", resolve(.speaking, isTeleprompterDismissed: true), .compactStatus),
        ]
        for (name, presentation, visualState) in states {
            XCTAssertEqual(presentation.visualState, visualState, name)
            XCTAssertEqual(presentation.geometry.leadingWingWidth, fixed, accuracy: 0.001, "\(name) left wing")
            XCTAssertEqual(presentation.geometry.trailingWingWidth, fixed, accuracy: 0.001, "\(name) right wing")
            XCTAssertEqual(presentation.geometry.topWidth, VoiceBarNotchContract.coreWidth + 2 * fixed,
                           accuracy: 0.001, "\(name): the outline never moves")
        }
    }

    func testReadingAloudWithTheTeleprompterKeepsTheFixedWings() {
        let presentation = resolve(.speaking, hasTeleprompterText: true)
        XCTAssertEqual(presentation.visualState, .teleprompter)
        XCTAssertEqual(presentation.geometry.leadingWingWidth, VoiceBarNotchContract.fixedWingWidth, accuracy: 0.001)
        XCTAssertEqual(presentation.geometry.trailingWingWidth, VoiceBarNotchContract.fixedWingWidth, accuracy: 0.001)
    }

    /// Deviation (mock silent): an Ask recording's lock is a third control, and a queued read's Next + "+N" are
    /// extra slots. They keep today's wider left wing instead of losing the control.
    func testOnlyControlsTheMockDoesNotDrawWidenTheLeftWing() {
        XCTAssertEqual(resolve(.recording, showsRecordingHold: true).geometry.leadingWingWidth,
                       VoiceBarNotchContract.recordingLeadingWingWidthWithHoldControl, accuracy: 0.001)
        XCTAssertGreaterThan(resolve(.speaking, isTeleprompterDismissed: true, readQueueLeadingSlotCount: 3)
            .geometry.leadingWingWidth, VoiceBarNotchContract.fixedWingWidth)
        XCTAssertEqual(resolve(.recording, showsRecordingHold: true).geometry.trailingWingWidth,
                       VoiceBarNotchContract.fixedWingWidth, accuracy: 0.001, "the right wing never grows")
    }

    func testTheRecordingWingLevelMeterIsSixThinBars() {
        let style = WaveformBarStyle.wingLevels
        XCTAssertEqual(style.barCount, 6)
        XCTAssertEqual(style.barWidth, 3)
        XCTAssertEqual(style.barSpacing, 3)
        XCTAssertEqual(style.maxHeight, 16)
        XCTAssertEqual(style.viewportWidth, 33)
        let lane = VoiceBarNotchContract.fixedWingWidth - 2 * VoiceBarNotchContract.fixedWingContentInset
        XCTAssertLessThanOrEqual(style.viewportWidth, lane)
        XCTAssertEqual(WaveformBarStyle.standard.barCount, WaveformLayout.barCount, "the standard meter is unchanged")
    }

    func testTheReadingTimeAndStopFillTheFixedRightWingExactly() {
        let material = VoiceBarNotchContract.material
        XCTAssertEqual(VoiceBarReadingTimeLabel.width, 31.5, accuracy: 0.001)
        XCTAssertEqual(2 * VoiceBarNotchContract.fixedWingContentInset + VoiceBarReadingTimeLabel.width
            + material.compactControlSpacing + material.compactControlSize,
            VoiceBarNotchContract.fixedWingWidth, accuracy: 0.001)
        XCTAssertEqual(VoiceBarReadingTimeLabel.text(elapsedMilliseconds: 12_400), "0:12")
        XCTAssertEqual(VoiceBarReadingTimeLabel.text(elapsedMilliseconds: 599_999), "9:59")
        XCTAssertEqual(VoiceBarReadingTimeLabel.text(elapsedMilliseconds: -5), "0:00")
    }

    /// U2 review R1 (A1): "10:00" in the 12 pt tabular system font measures 33.8 pt against the fixed 31.5 pt lane,
    /// so a long read lost part of its time. Past 9:59 the label switches to whole minutes ("10m", "59m"), then
    /// hours, so every supported value fits the fixed wing, measured with the font the label renders.
    func testEverySupportedReadingTimeFitsTheFixedLane() {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        let samples: [(Int, String)] = [
            (0, "0:00"), (599_999, "9:59"), (600_000, "10m"), (3_599_999, "59m"), (5_999_999, "99m"),
            (6_000_000, "1h"), (359_999_999, "99h"), (900_000_000_000, "99h"),
        ]
        for (milliseconds, expected) in samples {
            let text = VoiceBarReadingTimeLabel.text(elapsedMilliseconds: milliseconds)
            XCTAssertEqual(text, expected, "\(milliseconds) ms")
            let width = (text as NSString).size(withAttributes: [.font: font]).width
            XCTAssertLessThanOrEqual(width, VoiceBarReadingTimeLabel.width, "\(text) is \(width) pt wide")
        }
        // The witness for the old format: two-digit minutes with seconds do not fit.
        XCTAssertGreaterThan(("10:00" as NSString).size(withAttributes: [.font: font]).width,
                             VoiceBarReadingTimeLabel.width)
    }

    // MARK: - Hit regions match the drawn controls

    func testTheLauncherHitRectsAreTheMicChevronHistoryAndSettings() {
        let presentation = resolve(.idle, hovered: true)
        let region = VoiceBarNotchHitRegion(
            geometry: presentation.geometry,
            configuration: .fallback(for: presentation)
        )
        XCTAssertEqual(region.rects.count, 4)
        let geometry = presentation.geometry
        let leftWing = CGRect(x: geometry.coreOriginX - geometry.leadingWingWidth, y: 0,
                              width: geometry.leadingWingWidth, height: geometry.totalHeight)
        let rightWing = CGRect(x: geometry.coreOriginX + geometry.coreWidth, y: 0,
                               width: geometry.trailingWingWidth, height: geometry.totalHeight)
        XCTAssertEqual(region.rects.prefix(2).filter { leftWing.contains($0) }.count, 2, "mic + chevron")
        XCTAssertEqual(region.rects.suffix(2).filter { rightWing.contains($0) }.count, 2, "History + Settings")
        XCTAssertEqual(VoiceBarNotchInteractionConfiguration.historyPanel.leadingControlCount, 2)
    }

    func testTheReadingStopSitsAtTheRightWingsOuterInset() {
        let presentation = resolve(.speaking, isTeleprompterDismissed: false)
        let configuration = VoiceBarNotchInteractionConfiguration(
            leadingControlCount: 1,
            trailingControlCountFromOuter: 1,
            trailingOuterInset: VoiceBarNotchContract.fixedWingContentInset
        )
        let region = VoiceBarNotchHitRegion(geometry: presentation.geometry, configuration: configuration)
        let stop = try? XCTUnwrap(region.rects.last)
        let geometry = presentation.geometry
        XCTAssertEqual(stop?.maxX ?? 0, geometry.topOriginX + geometry.topWidth - 8, accuracy: 0.001)
    }

    // MARK: - Microphone list

    /// D2: the list displays the priority order; every row and "Microphone priority…" opens Settings › Microphone
    /// priority, and nothing in it writes the macOS default input.
    func testTheMicrophoneListIsADisplayOfThePriorityListThatLeadsToSettings() {
        let controller = PillContextMenuController()
        controller.microphonePickerRowsProvider = {
            [MicrophonePickerRow(label: "MacBook Pro Microphone", isNextDictation: true),
             MicrophonePickerRow(label: "USB Audio Interface", isNextDictation: false)]
        }
        var changes = 0
        controller.onChangeMicrophone = { changes += 1 }
        let menu = controller.makeMicrophonePickerMenu()
        let titles = menu.items.map { $0.isSeparatorItem ? "—" : $0.title }
        XCTAssertEqual(titles, ["Microphone", "MacBook Pro Microphone", "USB Audio Interface", "—",
                                "Microphone priority…"])
        XCTAssertEqual(menu.items[1].state, .on)
        XCTAssertEqual(menu.items[2].state, .off)
        menu.performActionForItem(at: 2)
        menu.performActionForItem(at: 4)
        XCTAssertEqual(changes, 2)

        controller.microphonePickerRowsProvider = { [] }
        XCTAssertEqual(controller.makeMicrophonePickerMenu().items[1].title, "No microphones")
    }

    func testTheMicrophoneListShowsConnectedVisibleRowsAndChecksTheNextDictation() {
        let snapshot = MicrophonePrioritySnapshot(rows: [
            MicrophonePriorityRow(uid: "usb", deviceID: "2", label: "USB Audio Interface", isConnected: true),
            MicrophonePriorityRow(uid: "gone", deviceID: nil, label: "AirPods Pro", isConnected: false),
            MicrophonePriorityRow(uid: "agg", deviceID: "9", label: "Aggregate", isConnected: true,
                                  isVirtualOrAggregateTransport: true),
            MicrophonePriorityRow(uid: "mbp", deviceID: "1", label: "MacBook Pro Microphone", isConnected: true),
        ], nextDeviceName: "MacBook Pro Microphone", nextDeviceUID: "mbp", nextDeviceID: "1")
        XCTAssertEqual(MicrophonePickerRow.rows(from: snapshot), [
            MicrophonePickerRow(label: "USB Audio Interface", isNextDictation: false),
            MicrophonePickerRow(label: "MacBook Pro Microphone", isNextDictation: true),
        ])
    }

    // MARK: - Setup attention

    func testTheGearBadgeFollowsTheMissingPermissions() {
        let state = VoiceState(
            recentTranscriptionsLoader: { [] }, recentTranscriptionsSaver: { _ in },
            recentTranscriptionEntriesLoader: { [] }, recentTranscriptionEntriesSaver: { _ in },
            transcriptionVocabularyLoader: { [] }, transcriptionVocabularyAliasLoader: { [] },
            keepsExpandedInDevState: false
        )
        XCTAssertFalse(state.setupNeedsAttention, "a listener that has not started yet is not a setup error")
        state.setSetupMissingPermissions([.accessibility])
        XCTAssertTrue(state.setupNeedsAttention)
        state.setSetupMissingPermissions([])
        XCTAssertFalse(state.setupNeedsAttention)
        XCTAssertEqual(SettingsFocus.permissions.rawValue, "settings-general-permissions")
    }

    // MARK: - Mutually exclusive notch surfaces (formal/notch-surfaces, Fixed)

    func testAMenuAskedForOverHistoryWaitsForHistoryToClose() {
        var surfaces = VoiceBarNotchSurfaceCoordinator()
        XCTAssertEqual(surfaces.historyDidChange(isOpen: true), [])
        XCTAssertEqual(surfaces.requestMenu(.microphone), [.closeHistory], "never shown over the open panel (Old)")
        XCTAssertEqual(surfaces.surface, .history)
        XCTAssertEqual(surfaces.historyDidChange(isOpen: false), [.showMenu(.microphone)],
                       "shown once closed (DropPending)")
        XCTAssertEqual(surfaces.surface, .menu(.microphone))
        XCTAssertEqual(surfaces.requestMenu(.microphone), [], "menus never stack")
        surfaces.menuDidClose()
        XCTAssertEqual(surfaces.surface, .none)
        XCTAssertEqual(surfaces.requestMenu(.microphone), [.showMenu(.microphone)])
    }

    func testHistoryOpeningAgainDropsAWaitingMenu() {
        var surfaces = VoiceBarNotchSurfaceCoordinator()
        _ = surfaces.historyDidChange(isOpen: true)
        _ = surfaces.requestMenu(.microphone)
        XCTAssertEqual(surfaces.historyDidChange(isOpen: true), [])
        XCTAssertNil(surfaces.pendingMenu)
        XCTAssertEqual(surfaces.historyDidChange(isOpen: false), [], "no stale menu later")
    }

    func testTheModelAsksTheViewToCloseHistoryAndReportsItsState() {
        let model = VoiceBarNotchPresentationModel()
        var reports: [Bool] = []
        model.onHistoryPanelChanged = { reports.append($0) }
        model.setHistoryPanelOpen(true)
        model.setHistoryPanelOpen(true)
        model.setHistoryPanelOpen(false)
        XCTAssertEqual(reports, [true, false])
        let before = model.historyCloseRequest
        model.requestHistoryClose()
        XCTAssertEqual(model.historyCloseRequest, before + 1)
    }
}
