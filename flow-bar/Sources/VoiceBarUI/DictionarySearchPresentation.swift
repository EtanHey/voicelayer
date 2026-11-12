import SwiftUI

/// Settings › Dictionary search: "Add '<query>'" when nothing matches, and the Included terms sample.
enum DictionarySearchPresentation {
    /// "Add '<query>'" when a loaded dictionary has no row for the search: the trimmed query, else nil.
    static func addSuggestion(search: String, loaded: Bool, personalMatches: Int, includedMatches: Int) -> String? {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard loaded, !query.isEmpty, personalMatches == 0, includedMatches == 0 else { return nil }
        return query
    }

    static func addSuggestionTitle(_ query: String) -> String {
        "Add \u{201C}\(query)\u{201D}"
    }

    /// A few included terms shown as chips while the list is closed: the daemon's own rows, in display order.
    static func includedSample(_ entries: [STTDictionaryEntry], limit: Int = 8) -> [String] {
        Array(entries.prefix(limit).map(\.canonical))
    }

    static let includedExplanation =
        "Built-in. Your terms override these."
}

/// Chips that wrap onto as many lines as they need.
struct DictionaryChipFlow: Layout {
    var spacing: CGFloat = 6

    private func rows(width: CGFloat, subviews: Subviews) -> [[(index: Int, size: CGSize)]] {
        var rows: [[(index: Int, size: CGSize)]] = [[]]
        var lineWidth: CGFloat = 0
        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            let needed = rows[rows.count - 1].isEmpty ? size.width : lineWidth + spacing + size.width
            if needed > width, !rows[rows.count - 1].isEmpty {
                rows.append([(index, size)])
                lineWidth = size.width
            } else {
                rows[rows.count - 1].append((index, size))
                lineWidth = needed
            }
        }
        return rows
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let rows = rows(width: width, subviews: subviews)
        // Typed loop, not map/reduce/max chains: that expression timed out the type checker (PR #690).
        var height: CGFloat = 0
        var widest: CGFloat = 0
        for row in rows {
            var rowHeight: CGFloat = 0
            var rowWidth: CGFloat = 0
            for item in row {
                rowHeight = max(rowHeight, item.size.height)
                rowWidth += item.size.width
            }
            rowWidth += spacing * CGFloat(max(0, row.count - 1))
            height += rowHeight
            widest = max(widest, rowWidth)
        }
        height += spacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: proposal.width ?? widest, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            let rowHeight = row.map { $0.size.height }.max() ?? 0
            for item in row {
                subviews[item.index].place(at: CGPoint(x: x, y: y), anchor: .topLeading,
                                           proposal: ProposedViewSize(item.size))
                x += item.size.width + spacing
            }
            y += rowHeight + spacing
        }
    }
}
