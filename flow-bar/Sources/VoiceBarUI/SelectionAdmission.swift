import Foundation

enum SelectionAdmission: String {
    case submit, advance, stop, alreadyQueued

    static func identity(_ text: String) -> String {
        var fence: (marker: Unicode.Scalar, length: Int)?
        let lines = text.components(separatedBy: .newlines).map { line in
            let trimmed = line.replacingOccurrences(of: #"^ {0,3}(?=[`~])"#, with: "", options: .regularExpression)
            let marker = trimmed.unicodeScalars.first
            let run = trimmed.unicodeScalars.prefix { $0 == marker }
            let delimiter = (marker == "`" || marker == "~") && run.count >= 3
            if let open = fence {
                if delimiter, marker == open.marker, run.count >= open.length,
                   String(String.UnicodeScalarView(trimmed.unicodeScalars.dropFirst(run.count))).trimmingCharacters(in: .whitespaces).isEmpty { fence = nil }
                return line
            }
            if delimiter, let marker {
                fence = (marker, run.count)
                return line
            }
            if line.range(of: #"^(?: {4}| {0,3}\t)"#, options: .regularExpression) != nil { return line }
            return line.replacingOccurrences(of: #"^[\t \p{Zs}]*(?:(?:[-+*]|[0-9]+[.)])[\t \p{Zs}]+)?(?:\[[ xX]\][\t \p{Zs}]+)?"#,
                                             with: "", options: .regularExpression)
        }
        func collapse(_ value: String) -> String {
            value.unicodeScalars.split(whereSeparator: { $0.properties.isWhitespace })
                .map(String.init).joined(separator: " ").precomposedStringWithCanonicalMapping
        }
        let normalized = collapse(lines.joined(separator: "\n"))
        return normalized.isEmpty ? collapse(text) : normalized
    }

    static func decide(_ text: String, playing: String?, pending: [String], count: Int) -> Self {
        let selected = identity(text)
        if let playing, selected == identity(playing) { return count > 0 ? .advance : .stop }
        if pending.contains(where: { identity($0) == selected }) { return .alreadyQueued }
        return .submit
    }
}
