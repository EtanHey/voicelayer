import Foundation

enum SelectionAdmission: String {
    case submit, advance, stop, alreadyQueued

    static func identity(_ text: String) -> String {
        text.replacingOccurrences(of: #"(?m)^\h*(?:(?:[-+*]|[0-9]+[.)])\h+)?(?:\[[ xX]\]\h+)?"#,
                                  with: "", options: .regularExpression)
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    static func decide(_ text: String, playing: String?, pending: [String], count: Int) -> Self {
        let selected = identity(text)
        if let playing, selected == identity(playing) { return count > 0 ? .advance : .stop }
        if pending.contains(where: { identity($0) == selected }) { return .alreadyQueued }
        return .submit
    }
}
