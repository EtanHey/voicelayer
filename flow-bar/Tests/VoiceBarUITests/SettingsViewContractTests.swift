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
        XCTAssertTrue(source.contains("historyMediaPartActions"))
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

    func testHistoryRowsUseOnlyTheSpinningButtonForInFlightFeedback() throws {
        let settingsSource = try settingsViewSource()
        let barSource = try barViewSource()
        let appSource = try voiceBarAppSource()

        XCTAssertTrue(settingsSource.contains("isHistoryRetranscribing"))
        XCTAssertFalse(settingsSource.contains("Text(\"Re-transcribing...\")"))
        XCTAssertFalse(settingsSource.contains(".opacity(isRetranscribing ?"))
        XCTAssertTrue(settingsSource.contains("historyMediaPartActions(part, isRetranscribing: isRetranscribing)"))
        XCTAssertTrue(settingsSource.contains("isSpinning: isRetranscribing"))
        XCTAssertTrue(settingsSource.contains(".rotationEffect(.degrees(isSpinning ? 360 : 0))"))
        XCTAssertTrue(settingsSource.contains(".repeatForever(autoreverses: false)"))
        XCTAssertTrue(settingsSource.contains("isRetranscribing ? \"Re-transcribing stored audio\""))
        XCTAssertTrue(settingsSource.contains("let disabled = !part.isEnabled(action) || isRetranscribing"))
        XCTAssertTrue(barSource.contains("activeHistoryRetranscriptionPath"))
        XCTAssertTrue(barSource.contains("Re-transcribing..."))
        XCTAssertTrue(appSource.contains("voiceState.activeHistoryRetranscriptionPath == recordingPath"))
    }

    func testHistoryTabExposesRecordingAndAskScopesWithRecordingFirst() {
        XCTAssertEqual(SettingsHistoryScope.allCases, [.recording, .ask])
        XCTAssertEqual(SettingsHistoryScope.allCases.first, .recording)
        XCTAssertEqual(SettingsHistoryScope.recording.title, "Recording")
        XCTAssertEqual(SettingsHistoryScope.ask.title, "Ask")
    }

    func testHistoryTabRendersASegmentedScopePickerDefaultingToRecording() throws {
        let source = try settingsViewSource()

        XCTAssertTrue(source.contains("historyScopePicker"))
        XCTAssertTrue(source.contains("Picker(\"History scope\""))
        XCTAssertTrue(source.contains(".pickerStyle(.segmented)"))
        XCTAssertTrue(source.contains("initialHistoryScope: SettingsHistoryScope = .recording"))
        XCTAssertTrue(source.contains("case .recording:"))
        XCTAssertTrue(source.contains("case .ask:"))
    }

    func testAskScopeRendersBothSidesOfTheExchangeWithPlayableAudio() throws {
        let source = try settingsViewSource()

        XCTAssertTrue(source.contains("SettingsHistoryRowModel.ask(entry)"))
        XCTAssertTrue(source.contains("historyEntryRow"))
        XCTAssertTrue(source.contains("historyMediaPartRow"))
        XCTAssertTrue(source.contains("historyPlayback.toggle"))
        XCTAssertTrue(source.contains("historyPlayback.isPlaying"))
        XCTAssertTrue(source.contains("onRevealHistoryFile(audioPath)"))
    }

    func testBothHistoryScopesUseTheSharedPinnedDayAndCardSeam() throws {
        let source = try settingsViewSource()

        XCTAssertEqual(
            source.components(separatedBy: "pinnedViews: [.sectionHeaders]").count - 1,
            2
        )
        XCTAssertTrue(source.contains("private func historyDaySection"))
        XCTAssertTrue(source.contains("private func historyDayHeader"))
        XCTAssertTrue(source.contains("private func historyEntryRow"))
        XCTAssertTrue(source.contains("private func historyMediaPartRow"))
        XCTAssertFalse(source.contains("askHistoryDaySection"))
        XCTAssertFalse(source.contains("askEntryRow"))
        XCTAssertFalse(source.contains("askSideRow"))
        XCTAssertFalse(source.contains("historyEntryActions"))
    }

    func testSharedHistoryPresentationPreservesOrderedPartsAndCapabilities() {
        let recordingURL = URL(fileURLWithPath: "/tmp/recording/audio.wav")
        let recording = SettingsHistoryEntry(
            id: recordingURL.path,
            dayKey: "2026-08-21",
            recordingID: "recording",
            createdAt: Date(timeIntervalSince1970: 0),
            transcript: "Recorded words",
            audioPath: recordingURL
        )
        let recordingRow = SettingsHistoryRowModel.recording(recording)

        XCTAssertEqual(recordingRow.parts.map(\.role), [.recording])
        XCTAssertNil(recordingRow.parts[0].label)
        XCTAssertEqual(
            recordingRow.parts[0].actions,
            [.play, .copy, .paste, .retranscribe, .finder]
        )

        let ask = SettingsAskHistoryEntry(
            id: "/tmp/ask",
            dayKey: "2026-08-21",
            askID: "ask",
            createdAt: Date(timeIntervalSince1970: 0),
            questionText: "Question",
            questionAudioPath: URL(fileURLWithPath: "/tmp/ask/agent-audio.mp3"),
            responseTranscript: "Response",
            responseAudioPath: URL(fileURLWithPath: "/tmp/ask/audio.wav")
        )
        let askRow = SettingsHistoryRowModel.ask(ask)

        XCTAssertEqual(askRow.parts.map(\.role), [.question, .response])
        XCTAssertEqual(askRow.parts.map(\.label), ["Question", "Response"])
        XCTAssertFalse(askRow.parts[0].isPlaceholder)
        XCTAssertEqual(askRow.parts[0].actions, [.play])
        XCTAssertEqual(askRow.parts[1].actions, [.play, .copy, .paste, .finder])
    }

    func testSharedHistoryCapabilitiesDisableActionsFromTheActualPart() {
        let retainedResponseURL = URL(fileURLWithPath: "/tmp/ask-missing/audio.wav")
        let ask = SettingsAskHistoryEntry(
            id: "/tmp/ask-missing",
            dayKey: "2026-08-21",
            askID: "ask-missing",
            createdAt: Date(timeIntervalSince1970: 0),
            questionText: "Question without audio",
            questionAudioPath: nil,
            responseTranscript: "",
            responseAudioPath: retainedResponseURL
        )
        let parts = SettingsHistoryRowModel.ask(ask).parts

        XCTAssertFalse(parts[0].isPlaceholder)
        XCTAssertTrue(parts[1].isPlaceholder)
        XCTAssertFalse(parts[0].isEnabled(.play))
        XCTAssertFalse(parts[0].actions.contains(.copy))
        XCTAssertFalse(parts[0].actions.contains(.finder))
        XCTAssertTrue(parts[1].isEnabled(.play))
        XCTAssertFalse(parts[1].isEnabled(.copy))
        XCTAssertFalse(parts[1].isEnabled(.paste))
        XCTAssertTrue(parts[1].isEnabled(.finder))
        XCTAssertEqual(parts[1].audioPath, retainedResponseURL)
    }

    func testHistoryActionsAreIconOnlyWithTooltipsAndAccessibleNames() throws {
        let source = try settingsViewSource()
        let actionsStart = try XCTUnwrap(source.range(of: "private func historyMediaPartActions"))
        let actionsEnd = try XCTUnwrap(source.range(of: "// MARK: - Dictionary Tab"))
        let actions = source[actionsStart.lowerBound ..< actionsEnd.lowerBound]

        XCTAssertTrue(actions.contains(".labelStyle(.iconOnly)"))
        XCTAssertTrue(actions.contains(".frame(minWidth: 28, minHeight: 28)"))
        XCTAssertTrue(actions.contains(".help(isPlaying ? \"Stop\" : \"Play\")"))
        XCTAssertTrue(actions.contains(".help(\"Copy\")"))
        XCTAssertTrue(actions.contains(".help(\"Paste\")"))
        XCTAssertTrue(actions.contains(".help(\"Re-transcribe\")"))
        XCTAssertTrue(actions.contains(".help(\"Open in Finder\")"))

        for accessibleName in [
            "Play \\(part.accessibilityNoun)",
            "Copy transcript",
            "Paste transcript",
            "Open stored audio in Finder",
        ] {
            XCTAssertTrue(
                actions.contains(".accessibilityLabel(\"\(accessibleName)\")"),
                "Missing explicit accessible name: \(accessibleName)"
            )
        }
        XCTAssertTrue(actions.contains("isRetranscribing ? \"Re-transcribing stored audio\""))
        XCTAssertTrue(actions.contains(": \"Re-transcribe stored audio\""))
    }

    func testSharedHistoryUsesRecordingDurationRuleForAskResponse() {
        let ask = SettingsAskHistoryEntry(
            id: "/tmp/ask-duration",
            dayKey: "2026-08-21",
            askID: "ask-duration",
            createdAt: Date(timeIntervalSince1970: 0),
            questionText: "How long?",
            questionAudioPath: nil,
            responseTranscript: "Long enough",
            responseAudioPath: URL(fileURLWithPath: "/tmp/ask-duration/audio.wav"),
            responseDurationMs: 43400,
            responseTranscribedDurationMs: 40100
        )

        let response = SettingsHistoryRowModel.ask(ask).parts[1]

        XCTAssertEqual(response.durationLabel, "0:43")
        XCTAssertEqual(response.transcribedDurationLabel, "0:40")
    }

    func testAskScopeLoadsItsOwnPagedArchiveOffMainThread() throws {
        let source = try settingsViewSource()

        XCTAssertTrue(source.contains("askHistoryPage"))
        XCTAssertTrue(source.contains("SettingsAskHistoryArchive.loadPage"))
        XCTAssertTrue(source.contains("isAskHistoryLoading"))
        XCTAssertTrue(source.contains("askHistoryLoadedEntryLimit"))
        XCTAssertTrue(source.contains("loadOlderAskHistory"))
    }

    func testRecordingScopeStillReadsOnlyTheRecordingArchive() throws {
        let source = try settingsViewSource()
        let recordingLoad = try XCTUnwrap(source.range(of: "SettingsHistoryArchive.loadPage"))

        XCTAssertNotNil(recordingLoad)
        XCTAssertFalse(source.contains("SettingsHistoryArchive.loadAskPage"))
        XCTAssertFalse(source.contains("historyDayGroups = Self.newestFirstAskHistoryGroups"))
    }

    func testRecentTranscriptsDropdownNeverReadsTheAskArchive() throws {
        for file in ["PillContextMenuController.swift", "VoiceState.swift", "VoiceBarPresentation.swift"] {
            let source = try uiSource(named: file)
            XCTAssertFalse(
                source.contains("SettingsAskHistoryArchive"),
                "\(file) must not surface voice_ask exchanges in the recent-transcripts dropdown"
            )
            XCTAssertFalse(
                source.contains("SettingsAskHistoryEntry"),
                "\(file) must not surface voice_ask exchanges in the recent-transcripts dropdown"
            )
        }
    }

    func testCancellingHistoryLoadsAlsoClearsTheirLoadingFlags() throws {
        let source = try settingsViewSource()

        // A stranded `true` leaves the spinner up and "Load older" disabled for the session,
        // because a scope with entries reopens without reloading.
        XCTAssertTrue(source.contains("private func cancelHistoryLoads()"))
        XCTAssertTrue(source.contains("cancelHistoryLoads()"))
        XCTAssertFalse(source
            .contains(
                "historyRefreshTask?.cancel()\n            askHistoryRefreshTask?.cancel()\n            askPlayback.stop()"
            ))

        let helper = try XCTUnwrap(source.range(of: "private func cancelHistoryLoads() {"))
        let helperBody = source[helper.upperBound...].prefix(400)
        XCTAssertTrue(helperBody.contains("isHistoryLoading = false"))
        XCTAssertTrue(helperBody.contains("isAskHistoryLoading = false"))
    }

    func testSwitchingScopeReloadsTheScopeBeingShown() throws {
        let source = try settingsViewSource()
        let onChange = try XCTUnwrap(source.range(of: "onChange(of: selectedHistoryScope)"))
        let handler = source[onChange.upperBound...].prefix(400)

        // An inactive scope misses voiceBarHistoryArchiveDidChange, so both sides must reload
        // on switch rather than only when empty.
        XCTAssertTrue(handler.contains("requestHistoryReload()"))
        XCTAssertTrue(handler.contains("requestAskHistoryReload()"))
        XCTAssertFalse(handler.contains("askHistoryDayGroups.isEmpty"))
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

    private func uiSource(named fileName: String) throws -> String {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = repoRoot
            .appendingPathComponent("flow-bar")
            .appendingPathComponent("Sources")
            .appendingPathComponent("VoiceBarUI")
            .appendingPathComponent(fileName)
        return try String(contentsOf: url)
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
