import CoreGraphics

/// History layout rules (H1-d, UI pass #9 / #10), kept as plain functions so they can be tested.
enum SettingsHistoryLayout {
    /// Space above the first Ask date header. It was ~50 pt: the list's 18 pt padding, plus the 18 pt stack
    /// spacing after the scroll anchor, plus the header's own inset.
    static let askListTopInset: CGFloat = 6

    /// UI pass #9: list and detail were each ~200 pt, 3.5 rows visible. The detail gets at most 38 % of the
    /// space (between 110 and 220 pt); the list gets the rest.
    static func detailHeight(available: CGFloat) -> CGFloat {
        min(220, max(110, available * 0.38))
    }

    /// Which Dictations row is selected after a page lands. Re-entering History selects the newest row: a
    /// kept older selection had scrolled out of view, so the detail belonged to no visible row (UI pass #9).
    /// Otherwise the selection stays while it is still on the page.
    static func selection(current: String?, entries: [String], preferNewest: Bool) -> String? {
        guard !preferNewest, let current, entries.contains(current) else { return entries.first }
        return current
    }
}
