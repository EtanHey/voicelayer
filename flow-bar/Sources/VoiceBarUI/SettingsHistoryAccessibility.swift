import Foundation

/// VoiceOver text for History rows (H1-d, UI pass #7).
///
/// AIDEV-NOTE: A Dictations row used to expose its children, and each carried the transcript, so VoiceOver read
/// a 2-minute transcript four or five times per row. The row is now one element with this label: the opening
/// words, then when, how long, and at which effort.
enum SettingsHistoryAccessibility {
    static let openingLimit = 80

    static func rowLabel(
        _ entry: SettingsHistoryEntry,
        locale: Locale = .current,
        timeZone: TimeZone = .current
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        var parts = [
            entry.hasTranscript ? opening(entry.transcript, limit: openingLimit) : "No transcript stored",
            // ICU puts a narrow no-break space before "AM"; a plain space reads the same and compares plainly.
            formatter.string(from: entry.createdAt).replacingOccurrences(of: "\u{202F}", with: " "),
        ]
        if let durationMs = entry.durationMs, durationMs > 0 {
            parts.append(spokenDuration(milliseconds: durationMs))
        }
        if let effort = entry.performanceEffort {
            parts.append(effort.displayName)
        }
        return parts.joined(separator: ", ")
    }

    /// The first `limit` characters, cut back to a word boundary, with "…" when anything was cut.
    static func opening(_ text: String, limit: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed }
        let prefix = String(trimmed.prefix(limit))
        guard let space = prefix.lastIndex(where: \.isWhitespace) else { return prefix + "…" }
        return String(prefix[..<space]).trimmingCharacters(in: .whitespaces) + "…"
    }

    static func spokenDuration(milliseconds: Int) -> String {
        let total = Int((Double(milliseconds) / 1000).rounded())
        let (minutes, seconds) = (total / 60, total % 60)
        var parts: [String] = []
        if minutes > 0 { parts.append("\(minutes) minute\(minutes == 1 ? "" : "s")") }
        if seconds > 0 || parts.isEmpty { parts.append("\(seconds) second\(seconds == 1 ? "" : "s")") }
        return parts.joined(separator: " ")
    }
}
