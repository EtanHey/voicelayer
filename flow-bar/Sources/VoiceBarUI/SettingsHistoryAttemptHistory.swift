import Foundation

/// View-only projection of STATE's future per-recording attempt log, not a second state machine.
/// The STATE adapter owns format/version validation, safe I/O, ordering and completeness.
public struct SettingsHistoryAttemptRecord: Identifiable, Equatable, Sendable {
    public enum Status: Equatable, Sendable { case captured, transcribing, formatting, completed, failed, cancelled, timedOut }
    public let id: String
    public let status: Status
    public let startedAt: Date?
    public let technicalDetail: String?
    /// Immutable text supplied by the read-only adapter; never reconstructed from an archive summary.
    public let savedText: String?
    public let failureReason: String?
    /// Adapter-projected execution evidence for THIS attempt. STATE currently has none of these fields.
    public let engine: String?
    public let model: String?
    public let effort: String?
    public let audioDurationMs: Int?
    public let processingDurationMs: Int?
    public init(id: String, status: Status, startedAt: Date? = nil, technicalDetail: String? = nil,
                savedText: String? = nil, failureReason: String? = nil,
                engine: String? = nil, model: String? = nil, effort: String? = nil,
                audioDurationMs: Int? = nil, processingDurationMs: Int? = nil) {
        self.engine = Self.label(engine); self.model = Self.label(model); self.effort = Self.label(effort)
        self.audioDurationMs = audioDurationMs.flatMap { $0 > 0 ? $0 : nil }
        self.processingDurationMs = processingDurationMs.flatMap { $0 >= 0 ? $0 : nil }
        self.id = id; self.status = status; self.startedAt = startedAt
        self.technicalDetail = technicalDetail.map(SettingsHistoryDiagnosticPrivacy.text)
        self.savedText = savedText // Display and Copy keep these exact bytes, including retractions and tails.
        self.failureReason = failureReason.map {
            String(SettingsHistoryDiagnosticPrivacy.text($0).split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(80))
        }
    }
    private static func label(_ value: String?) -> String? {
        guard let value else { return nil }
        let clean = SettingsHistoryDiagnosticPrivacy.text(value).split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return clean.isEmpty ? nil : String(clean.prefix(80))
    }
    /// Spoken/copied only (VoiceOver label, Log copy); the visible facts show the engine by name.
    var executionLabel: String? {
        let values = [engine, model, effort.map { "Effort: \($0)" }].compactMap { $0 }
        return values.isEmpty ? nil : values.joined(separator: " · ")
    }
    /// This attempt's own processing time. Audio length is the recording's, shown once in the footer.
    var processingLabel: String? {
        processingDurationMs.flatMap { $0 > 0 ? SettingsHistoryDiagnosticsCopy.processingLabel($0) : nil }
    }
    func localTimestamp(locale: Locale = .current, timeZone: TimeZone = .current) -> String? {
        startedAt.map { SettingsHistoryDiagnosticsCopy.clockTime($0, locale: locale, timeZone: timeZone) }
    }
    var hasSavedText: Bool { savedText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false }
    var statusTitle: String {
        switch status {
        case .captured: "Saved"
        case .transcribing, .formatting: "Running"
        case .completed: "Finished"
        case .failed: "Failed"
        case .cancelled: "Cancelled"
        case .timedOut: "Timed out"
        }
    }
    var statusSymbol: String {
        switch status {
        case .completed: "checkmark"
        case .failed, .timedOut: "xmark"
        case .cancelled: "slash.circle"
        case .captured, .transcribing, .formatting: "clock"
        }
    }
    static func title(at index: Int) -> String { index == 0 ? "Original" : "Retry \(index)" }

}

public struct SettingsHistoryAttemptHistory: Equatable, Sendable {
    public let recordingPath: String
    public let attempts: [SettingsHistoryAttemptRecord]
    public let isComplete: Bool
    public let hasPartialResult: Bool
    public init(recordingPath: String, attempts: [SettingsHistoryAttemptRecord], isComplete: Bool, hasPartialResult: Bool = false) {
        self.recordingPath = recordingPath; self.attempts = attempts; self.isComplete = isComplete
        self.hasPartialResult = hasPartialResult
    }
    /// A stale or misrouted reader result must never appear under another selected recording.
    public func matching(_ audioPath: URL) -> Self? {
        recordingPath == audioPath.standardizedFileURL.path ? self : nil
    }
}

/// Inject STATE's reader here when its log contract is ready. Nil means no attempt log was supplied
/// (the shipping app injects none). It is NOT evidence that any history is missing: only the reader's
/// own `isComplete == false`, or an archive whose metadata could not establish an outcome, is.
public typealias SettingsHistoryAttemptLogReader = @Sendable (URL) async -> SettingsHistoryAttemptHistory?

/// One visible Log row. Every row is backed by a real event: an attempt from the per-recording
/// reader, the archive's saved result, or a retry request this app process sent. A row is never
/// synthesized from a missing field, and the archive's single result is never split into attempts.
struct SettingsHistoryLogLine: Identifiable, Equatable {
    enum Source: Equatable { case attempt(String), archivedTake, sessionRequest(String) }
    let source: Source
    let title: String
    let time: String?
    let outcome: String
    /// This row's own processing time. Nil when nothing measured it; never derived from observation times.
    let processing: String?
    let symbol: String
    let isProblem: Bool
    /// VoiceOver/copy only: engine, model and effort the reader reported for this attempt.
    var execution: String? = nil

    var id: String {
        switch source {
        case .attempt(let id): "attempt-\(id)"
        case .archivedTake: "archived-take"
        case .sessionRequest(let id): "request-\(id)"
        }
    }
    var attemptID: String? { if case .attempt(let id) = source { id } else { nil } }
    var text: String { [title, time, outcome, processing].compactMap { $0 }.joined(separator: "  ") }
    var accessibilityText: String { [title, time, outcome, processing, execution].compactMap { $0 }.joined(separator: ", ") }
}

struct SettingsHistoryFact: Equatable {
    let title: String
    let value: String
}

struct SettingsHistoryDiagnosticsCopy {
    /// Shown only when the archive itself could not establish this recording's outcome.
    static let incompleteDetails = "Details for this recording are unavailable."
    /// Shown only when the attempt reader says its own log is incomplete.
    static let incompleteAttempts = "Earlier attempts weren't saved for this recording."
    let summary: String
    let attempts: [SettingsHistoryAttemptRecord]
    let logLines: [SettingsHistoryLogLine]
    let notice: String?
    /// Copy payload behind the Log's copy icon: the visible rows, then the full provenance that used
    /// to sit in the on-screen "Technical details" block. Never rendered as visible text.
    let logCopyText: String
    let shouldExpand: Bool
    var defaultExpanded: Bool { shouldExpand }
    var visibleSentences: [String] { [summary, notice].compactMap { $0 }.filter { !$0.isEmpty } }

    init(snapshot: SettingsHistoryDiagnostics?, runs: [SettingsHistoryRunLog.Run], omittedCount: Int,
         attemptHistory: SettingsHistoryAttemptHistory?, recordingID: String? = nil,
         recordingEntry: SettingsHistoryEntry? = nil, locale: Locale = .current, timeZone: TimeZone = .current) {
        let recordingError = runs.first.map {
            $0.outcome == .rejected || $0.outcome == .failed || $0.recordingObservations.contains { $0.hasPrefix("Recording-linked error;") }
        } ?? false
        let partial = attemptHistory?.hasPartialResult == true || (attemptHistory == nil && snapshot?.archiveState == .partial)
        if partial { shouldExpand = true }
        else if let latest = attemptHistory?.attempts.last {
            shouldExpand = latest.status == .failed || latest.status == .timedOut
        } else { shouldExpand = recordingError || snapshot?.archiveState == .failed }
        attempts = attemptHistory?.attempts ?? []

        // Missing optional fields (engine, language, duration, timestamps) and an absent reader are
        // not evidence of missing history. A fresh take must never read as an old, incomplete one.
        if let attemptHistory { notice = attemptHistory.isComplete ? nil : Self.incompleteAttempts }
        else if snapshot?.archiveState == .unavailable { notice = Self.incompleteDetails }
        else { notice = nil }

        if partial {
            summary = "Partial text is saved."
        } else if attemptHistory?.isComplete == true {
            summary = "" // The Log rows already explain each attempt.
        } else if let snapshot {
            switch snapshot.archiveState {
            case .failed where snapshot.savedTextState == .present:
                summary = "The last transcription failed. Saved text is still available."
            case .failed: summary = "No text was saved from the last transcription."
            case .cancelled: summary = "" // The Log row says Cancelled.
            default:
                switch snapshot.savedTextState {
                case .present: summary = ""
                case .empty: summary = "The saved text is empty."
                case .unavailable: summary = "Saved text is unavailable."
                }
            }
        } else { summary = "" }

        var lines: [SettingsHistoryLogLine] = []
        if let attemptHistory {
            // Durable per-recording attempts are the whole story; session requests would duplicate them.
            for (index, attempt) in attemptHistory.attempts.enumerated() {
                lines.append(SettingsHistoryLogLine(
                    source: .attempt(attempt.id), title: SettingsHistoryAttemptRecord.title(at: index),
                    time: attempt.localTimestamp(locale: locale, timeZone: timeZone),
                    outcome: attempt.failureReason?.isEmpty == false ? attempt.failureReason! : attempt.statusTitle,
                    processing: attempt.processingLabel, symbol: attempt.statusSymbol,
                    isProblem: attempt.status == .failed || attempt.status == .timedOut,
                    execution: attempt.executionLabel))
            }
        } else {
            if let snapshot, let take = Self.archivedTake(snapshot, entry: recordingEntry, locale: locale, timeZone: timeZone) {
                lines.append(take)
            }
            // Oldest first, like the attempt log. Unnumbered: earlier sessions' retries are not known.
            for run in runs.reversed() { lines.append(Self.requestLine(run, locale: locale, timeZone: timeZone)) }
        }
        logLines = lines

        var copyText: [String] = []
        if let recordingID { copyText.append("Recording ID: \(recordingID)") }
        copyText += lines.map(\.text)
        var provenance: [String] = []
        if let snapshot {
            provenance += ["Recording: \(snapshot.selection)", snapshot.summary, snapshot.savedResult]
            if let date = snapshot.capturedAt { provenance.append("Capture time: \(date.formatted(date: .abbreviated, time: .standard))") }
            if let backend = snapshot.backend { provenance.append("Backend: \(backend)") }
            if let model = snapshot.model { provenance.append("Model: \(model)") }
            if let detail = snapshot.detail { provenance.append(detail) }
            provenance += snapshot.warnings
        }
        if let recordingEntry { provenance.append(SettingsDiagnosticSummary.historyMetadata(recordingEntry)) }
        for attempt in attempts {
            provenance.append("Attempt \(attempt.id): \(String(describing: attempt.status))")
            if let execution = attempt.executionLabel { provenance.append(execution) }
            if let detail = attempt.technicalDetail { provenance.append(detail) }
        }
        if !runs.isEmpty {
            provenance.append("Session requests are this app process only; their times are observation times, not processing times.")
        }
        for run in runs {
            provenance += ["Request \(run.id): \(run.outcome.rawValue); \(run.acknowledgement.rawValue)",
                           "Requested \(run.startedAt); observed \(run.observedAt)"]
            if let detail = run.detail { provenance.append(detail) }
            provenance += run.recordingObservations
            if run.omittedObservationCount > 0 { provenance.append("\(run.omittedObservationCount) older recording observations omitted (4-observation limit).") }
        }
        if omittedCount > 0 { provenance.append("\(omittedCount) older session requests omitted (30-request limit).") }
        // Every input is already bounded/redacted independently; preserve their individual limit markers.
        logCopyText = ([copyText.joined(separator: "\n")] + provenance).filter { !$0.isEmpty }
            .map(SettingsHistoryDiagnosticPrivacy.text).joined(separator: "\n\n")
    }

    /// The archive keeps the latest saved result, not the original attempt's outcome. Use the
    /// transcript's write time when available; aggregate processing is shown once in the footer.
    /// An archive that could not establish an outcome gets no row, so nothing is asserted about it.
    static func archivedTake(_ snapshot: SettingsHistoryDiagnostics, entry: SettingsHistoryEntry?,
                             locale: Locale, timeZone: TimeZone) -> SettingsHistoryLogLine? {
        guard snapshot.archiveState != .unavailable else { return nil }
        let (outcome, symbol, problem): (String, String, Bool) = switch snapshot.archiveState {
        case .transcribed: ("Finished", "checkmark", false)
        case .partial: ("Partial text", "exclamationmark.circle", true)
        case .failed: ("Failed", "xmark", true)
        case .cancelled: ("Cancelled", "slash.circle", false)
        case .captured, .unavailable: ("Not transcribed", "clock", false)
        }
        let time = (snapshot.transcriptWrittenAt ?? snapshot.capturedAt ?? entry?.createdAt)
            .map { clockTime($0, locale: locale, timeZone: timeZone) }
        return SettingsHistoryLogLine(source: .archivedTake, title: "Saved result", time: time, outcome: outcome,
            processing: nil,
            symbol: symbol, isProblem: problem)
    }

    /// A retry this process asked for. Outcomes are plain words; ambiguous evidence stays ambiguous.
    static func requestLine(_ run: SettingsHistoryRunLog.Run, locale: Locale, timeZone: TimeZone) -> SettingsHistoryLogLine {
        let last = run.recordingObservation ?? ""
        let linkedError = run.recordingObservations.contains { $0.hasPrefix("Recording-linked error;") }
        let (outcome, symbol, problem): (String, String, Bool) = switch run.outcome {
        case .rejected: ("Couldn't start", "xmark", true)
        case .failed: ("Failed", "xmark", true)
        case .succeeded: ("Finished", "checkmark", false)
        case .accepted: ("Running", "clock", false)
        case .requested: ("Requested", "clock", false)
        case .unknown:
            if linkedError { ("Problem reported", "exclamationmark.circle", true) }
            else if last.hasPrefix("Final result observed") { ("New text received", "checkmark", false) }
            else if last.hasPrefix("Empty final result") { ("Empty result", "minus.circle", false) }
            else if last.hasPrefix("Recording became idle") { ("No result", "minus.circle", false) }
            else { ("Outcome unclear", "questionmark.circle", false) }
        }
        return SettingsHistoryLogLine(source: .sessionRequest(run.id), title: "Retry",
            time: clockTime(run.startedAt, locale: locale, timeZone: timeZone), outcome: outcome,
            processing: nil, symbol: symbol, isProblem: problem)
    }

    /// Recording facts in reading order. The detail heading has no date; Created appears here once.
    /// Engine sits beside Language; audio length and total processing live in the footer.
    static func facts(snapshot: SettingsHistoryDiagnostics?, entry: SettingsHistoryEntry?,
                      attemptHistory: SettingsHistoryAttemptHistory?, selectedAttemptID: String?,
                      locale: Locale = .current, timeZone: TimeZone = .current) -> [SettingsHistoryFact] {
        var facts: [SettingsHistoryFact] = []
        if let created = snapshot?.capturedAt ?? entry?.createdAt {
            facts.append(.init(title: "Created", value: dateTime(created, locale: locale, timeZone: timeZone)))
        }
        // Stored input_device_name values, never the currently selected microphone.
        if let mic = snapshot?.inputDeviceName ?? entry?.inputDeviceLabel { facts.append(.init(title: "Microphone", value: mic)) }
        if let language = snapshot?.languageSetting { facts.append(.init(title: "Language setting", value: language)) }
        let attempts = attemptHistory?.attempts ?? []
        if attempts.isEmpty {
            if let engine = engineName(snapshot?.backend) { facts.append(.init(title: "Engine", value: engine)) }
            facts += SettingsHistoryDiagnosticsPanel.legacyRecognitionFacts(entry, hasAttempts: false)
                .map { SettingsHistoryFact(title: $0.0, value: $0.1) }
            // The shipping app has no attempt reader. A later transcript write survives restarts;
            // allow the original capture, measured processing and 30 seconds before calling it a retry.
            if attemptHistory == nil, let writtenAt = snapshot?.transcriptWrittenAt,
               let created = snapshot?.capturedAt ?? entry?.createdAt {
                let initialSeconds = Double(max(0, entry?.durationMs ?? 0)) / 1000
                    + Double(max(0, entry?.processingDurationMs ?? 0)) / 1000
                if writtenAt > created.addingTimeInterval(initialSeconds + 30) {
                    facts.append(.init(title: "Last transcribed", value: dateTime(writtenAt, locale: locale, timeZone: timeZone)))
                }
            }
        } else {
            // An attempt's own facts only; archive-level settings never stand in for them.
            let attempt = attempts.first { $0.id == selectedAttemptID } ?? attempts.last
            if let engine = engineName(attempt?.engine) { facts.append(.init(title: "Engine", value: engine)) }
            if let model = attempt?.model { facts.append(.init(title: "Model", value: model)) }
            if let effort = attempt?.effort { facts.append(.init(title: "Recognition preset", value: effort)) }
            // Only a completed retry proves the recording was transcribed again.
            if let index = attempts.lastIndex(where: { $0.status == .completed }), index > 0,
               let at = attempts[index].startedAt {
                facts.append(.init(title: "Last transcribed", value: dateTime(at, locale: locale, timeZone: timeZone)))
            }
        }
        return facts
    }

    /// Display name for a recorded backend id (`parakeet-resident`, `whisper-server+outro`, `whisper.cpp`,
    /// `wispr-flow`). Unrecognised ids return nil rather than surfacing an internal name.
    static func engineName(_ backend: String?) -> String? {
        guard let id = backend?.lowercased(), !id.isEmpty else { return nil }
        if id.contains("parakeet") { return "Parakeet" }
        if id.contains("wispr") { return "Wispr Flow" }
        if id.contains("whisper") { return "Whisper" }
        return nil
    }

    static func processingLabel(_ milliseconds: Int) -> String {
        String(format: "processed in %.1f s", Double(milliseconds) / 1000)
    }

    static func clockTime(_ date: Date, locale: Locale, timeZone: TimeZone) -> String {
        let formatter = DateFormatter(); formatter.locale = locale; formatter.timeZone = timeZone
        formatter.dateStyle = .none; formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    static func dateTime(_ date: Date, locale: Locale, timeZone: TimeZone) -> String {
        let formatter = DateFormatter(); formatter.locale = locale; formatter.timeZone = timeZone
        formatter.dateStyle = .medium; formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}
