@testable import VoiceBarUI
import XCTest

/// H1-d part 2 (UI pass #9 / #10): the list gets most of the height, re-entering History selects the newest row,
/// and the Ask list has no empty band above its first date.
final class SettingsHistoryLayoutTests: XCTestCase {
    /// UI pass #9: list and detail were each ~200 pt (3.5 rows visible).
    func testTheListAlwaysGetsMostOfTheHeight() {
        for available: CGFloat in [300, 400, 520, 700, 1000] {
            let detail = SettingsHistoryLayout.detailHeight(available: available)
            XCTAssertLessThan(detail, available - detail, "available \(available)")
        }
        XCTAssertEqual(SettingsHistoryLayout.detailHeight(available: 300), 114, accuracy: 0.001)
        XCTAssertEqual(SettingsHistoryLayout.detailHeight(available: 1000), 220)
        XCTAssertEqual(SettingsHistoryLayout.detailHeight(available: 100), 100)
    }

    func testReenteringHistorySelectsTheNewestRow() {
        XCTAssertEqual(
            SettingsHistoryLayout.selection(current: "older", entries: ["newest", "older"], preferNewest: true),
            "newest"
        )
    }

    func testOtherwiseTheSelectionStaysWhileItIsOnThePage() {
        XCTAssertEqual(
            SettingsHistoryLayout.selection(current: "older", entries: ["newest", "older"], preferNewest: false),
            "older"
        )
        XCTAssertEqual(
            SettingsHistoryLayout.selection(current: "gone", entries: ["newest", "older"], preferNewest: false),
            "newest"
        )
        XCTAssertEqual(SettingsHistoryLayout.selection(current: nil, entries: [], preferNewest: false), nil)
    }

    func testTheViewUsesTheLayoutRules() throws {
        let source = try settingsSource()
        XCTAssertTrue(source.contains("SettingsHistoryWorkspace {"))
        XCTAssertFalse(source.contains(".frame(maxHeight: 260)"), "the fixed 260 pt detail cap is gone")
        XCTAssertTrue(source.contains("historyMemory.applyPage(historyDayGroups.flatMap(\\.entries).map(\\.id))"))
        XCTAssertTrue(source.contains(".padding(.top, SettingsHistoryLayout.askListTopInset)"))
        XCTAssertLessThanOrEqual(SettingsHistoryLayout.askListTopInset, 8)
        XCTAssertTrue(source.contains("Color.clear.frame(height: 0).id(latestAskHistoryAnchorID)"),
                      "the Ask scroll anchor sits behind the stack, so no stack spacing follows it")
        // QA-06: re-entering the History tab reloads but no longer forces the newest row.
        let tabChange = try XCTUnwrap(source.range(of: ".onChange(of: selectedTab) { _, tab in"))
        let body = source[tabChange.lowerBound...].prefix(700)
        XCTAssertFalse(body.contains("historyMemory"), "a tab change never touches the remembered row")
        XCTAssertFalse(source.contains("selectNewestOnNextHistoryPage"))
    }

    func testRecordingPaginationFollowsAllDayGroupsInsideTheScrollList() throws {
        let source = try settingsSource()
        let scopeStart = try XCTUnwrap(source.range(of: "private var recordingHistoryScope: some View"))
        let scopeEnd = try XCTUnwrap(source.range(of: "private var selectedHistoryEntry:", range: scopeStart.upperBound..<source.endIndex))
        let scope = String(source[scopeStart.lowerBound..<scopeEnd.lowerBound])
        let listStart = try XCTUnwrap(scope.range(of: "ScrollView(.vertical) {"))
        // V27: the list's top inset now sits outside the scroll view, right after it closes.
        let listEnd = try XCTUnwrap(scope.range(of: "// V27: the top inset sits outside the scroll view", range: listStart.upperBound..<scope.endIndex))
        let list = String(scope[listStart.upperBound..<listEnd.lowerBound])
        let groupsEnd = try XCTUnwrap(list.range(of: "} header: { historyDayHeader(group.dayTitle(), coversAbove: 0) }"))
        let pagination = try XCTUnwrap(list.range(of: "if historyHasMore {"))
        XCTAssertLessThan(groupsEnd.upperBound, pagination.lowerBound, "pagination follows the day groups")
        XCTAssertEqual(list[groupsEnd.upperBound..<pagination.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines), "}",
                       "the day-group loop ends before pagination, so the button appears once")
        let paginationContent = list[pagination.upperBound...]
        XCTAssertTrue(paginationContent.contains("Button(SettingsHistoryRecordingCopy.loadMoreTitle(isLoading: isHistoryLoading)) { loadOlderHistory() }"))
        XCTAssertTrue(paginationContent.contains(".disabled(isHistoryLoading)"))
        XCTAssertFalse(scope[listEnd.upperBound...].contains("loadOlderHistory()"), "no pagination outside the list")
        XCTAssertTrue(scope.contains("\\(historyLoadedEntryCount) matches shown"))
        XCTAssertTrue(scope.contains("\\(historyLoadedEntryCount) saved shown"))
    }

    /// L7 review NIT: Load more reads as the quiet end of the list, centred and small, not as a row.
    func testLoadMoreIsSmallAndCentredUnderTheList() throws {
        XCTAssertEqual(SettingsHistoryRecordingCopy.loadMoreTitle(isLoading: false), "Load more")
        XCTAssertEqual(SettingsHistoryRecordingCopy.loadMoreTitle(isLoading: true), "Loading…")
        let source = try settingsSource()
        let button = try XCTUnwrap(source.range(of: "Button(SettingsHistoryRecordingCopy.loadMoreTitle(isLoading: isHistoryLoading)) { loadOlderHistory() }"))
        let modifiers = source[button.upperBound...].prefix(260)
        XCTAssertTrue(modifiers.contains(".controlSize(.small)"))
        XCTAssertTrue(modifiers.contains(".frame(maxWidth: .infinity)"))
    }

    /// L7 review LOW + Etan 02:54Z: every visible word of the list and pane is plain, with no jargon.
    /// Checked on the values the view renders, not on view source.
    func testVisibleListAndPaneCopyIsPlain() {
        let visible = [SettingsHistoryRecordingCopy.emptyTitle, SettingsHistoryRecordingCopy.emptyHint,
                       SettingsHistoryRecordingCopy.noSelection,
                       SettingsHistoryRecordingCopy.loadMoreTitle(isLoading: false)]
        XCTAssertTrue(SettingsHistoryRecordingCopy.emptyHint.hasSuffix("Select one to see its details."))
        for text in visible {
            for jargon in ["Errors & runs", "Archive backend", "Attempt identity", "Technical details", "Text saved"] {
                XCTAssertFalse(text.localizedCaseInsensitiveContains(jargon), "\(text) shows \(jargon)")
            }
        }
    }

    /// L7 review LOW: the archive-only rows keep their space while the read is in flight, and nothing is
    /// reserved (or guessed) once it has landed.
    func testArchiveOnlyFactsAreReservedOnlyWhileLoading() {
        let created = SettingsHistoryFact(title: "Created", value: "Nov 2, 2026 at 05:25")
        XCTAssertEqual(SettingsHistoryDiagnosticsPanel.reservedFactTitles(facts: [created], snapshotLoaded: false, hasRecording: true),
                       ["Language setting", "Engine"])
        XCTAssertEqual(SettingsHistoryDiagnosticsPanel.reservedFactTitles(facts: [created], snapshotLoaded: true, hasRecording: true), [])
        XCTAssertEqual(SettingsHistoryDiagnosticsPanel.reservedFactTitles(facts: [], snapshotLoaded: false, hasRecording: false), [])
        let attemptEngine = SettingsHistoryFact(title: "Engine", value: "Parakeet")
        XCTAssertEqual(SettingsHistoryDiagnosticsPanel.reservedFactTitles(facts: [created, attemptEngine], snapshotLoaded: false, hasRecording: true),
                       ["Language setting"], "a fact already shown is never reserved twice")
    }

    /// L7 review LOW: a narrow detail pane folds a log line instead of overflowing it, and a copy that
    /// lands is announced to VoiceOver.
    func testLogRowsFoldInsteadOfOverflowingAndCopyIsAnnounced() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Sources/VoiceBarUI/SettingsHistoryDiagnosticsView.swift"),
            encoding: .utf8
        )
        let row = try XCTUnwrap(source.range(of: "private func logRow(_ line: SettingsHistoryLogLine) -> some View {"))
        XCTAssertTrue(source[row.upperBound...].prefix(200).contains("ViewThatFits(in: .horizontal)"))
        XCTAssertTrue(source.contains("if copied { AccessibilityNotification.Announcement(\"Copied \\(label)\").post() }"))
    }

    /// QA-16 ("I don't need to know this is selected dictation"): the detail pane has no heading band, so
    /// no date or caption repeats above the transcript.
    func testDetailPaneHasNoHeadingAboveTheTranscript() throws {
        let source = try settingsSource()
        let pane = try XCTUnwrap(source.range(of: "SettingsHistoryAttemptDetailPane(entry: entry"))
        let content = try XCTUnwrap(source.range(of: "} content: { displayedEntry in", range: pane.upperBound..<source.endIndex))
        let header = source[pane.upperBound..<content.lowerBound]
        XCTAssertFalse(header.contains("Text("), "no caption above the transcript")
        XCTAssertFalse(header.contains("createdAt"), "the date belongs in Recording details")
        XCTAssertTrue(header.contains("EmptyView()"))
    }

    /// QA-06 (Etan, 2026-11-02: "the state is not kept between just traveling within the app").
    func testLeavingAndReturningKeepsTheRowAndItsDetailsState() {
        var memory = SettingsHistoryRecordingMemory()
        memory.applyPage(["newest", "three-minute", "oldest"])
        XCTAssertEqual(memory.selectedID, "newest", "a fresh Settings window opens on the newest row")
        memory.select("three-minute")
        memory.rememberDetailsExpanded(true, for: "three-minute")
        // Away to General and back: History reloads its page (a new dictation may have landed).
        memory.applyPage(["brand-new", "newest", "three-minute", "oldest"])
        XCTAssertEqual(memory.selectedID, "three-minute", "the row Etan left stays selected")
        XCTAssertEqual(memory.detailsExpanded(for: "three-minute"), true)
        XCTAssertNil(memory.detailsExpanded(for: "newest"), "another row keeps its own default")
        // A page that no longer holds it (a search) falls back to the newest match.
        memory.applyPage(["match-a", "match-b"])
        XCTAssertEqual(memory.selectedID, "match-a")
    }

    func testAPreloadedPageCountsAsTheFirstPage() {
        var memory = SettingsHistoryRecordingMemory(initialPage: ["newest", "older"])
        XCTAssertEqual(memory.selectedID, "newest")
        memory.select("older")
        memory.applyPage(["newest", "older"])
        XCTAssertEqual(memory.selectedID, "older")
    }

    private func settingsSource() throws -> String {
        try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Sources/VoiceBarUI/SettingsView.swift"),
            encoding: .utf8
        )
    }
}
