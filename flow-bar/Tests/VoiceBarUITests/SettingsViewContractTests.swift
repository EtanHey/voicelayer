@testable import VoiceBarUI
import XCTest

final class SettingsViewContractTests: XCTestCase {
    func testSettingsSourceDoesNotExposeStandalonePositionLock() throws {
        let source = try settingsViewSource()

        XCTAssertFalse(source.contains("Lock position"))
        XCTAssertFalse(source.contains("isPositionLocked"))
        XCTAssertFalse(source.contains("onSetPositionLocked"))
    }

    func testDictionaryTabUsesCanonicalCardSurface() throws {
        let source = try settingsViewSource()

        XCTAssertTrue(source.contains("dictionaryEntryCard"))
        XCTAssertTrue(source.contains("variantChips"))
        XCTAssertFalse(source.contains("Section(\"Find\")"))
        XCTAssertFalse(source.contains("Section(\"Prompt Terms\")"))
        XCTAssertFalse(source.contains("DisclosureGroup"))
    }

    func testDictionaryAddAndSearchAppearBeforeCanonicalCards() throws {
        let source = try settingsViewSource()
        let addRange = try XCTUnwrap(source.range(of: "addTermRow"))
        let searchRange = try XCTUnwrap(source.range(of: "searchRow"))
        let cardRange = try XCTUnwrap(source.range(of: "dictionaryEntryCard"))
        let addVariantRange = try XCTUnwrap(source.range(of: "addVariantInlineEditor"))

        XCTAssertLessThan(addRange.lowerBound, searchRange.lowerBound)
        XCTAssertLessThan(searchRange.lowerBound, cardRange.lowerBound)
        XCTAssertLessThan(cardRange.lowerBound, addVariantRange.lowerBound)
    }

    func testSettingsAnchorUsesOneToggleAndTopBottomPicker() throws {
        let source = try settingsViewSource()

        XCTAssertTrue(source.contains("Toggle(\"Anchor\""))
        XCTAssertTrue(source.contains("Picker(\"Position\""))
        XCTAssertFalse(source.contains("Picker(\"Anchor\""))
    }

    func testAudioTabIncludesPerformanceEffortPicker() throws {
        let source = try settingsViewSource()

        XCTAssertTrue(source.contains("Section(\"Performance\")"))
        XCTAssertTrue(source.contains("Picker(\"Effort\""))
        XCTAssertTrue(source.contains("Fast"))
        XCTAssertTrue(source.contains("Balanced"))
        XCTAssertTrue(source.contains("Accurate"))
        XCTAssertTrue(source.contains("onSelectPerformanceEffort"))
    }

    func testSettingsIncludesFullHistoryTabWithEntryActions() throws {
        let source = try settingsViewSource()

        XCTAssertTrue(source.contains("case history"))
        XCTAssertTrue(source.contains("Label(\"History\""))
        XCTAssertTrue(source.contains("historyTab"))
        XCTAssertTrue(source.contains("historyGroups"))
        XCTAssertTrue(source.contains("SettingsHistoryArchive.load"))
        XCTAssertTrue(source.contains("onCopyHistoryTranscript"))
        XCTAssertTrue(source.contains("onPasteHistoryTranscript"))
        XCTAssertTrue(source.contains("onRetranscribeHistoryEntry"))
        XCTAssertTrue(source.contains("ScrollViewReader"))
        XCTAssertTrue(source.contains("latestHistoryAnchorID"))
        XCTAssertTrue(source.contains("historyEntryActions"))
        XCTAssertTrue(source.contains("voiceBarHistoryArchiveDidChange"))
    }

    func testSettingsHistoryLoadsPagedDataOffMainThreadWithLatestAtTop() throws {
        let source = try settingsViewSource()

        XCTAssertTrue(source.contains("historyPage"))
        XCTAssertTrue(source.contains("SettingsHistoryArchive.loadPage"))
        XCTAssertTrue(source.contains("isHistoryLoading"))
        XCTAssertTrue(source.contains("historyLoadedEntryLimit"))
        XCTAssertTrue(source.contains("loadOlderHistory"))
        XCTAssertTrue(source.contains("Task.detached"))
        XCTAssertTrue(source.contains("scrollTo(latestHistoryAnchorID, anchor: .top)"))
        XCTAssertFalse(source
            .contains(
                "_historyDayGroups = State(initialValue: Self.chronologicallySortedHistoryGroups(historyGroups()))"
            ))
        XCTAssertFalse(source.contains("latestHistoryAnchorID, anchor: .bottom"))
    }

    func testVoiceStateUsesSingleHistoryRetranscriptionRequest() throws {
        let source = try voiceStateSource()

        XCTAssertTrue(source.contains("HistoryRetranscriptionRequest"))
        XCTAssertTrue(source.contains("historyRetranscriptionRequest"))
        XCTAssertFalse(source.contains("pendingHistoryRetranscriptionPath"))
        XCTAssertFalse(source.contains("pendingHistoryRetranscriptionIntentID"))
        XCTAssertFalse(source.contains("pendingHistoryRetranscriptionIntentPath"))
        XCTAssertFalse(source.contains("historyRetranscriptionPasteSuppressionPaths"))
    }

    func testHistoryRowsExposeRetranscribeInFlightFeedback() throws {
        let settingsSource = try settingsViewSource()
        let barSource = try barViewSource()
        let appSource = try voiceBarAppSource()

        XCTAssertTrue(settingsSource.contains("isHistoryRetranscribing"))
        XCTAssertTrue(settingsSource.contains("Re-transcribing..."))
        XCTAssertTrue(settingsSource.contains("historyEntryActions(entry, isRetranscribing: isRetranscribing)"))
        XCTAssertTrue(barSource.contains("activeHistoryRetranscriptionPath"))
        XCTAssertTrue(barSource.contains("Re-transcribing..."))
        XCTAssertTrue(appSource.contains("voiceState.activeHistoryRetranscriptionPath == recordingPath"))
    }

    func testGeneralTabProvidesVoiceBarHideAndUnhideAffordance() throws {
        let source = try settingsViewSource()

        XCTAssertTrue(source.contains("Section(\"Visibility\")"))
        XCTAssertTrue(source.contains("isVoiceBarHidden"))
        XCTAssertTrue(source.contains("onHideVoiceBar"))
        XCTAssertTrue(source.contains("onShowVoiceBar"))
        XCTAssertTrue(source.contains("Show VoiceBar"))
        XCTAssertTrue(source.contains("Hide for 1 hour"))
    }

    func testGeneralTabShowsGranularPermissionAndRelayRows() throws {
        let source = try settingsViewSource()

        XCTAssertTrue(source.contains("permissionRow"))
        XCTAssertTrue(source.contains("Microphone"))
        XCTAssertTrue(source.contains("Privacy_Microphone"))
        XCTAssertTrue(source.contains("Section(\"Permissions & Hotkey Setup\")"))
        XCTAssertTrue(source.contains("Relay (hidutil LaunchAgent)"))
        XCTAssertTrue(source.contains("runRelaySetup"))
        XCTAssertTrue(source.contains(".disabled(relaySetupRunning)"))
        XCTAssertFalse(source.contains("Section(\"Karabiner\")"))
    }

    func testDictionaryTextFieldsUseVisibleDictionaryFieldTreatment() throws {
        let source = try settingsViewSource()
        let visibleFieldCount = source.components(separatedBy: ".dictionaryTextField()").count - 1

        XCTAssertGreaterThanOrEqual(visibleFieldCount, 3)
    }

    private func settingsViewSource() throws -> String {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let settingsURL = repoRoot
            .appendingPathComponent("flow-bar")
            .appendingPathComponent("Sources")
            .appendingPathComponent("VoiceBarUI")
            .appendingPathComponent("SettingsView.swift")
        return try String(contentsOf: settingsURL)
    }

    private func voiceStateSource() throws -> String {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let voiceStateURL = repoRoot
            .appendingPathComponent("flow-bar")
            .appendingPathComponent("Sources")
            .appendingPathComponent("VoiceBarUI")
            .appendingPathComponent("VoiceState.swift")
        return try String(contentsOf: voiceStateURL)
    }

    private func barViewSource() throws -> String {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let barViewURL = repoRoot
            .appendingPathComponent("flow-bar")
            .appendingPathComponent("Sources")
            .appendingPathComponent("VoiceBarUI")
            .appendingPathComponent("BarView.swift")
        return try String(contentsOf: barViewURL)
    }

    private func voiceBarAppSource() throws -> String {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let appURL = repoRoot
            .appendingPathComponent("flow-bar")
            .appendingPathComponent("Sources")
            .appendingPathComponent("VoiceBar")
            .appendingPathComponent("VoiceBarApp.swift")
        return try String(contentsOf: appURL)
    }
}
