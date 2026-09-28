import Foundation

/// C13 (QA recording 2026-09-25): after Reinstall, Etan couldn't tell whether it did anything. The line under the
/// F5 key helper now says which action ran, what the launchctl + hidutil probes read back afterwards, and when;
/// a failure says so plainly. This only reports: the installer and the probes are the app's, unchanged.
public struct SettingsRelaySetupResult: Equatable, Sendable {
    public enum Outcome: Equatable, Sendable {
        /// The installer exited 0 and every probe reads back ready.
        case ready
        /// The installer exited 0 but a probe still finds something missing, in the probe's own words.
        case needsAttention(missing: [String])
        /// The installer could not start, or exited non-zero.
        case failed(reason: String)
    }

    public let outcome: Outcome
    public let finishedAt: Date

    public init(outcome: Outcome, finishedAt: Date) {
        self.outcome = outcome
        self.finishedAt = finishedAt
    }

    /// Reads an installer run: its exit code, its combined output, and what the probes found missing after it.
    public static func installerRun(
        exitCode: Int32,
        output: String,
        missingAfter: [String],
        finishedAt: Date
    ) -> SettingsRelaySetupResult {
        guard exitCode == 0 else {
            let lastLine = output.split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .last { !$0.isEmpty }
            let reason = lastLine.map { "installer exited \(exitCode): \($0)" } ?? "installer exited \(exitCode)"
            return SettingsRelaySetupResult(outcome: .failed(reason: reason), finishedAt: finishedAt)
        }
        return SettingsRelaySetupResult(
            outcome: missingAfter.isEmpty ? .ready : .needsAttention(missing: missingAfter),
            finishedAt: finishedAt
        )
    }

    public var succeeded: Bool {
        outcome == .ready
    }
}

public enum SettingsRelaySetupFeedback {
    public enum Action: Equatable, Sendable {
        case setUp
        case reinstall

        var done: String {
            self == .reinstall ? "Reinstalled" : "Set up"
        }
    }

    public static func running(_ action: Action) -> String {
        action == .reinstall ? "Reinstalling…" : "Setting up…"
    }

    /// e.g. "Reinstalled · helper running · F5 and 🎤 mapped to F18 · checked 14:02".
    public static func line(
        for result: SettingsRelaySetupResult,
        action: Action,
        calendar: Calendar = .current
    ) -> String {
        let time = clockTime(result.finishedAt, calendar: calendar)
        switch result.outcome {
        case .ready:
            return "\(action.done) · helper running · F5 and 🎤 mapped to F18 · checked \(time)"
        case let .needsAttention(missing):
            return "\(action.done), but not working · \(missing.joined(separator: ", ")) · checked \(time)"
        case let .failed(reason):
            let verb = action == .reinstall ? "Reinstall" : "Set up"
            return "\(verb) failed · \(reason) · \(time)"
        }
    }

    private static func clockTime(_ date: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = calendar.locale ?? .current
        formatter.setLocalizedDateFormatFromTemplate("jmm")
        return formatter.string(from: date)
    }
}
