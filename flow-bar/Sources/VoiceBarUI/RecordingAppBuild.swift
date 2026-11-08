import Foundation

/// Stored capture identity. Missing legacy facts never fall back to the current app.
public struct RecordingAppBuild: Codable, Equatable, Sendable {
    public let version: String?
    public let gitCommit: String?
    public let buildTimeUTC: String?
    public let source: String?
    enum CodingKeys: String, CodingKey {
        case version, source
        case gitCommit = "git_commit", buildTimeUTC = "build_time_utc"
    }
    static func parse(_ value: Any?) -> Self? {
        guard let value = value as? [String: Any], let data = try? JSONSerialization.data(withJSONObject: value) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }
    public var label: String {
        let version = version.flatMap { $0.range(of: #"^\d+\.\d+\.\d+(?:[-+][A-Za-z0-9.-]+)?$"#, options: .regularExpression) != nil ? $0 : nil }
        let commit = gitCommit.flatMap { $0.range(of: #"^[a-fA-F0-9]{40}$"#, options: .regularExpression) != nil ? String($0.prefix(8)) : nil }
        guard version != nil || commit != nil else { return "Unknown build" }
        return "\(version ?? "unknown version") · \(commit ?? "unknown commit")"
    }
}
