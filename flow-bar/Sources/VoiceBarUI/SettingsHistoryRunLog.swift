import Foundation

/// A bounded presentation log, NOT an archive writer or a backend attempt ledger.
/// Only History requests sent by this app process are observed. No transcript is retained here.
public struct SettingsHistoryRunLog: Equatable, Sendable {
    public enum Outcome: String, Equatable, Sendable {
        case requested = "Requested"
        case accepted = "Accepted; result pending"
        case succeeded = "Result received"
        case failed = "Failed"
        case rejected = "Rejected"
        case unknown = "Outcome unknown"
    }

    public enum Acknowledgement: String, Equatable, Sendable {
        case pending = "Awaiting acknowledgement"
        case accepted = "Request accepted"
        case rejected = "Request rejected"
    }

    public struct Run: Identifiable, Equatable, Sendable {
        public let id: String
        let path: String
        public let startedAt: Date
        public var observedAt: Date
        public var outcome: Outcome
        public var detail: String?
        public var acknowledgement: Acknowledgement = .pending
        /// Recording-level evidence; the protocol does not identify the backend attempt.
        public var recordingObservations: [String] = []
        public var omittedObservationCount = 0
        public var recordingObservation: String? { recordingObservations.last }
    }

    public private(set) var runs: [Run] = []
    public private(set) var omittedCount = 0
    public static let capacity = 30

    public init() {}

    public func runs(for path: String) -> [Run] { runs.filter { $0.path == path } }

    public mutating func begin(id: String, path: String, at: Date = Date()) {
        guard !runs.contains(where: { $0.id == id }) else { return }
        runs.insert(Run(id: id, path: path, startedAt: at, observedAt: at, outcome: .requested), at: 0)
        if runs.count > Self.capacity {
            omittedCount += runs.count - Self.capacity
            runs.removeLast(runs.count - Self.capacity)
        }
    }

    /// Passive observer. It never changes request ownership, capture, paste or retry control.
    public mutating func observe(_ event: [String: Any], at: Date = Date()) {
        switch event["type"] as? String {
        case "ack":
            guard event["command"] as? String == "retranscribe_recording",
                  let id = event["id"] as? String,
                  let index = runs.firstIndex(where: { $0.id == id }),
                  let outcome = event["outcome"] as? String,
                  runs[index].acknowledgement != .rejected else { return }
            if outcome == "accept" {
                runs[index].acknowledgement = .accepted
                set(index, runs[index].outcome == .unknown ? .unknown : .accepted,
                    at: at, detail: "Request acknowledged. Engine, model and result attempt ID are not reported.")
            } else if outcome == "reject" || outcome == "busy" {
                runs[index].acknowledgement = .rejected
                set(index, .rejected, at: at, detail: event["reason"] as? String)
            }
        case "transcription":
            guard event["partial"] as? Bool != true,
                  let path = event["recording_path"] as? String,
                  let text = event["text"] as? String else { return }
            // A single visible request is still ambiguous: another client or a duplicate old
            // result can share this path. Never infer attempt success from recording identity.
            let observation = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "Empty final result observed for this recording. It cannot be attributed to this request."
                : "Final result observed for this recording. It cannot be attributed to this request or prove an archive write."
            for index in unresolved(for: path) { note(index, observation, at: at) }
        case "error":
            let message = event["message"] as? String ?? "Error detail unavailable"
            for index in runs.indices where runs[index].acknowledgement != .rejected {
                if message.hasPrefix("Could not retranscribe archived recording \(runs[index].path). ") {
                    note(index, "Recording-linked error; attribution to this request is unavailable. " + message, at: at)
                } else {
                    note(index, "An uncorrelated error was observed; attribution to this request is unavailable.", at: at)
                }
            }
        case "state":
            guard event["state"] as? String == "idle", event["source"] as? String == "recording" else { return }
            for index in runs.indices where runs[index].outcome == .requested || runs[index].outcome == .accepted {
                note(index, "Recording became idle without an attributable result. A previous saved transcript is not proof this run succeeded.", at: at)
            }
        default: break
        }
    }

    private func unresolved(for path: String) -> [Int] {
        runs.indices.filter { runs[$0].path == path && [.requested, .accepted, .unknown].contains(runs[$0].outcome) }
    }

    private mutating func note(_ index: Int, _ observation: String, at: Date) {
        runs[index].outcome = .unknown
        runs[index].observedAt = at
        let projected = SettingsHistoryDiagnosticPrivacy.text(observation)
        guard runs[index].recordingObservations.last != projected else { return }
        runs[index].recordingObservations.append(projected)
        if runs[index].recordingObservations.count > 4 {
            runs[index].recordingObservations.removeFirst()
            runs[index].omittedObservationCount += 1
        }
    }

    private mutating func set(_ index: Int, _ outcome: Outcome, at: Date, detail: String?) {
        runs[index].outcome = outcome
        runs[index].observedAt = at
        runs[index].detail = detail.map(SettingsHistoryDiagnosticPrivacy.text)
    }
}

/// A local display/copy projection. Raw archive bytes are never changed or exported.
public enum SettingsHistoryDiagnosticPrivacy {
    public static func text(_ value: String) -> String {
        var result = String(value.prefix(8192))
        for pattern in [
            "(?i)\\b(?:bearer\\s+|(?:api[_-]?key|token|password|secret)\\s*[:=]\\s*)[^\\s,;]+",
            "\\bsk-[A-Za-z0-9_-]+",
            "(?:https?|file)://[^\\s]+",
            "(?:~?/|[A-Za-z]:\\\\)[^\\s<>\\\"']+"
        ] {
            result = result.replacingOccurrences(of: pattern, with: "[redacted]", options: .regularExpression)
        }
        result = String(result.unicodeScalars.filter { scalar in
            scalar == "\n" || scalar == "\t" || (!CharacterSet.controlCharacters.contains(scalar) && ![0x202A, 0x202B, 0x202C, 0x202D, 0x202E, 0x2066, 0x2067, 0x2068, 0x2069].contains(scalar.value))
        })
        let omitted = value.count > 8192 || result.count > 4096
        return String(result.prefix(4096)) + (omitted ? "\n[Detail limited to 4,096 characters]" : "")
    }
}
