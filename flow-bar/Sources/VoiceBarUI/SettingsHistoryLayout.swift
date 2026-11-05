import CoreGraphics

/// History layout rules (H1-d, UI pass #9 / #10), kept as plain functions so they can be tested.
enum SettingsHistoryLayout {
    /// Space above the first Ask date header. It was ~50 pt: the list's 18 pt padding, plus the 18 pt stack
    /// spacing after the scroll anchor, plus the header's own inset.
    static let askListTopInset: CGFloat = 6

    /// UI pass #9: list and detail were each ~200 pt, 3.5 rows visible. The detail gets at most 38 % of the
    /// space (between 110 and 220 pt); the list gets the rest.
    static func detailHeight(available: CGFloat) -> CGFloat {
        min(max(0, available), min(220, max(110, available * 0.38)))
    }

    struct Regions {
        let list: CGRect
        let divider: CGRect
        let detail: CGRect
        let sideBySide: Bool
    }

    static func clampFraction(_ fraction: CGFloat, maximum: CGFloat = 0.6) -> CGFloat {
        fraction.isFinite ? min(maximum, max(0.2, fraction)) : 0.32
    }

    /// The exact rectangles used by the workspace. The 8 pt divider is counted inside the viewport.
    static func regions(size: CGSize, listFraction: CGFloat = 0.32) -> Regions {
        let width = size.width.isFinite ? max(0, size.width) : 0
        let height = size.height.isFinite ? max(0, size.height) : 0
        // A 780 pt Settings window leaves 607 pt after its sidebar. Stacking that
        // minimum window halves a 345 pt workspace and leaves only 51.5 pt to scroll.
        // Two columns keep the full height, with room for four rows and a readable detail.
        let horizontal = width >= 600
        let length = horizontal ? width : height
        let divider = min(8, length)
        let usable = max(0, length - divider)
        if horizontal {
            let minimumList: CGFloat = 220
            let minimumDetail: CGFloat = 360
            let list = min(usable - minimumDetail, max(minimumList, usable * clampFraction(listFraction)))
            return Regions(list: CGRect(x: 0, y: 0, width: list, height: height),
                divider: CGRect(x: list, y: 0, width: divider, height: height),
                detail: CGRect(x: list + divider, y: 0, width: usable - list, height: height), sideBySide: true)
        }
        // At standard height, 260 pt fits at least four 48 pt rows plus header/insets.
        // Compact viewports retain both panes, and the divider still has travel.
        let minimumList = usable >= 460 ? 260 : usable * 0.5
        let minimumDetail = min(160, usable * 0.4)
        let list = min(usable - minimumDetail,
                       max(minimumList, usable * clampFraction(listFraction, maximum: 0.85)))
        return Regions(list: CGRect(x: 0, y: 0, width: width, height: list),
            divider: CGRect(x: 0, y: list, width: width, height: divider),
            detail: CGRect(x: 0, y: list + divider, width: width, height: usable - list), sideBySide: false)
    }

    /// Which Dictations row is selected after a page lands. Re-entering History selects the newest row: a
    /// kept older selection had scrolled out of view, so the detail belonged to no visible row (UI pass #9).
    /// Otherwise the selection stays while it is still on the page.
    static func selection(current: String?, entries: [String], preferNewest: Bool) -> String? {
        guard !preferNewest, let current, entries.contains(current) else { return entries.first }
        return current
    }
}

/// QA-06 (Etan, 2026-11-02: "the state is not kept between just traveling within the app"): what the
/// Dictations list keeps while Settings is open. SettingsView owns it, so it outlives the History tab;
/// leaving History and coming back restores the same row and keeps its Recording details open or
/// closed. Scroll positions live in SettingsHistoryScrollMemory, independent of the selection. Only a fresh Settings window starts again from the newest row.
struct SettingsHistoryRecordingMemory: Equatable {
    private(set) var selectedID: String?
    private var hasPage: Bool
    private var detailsEntryID: String?
    private var detailsExpandedValue: Bool?

    init(initialPage ids: [String]? = nil) {
        hasPage = ids != nil
        selectedID = ids?.first
    }

    mutating func select(_ id: String) { selectedID = id }

    /// A row asked for from outside (a notch History row click): selected now and kept by the next page while that
    /// page has it, falling back to the newest otherwise, exactly as a user's own pick is.
    mutating func request(_ id: String) {
        selectedID = id
        hasPage = true
    }

    /// The first page selects the newest row. Every later page (a refresh, a search, Load more, coming back
    /// to History) keeps the remembered row while it is still loaded, and falls back to the newest otherwise.
    mutating func applyPage(_ ids: [String]) {
        selectedID = SettingsHistoryLayout.selection(current: selectedID, entries: ids, preferNewest: !hasPage)
        hasPage = true
    }

    /// The open/closed state the user left this recording's details in; nil means use the default.
    func detailsExpanded(for id: String) -> Bool? { detailsEntryID == id ? detailsExpandedValue : nil }

    mutating func rememberDetailsExpanded(_ expanded: Bool, for id: String) {
        detailsEntryID = id; detailsExpandedValue = expanded
    }
}

/// Visible words of the Dictations list and detail pane, kept as values so tests read what the user
/// reads instead of grepping view source.
enum SettingsHistoryRecordingCopy {
    static let emptyTitle = "No transcript history yet"
    static let emptyHint = "Saved recordings, including failed or cancelled ones, will appear here. Select one to see its details."
    static let noSelection = "Select a dictation to read its transcript."
    static func loadMoreTitle(isLoading: Bool) -> String { isLoading ? "Loading…" : "Load more" }
}
