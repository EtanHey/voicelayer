import Foundation

/// CLICK2: privacy-safe click telemetry. A fixed event and field allowlist, one JSON line per record.
/// Never text, selections, command/event dictionaries, window titles or error messages.
public enum ClickTelemetry {
    public static let events: Set<String> = [
        "command_dispatch", "playback_state_apply", "playback_state_drop", "playback_control_ack", "teleprompter_hide",
    ]
    /// Commands a pill or teleprompter click sends; health polls and settings writes are not click telemetry.
    public static let dispatchedCommands: Set<String> = ["pause", "resume", "replay", "stop", "cancel", "read_next", "seek"]
    static let fields: Set<String> = [
        "timestamp", "command", "command_id", "appActive", "panelKey", "frontmost_bundle_id",
        "state", "generation", "expected_generation", "generation_match", "playback_id",
        "outcome", "reason", "owned", "dismissed", "previous_dismissed",
    ]
    /// Fixed daemon ack reasons; anything else is reported as `unlisted`, never echoed.
    static let reasons: Set<String> = [
        "already paused", "busy", "not paused", "nothing playing", "parked", "paused", "resuming", "stale", "unsupported",
    ]

    public static func timestamp(_ date: Date = Date()) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    /// A machine identifier (command, player or bundle ID), or nil; nothing free-form gets through.
    public static func identifier(_ value: Any?) -> String? {
        guard let value = value as? String, (1...128).contains(value.utf8.count),
              value.unicodeScalars.allSatisfy({ $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "-_.:".unicodeScalars.contains($0)) })
        else { return nil }
        return value
    }

    public static func outcome(_ value: Any?) -> String {
        guard let value = value as? String else { return "null" }
        return ["accept", "noop", "reject"].contains(value) ? value : "other"
    }

    public static func reason(_ value: Any?) -> String {
        guard let value = value as? String else { return "null" }
        return reasons.contains(value) ? value : "unlisted"
    }

    /// The dispatch record for an outgoing click command, from the app state read at that moment.
    public static func dispatchFields(
        command: [String: Any], appActive: Bool, panelKey: Bool, frontmostBundleID: String?, now: Date = Date()
    ) -> [String: String]? {
        guard let cmd = command["cmd"] as? String, dispatchedCommands.contains(cmd) else { return nil }
        return [
            "timestamp": timestamp(now),
            "command": cmd,
            "command_id": identifier(command["id"]) ?? "null",
            "appActive": appActive ? "true" : "false",
            "panelKey": panelKey ? "true" : "false",
            "frontmost_bundle_id": identifier(frontmostBundleID) ?? "null",
        ]
    }

    /// One JSON line of the allowlisted fields; an unknown event is refused and unknown fields are dropped.
    public static func line(event: String, fields details: [String: String]) -> String? {
        guard events.contains(event) else { return nil }
        var record = details.filter { fields.contains($0.key) }
        record["event"] = event
        guard let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}
