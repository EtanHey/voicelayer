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
    var executionLabel: String? {
        let values = [engine, model, effort.map { "Effort: \($0)" }].compactMap { $0 }
        return values.isEmpty ? nil : values.joined(separator: " · ")
    }
    var timingLabel: String? {
        let audio = audioDurationMs.flatMap(SettingsHistoryEntry.clockLabel).map { "\($0) audio" }
        let processing = processingDurationMs.map { String(format: "%.1f s processing", Double($0) / 1000) }
        let values = [audio, processing].compactMap { $0 }
        return values.isEmpty ? nil : values.joined(separator: " → ")
    }
    var hasMissingExecutionDetails: Bool { engine == nil || model == nil || audioDurationMs == nil || processingDurationMs == nil || startedAt == nil }
    func localTimestamp(locale: Locale = .current, timeZone: TimeZone = .current) -> String? {
        guard let startedAt else { return nil }
        let formatter = DateFormatter(); formatter.locale = locale; formatter.timeZone = timeZone
        formatter.dateStyle = .none; formatter.timeStyle = .short
        return formatter.string(from: startedAt)
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

/// Inject STATE's reader here when its log contract is ready. Nil means legacy data, not no attempts.
public typealias SettingsHistoryAttemptLogReader = @Sendable (URL) async -> SettingsHistoryAttemptHistory?

struct SettingsHistoryDiagnosticsCopy {
    static let olderDetails = "Older details weren't saved for this recording."
    let summary: String
    let latestUpdate: String?
    let attempts: [SettingsHistoryAttemptRecord]
    let olderNotice: String?
    let technicalDetails: String
    let shouldExpand: Bool
    var defaultExpanded: Bool { shouldExpand }
    var visibleSentences: [String] {
        ([summary] + [latestUpdate].compactMap { $0 } + [olderNotice].compactMap { $0 }).filter { !$0.isEmpty }
    }

    init(snapshot: SettingsHistoryDiagnostics?, runs: [SettingsHistoryRunLog.Run], omittedCount: Int,
         attemptHistory: SettingsHistoryAttemptHistory?, recordingID: String? = nil) {
        let recordingError = runs.first.map {
            $0.outcome == .rejected || $0.outcome == .failed || $0.recordingObservations.contains { $0.hasPrefix("Recording-linked error;") }
        } ?? false
        let partial = attemptHistory?.hasPartialResult == true || (attemptHistory == nil && snapshot?.archiveState == .partial)
        if partial { shouldExpand = true }
        else if let latest = attemptHistory?.attempts.last {
            shouldExpand = latest.status == .failed || latest.status == .timedOut
        } else { shouldExpand = recordingError || snapshot?.archiveState == .failed }
        attempts = attemptHistory?.attempts ?? []
        olderNotice = (snapshot != nil && attemptHistory?.isComplete != true) ||
            attempts.contains(where: { $0.hasMissingExecutionDetails }) ? Self.olderDetails : nil
        if partial {
            summary = "Partial text is saved."
        } else if attemptHistory?.isComplete == true {
            summary = "" // Durable status rows already explain each attempt.
        } else if let snapshot {
            switch snapshot.archiveState {
            case .failed where snapshot.savedTextState == .present:
                summary = "The last transcription failed. Saved text is still available."
            case .failed: summary = "No text was saved from the last transcription."
            case .cancelled: summary = "This recording was cancelled."
            default:
                switch snapshot.savedTextState {
                case .present: summary = ""
                case .empty: summary = "The saved text is empty."
                case .unavailable: summary = "Saved text is unavailable."
                }
            }
        } else { summary = "" }
        if attemptHistory?.isComplete == true {
            latestUpdate = nil // Complete durable history replaces the provisional request summary.
        } else if let latest = runs.first {
            if latest.outcome != .rejected,
               latest.recordingObservations.contains(where: { $0.hasPrefix("Recording-linked error;") }) {
                latestUpdate = "VoiceBar reported a problem with this recording."
            } else { switch latest.outcome {
            case .rejected: latestUpdate = "VoiceBar couldn't start this retry."
            case .failed: latestUpdate = "This retry failed."
            case .succeeded: latestUpdate = "New text was received."
            case .accepted: latestUpdate = "A retry was requested."
            case .requested, .unknown: latestUpdate = "A retry was requested."
            } }
        } else { latestUpdate = nil }
        var technical: [String] = []
        if let recordingID { technical.append("Recording ID: \(recordingID)") }
        if let snapshot {
            technical += ["Recording: \(snapshot.selection)", snapshot.summary, snapshot.savedResult]
            if let date = snapshot.capturedAt { technical.append("Capture time: \(date.formatted(date: .abbreviated, time: .standard))") }
            if let backend = snapshot.backend { technical.append("Archive backend: \(backend)") }
            if let model = snapshot.model { technical.append("Archive model: \(model)") }
            if let detail = snapshot.detail { technical.append(detail) }
            technical += snapshot.warnings
        }
        technical.append(attemptHistory == nil
            ? "No per-recording attempt log was supplied. Session requests below are provisional and clear when VoiceBar quits."
            : "Attempt rows come from the injected per-recording log reader; completeness is supplied by that reader.")
        for attempt in attempts {
            technical.append("Attempt \(attempt.id): \(String(describing: attempt.status))")
            if let detail = attempt.technicalDetail { technical.append(detail) }
        }
        technical.append("Session timestamps are observation times, not backend execution times; path-only events do not identify a request's terminal outcome.")
        for run in runs {
            technical += ["Request \(run.id): \(run.outcome.rawValue); \(run.acknowledgement.rawValue)",
                          "Requested \(run.startedAt); observed \(run.observedAt)"]
            if let detail = run.detail { technical.append(detail) }
            technical += run.recordingObservations
            if run.omittedObservationCount > 0 { technical.append("\(run.omittedObservationCount) older recording observations omitted (4-observation limit).") }
        }
        if omittedCount > 0 { technical.append("\(omittedCount) older session requests omitted (30-request limit).") }
        // Every input is already bounded/redacted independently; preserve their individual limit markers.
        technicalDetails = technical.map(SettingsHistoryDiagnosticPrivacy.text).joined(separator: "\n\n")
    }
}
