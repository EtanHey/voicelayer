@testable import VoiceBarUI
import XCTest

/// R4/D1-b (UI pass #17, #18; Etan's M27 "a collapsible Personal section"): real words first, the saved term is
/// scrolled to, selected and flashed, and "Your terms" collapses like "Included terms".
final class DictionaryListOrderAndFocusTests: XCTestCase {
    private func personal(_ canonicals: [String]) -> [STTDictionaryDisplayEntry] {
        canonicals.map { STTDictionaryDisplayEntry(
            source: "personal",
            entry: STTDictionaryEntry(canonical: $0, variants: [])
        ) }
    }

    // MARK: - Ordering

    func testRealWordsSortBeforePunctuationAndSlashEntries() {
        let index = STTDictionaryDisplayIndex(entries: personal([
            "/catchup",
            "-s",
            "zsh",
            "Apple",
            "/batch",
            "2FA",
            "brainlayer",
        ]))

        XCTAssertEqual(
            index.entries(source: "personal", matching: "").map(\.entry.canonical),
            ["2FA", "Apple", "brainlayer", "zsh", "-s", "/batch", "/catchup"]
        )
    }

    func testOrderingStaysPerSourceAndSearchKeepsIt() {
        let entries = personal(["/batch", "Swift"]) + [
            STTDictionaryDisplayEntry(source: "bundled", entry: STTDictionaryEntry(canonical: ".NET", variants: [])),
            STTDictionaryDisplayEntry(source: "bundled", entry: STTDictionaryEntry(canonical: "AppKit", variants: [])),
        ]
        let index = STTDictionaryDisplayIndex(entries: entries)

        XCTAssertEqual(index.entries(source: "personal", matching: "").map(\.entry.canonical), ["Swift", "/batch"])
        XCTAssertEqual(index.entries(source: "bundled", matching: "").map(\.entry.canonical), ["AppKit", ".NET"])
        XCTAssertEqual(index.entries(source: "personal", matching: "s").map(\.entry.canonical), ["Swift"])
    }

    // MARK: - Focus after save (UI pass #18: the new term was not shown, highlighted or scrolled to)

    func testSavingScrollsToAndSelectsTheSavedTermsRow() {
        let focus = SettingsView.dictionaryFocus(afterSaving: "VoiceLayer", search: "")

        XCTAssertEqual(focus.rowID, "personal:VoiceLayer")
        XCTAssertFalse(focus.clearsSearch)
    }

    func testASearchThatWouldHideTheSavedTermIsCleared() {
        XCTAssertTrue(SettingsView.dictionaryFocus(afterSaving: "VoiceLayer", search: "swift").clearsSearch)
        XCTAssertFalse(SettingsView.dictionaryFocus(afterSaving: "VoiceLayer", search: "voice").clearsSearch)
    }

    /// #148 Macroscope (Medium): the list also matches misheard spellings, so a search that still shows the
    /// saved term through one of them must be kept.
    func testASearchMatchingASavedMisheardSpellingIsKept() {
        let focus = SettingsView.dictionaryFocus(afterSaving: "Swift", variants: ["swiftui"], search: "swiftui")

        XCTAssertFalse(focus.clearsSearch)
        XCTAssertTrue(SettingsView.dictionaryFocus(afterSaving: "Swift", variants: ["swiftui"], search: "kotlin")
            .clearsSearch)
    }

    /// #148 Macroscope (Medium, 4099482634): the "forced open" checks and the "N of N" titles used the untrimmed
    /// search, while matching trims it. A lone space forced both sections open with every row shown.
    func testAWhitespaceOnlySearchIsNotASearch() throws {
        XCTAssertEqual(SettingsView.dictionaryQuery(" "), "")
        XCTAssertEqual(SettingsView.dictionaryQuery("  swift "), "swift")

        let source = try settingsViewSource()
        XCTAssertFalse(source.contains("dictionarySearch.isEmpty"), "every check goes through the one trimmed query")
        XCTAssertTrue(source.contains("if yourTermsExpanded || isSearching {"))
        XCTAssertTrue(source.contains("if includedTermsExpanded || isSearching {"))
        XCTAssertTrue(source.contains("matches: isSearching ? personal.count : nil"))
        XCTAssertTrue(source.contains("matches: isSearching ? included.count : nil"))
    }

    // MARK: - Layout pins (SwiftUI builds no AX tree offscreen)

    func testYourTermsCollapsesLikeIncludedTerms() throws {
        let source = try settingsViewSource()

        XCTAssertTrue(source.contains("@State private var yourTermsExpanded"))
        XCTAssertTrue(source.contains("yourTermsExpanded.toggle()"))
        XCTAssertTrue(source.contains(".accessibilityValue(yourTermsExpanded ? \"Expanded\" : \"Collapsed\")"))
        XCTAssertTrue(source.contains("if yourTermsExpanded || isSearching {"))
    }

    func testTheSavedTermIsScrolledToSelectedAndFlashed() throws {
        let source = try settingsViewSource()

        XCTAssertTrue(source.contains("ScrollViewReader { proxy in"))
        XCTAssertTrue(source.contains(".id(row.rowID)"))
        XCTAssertTrue(source.contains("proxy.scrollTo(rowID, anchor: .center)"))
        XCTAssertTrue(source.contains("selectedTermRowID = focus.rowID"))
        XCTAssertTrue(source.contains("flashingTermRowID = focus.rowID"))
        XCTAssertTrue(source.contains(".accessibilityAddTraits(selectedTermRowID == rowID ? .isSelected : [])"))
    }

    private func settingsViewSource() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/VoiceBarUI/SettingsView.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }
}
