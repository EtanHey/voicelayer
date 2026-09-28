import Foundation

/// A History search query (H1-c; Etan: "add search, separately for Recording and Ask").
///
/// AIDEV-NOTE: The query is trimmed, and whitespace alone is not a search (the #148 lesson from the Dictionary
/// search). Matching ignores case and diacritics, so "cafe" finds "Café"; Hebrew matches as typed.
public struct SettingsHistorySearch: Equatable, Sendable {
    public let query: String
    /// The query folded the same way as the text it is compared with.
    let foldedQuery: String

    public init(_ raw: String) {
        query = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        foldedQuery = Self.fold(query)
    }

    public var isActive: Bool {
        !query.isEmpty
    }

    /// True when not searching, or when any of `texts` contains the query.
    public func matches(_ texts: String...) -> Bool {
        guard isActive else { return true }
        return texts.contains { matches(folded: Self.fold($0)) }
    }

    /// The one comparison search uses; the index folds each entry's text once and keeps it.
    func matches(folded text: String) -> Bool {
        !isActive || text.contains(foldedQuery)
    }

    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}
