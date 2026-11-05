import Foundation

public struct CloneEngineSnapshot: Codable, Equatable {
    public enum State: String, Codable { case running, starting, restarting, stopped, failed }
    public var state: State
    public var since: String
    public var reason: String?
    public var pid: Int?
    public var startWithVoiceBar: Bool
    enum CodingKeys: String, CodingKey {
        case state, since, reason, pid
        case startWithVoiceBar = "start_with_voicebar"
    }

    public init(state: State, since: String, reason: String?, pid: Int?, startWithVoiceBar: Bool) {
        self.state = state; self.since = since; self.reason = reason
        self.pid = pid; self.startWithVoiceBar = startWithVoiceBar
    }

    public init?(payload: [String: Any]) {
        guard payload["type"] as? String == "clone_engine", payload.keys.contains("pid"), payload.keys.contains("reason"),
              let data = try? JSONSerialization.data(withJSONObject: payload),
              let decoded = try? JSONDecoder().decode(Self.self, from: data),
              ISO8601DateFormatter().date(from: decoded.since) != nil,
              decoded.pid.map({ $0 > 0 && $0 <= Int(Int32.max) }) ?? true else { return nil }
        self = decoded
    }

    public var payload: [String: Any] {
        ["type": "clone_engine", "state": state.rawValue, "since": since,
         "reason": reason as Any? ?? NSNull(), "pid": pid as Any? ?? NSNull(), "start_with_voicebar": startWithVoiceBar]
    }
}
