import SwiftUI

/// Read-only recording facts plus a compact Log of real attempts (archive take, this process's retry
/// requests, or the attempt reader's rows). It offers no retry, playback or paste action; the only
/// actions are copying the Recording ID and copying the Log with its provenance.
public struct SettingsHistoryDiagnosticsPanel: View {
    public let snapshot: SettingsHistoryDiagnostics?
    public let runs: [SettingsHistoryRunLog.Run]
    public let omittedCount: Int
    public let attemptHistory: SettingsHistoryAttemptHistory?
    public let recordingID: String?
    public let recordingEntry: SettingsHistoryEntry?
    private let expansionOverride: Bool?
    public let selectedAttemptID: String?
    public let shownAttemptID: String?
    private let onSelectAttempt: ((String) -> Void)?
    @State private var disclosure: SettingsHistoryDiagnosticsDisclosure

    public init(snapshot: SettingsHistoryDiagnostics?, runs: [SettingsHistoryRunLog.Run], omittedCount: Int = 0, initialDetailsExpanded: Bool = false, initiallyExpanded: Bool? = nil, attemptHistory: SettingsHistoryAttemptHistory? = nil, selectedAttemptID: String? = nil, shownAttemptID: String? = nil, onSelectAttempt: ((String) -> Void)? = nil, recordingID: String? = nil, recordingEntry: SettingsHistoryEntry? = nil) {
        self.snapshot = snapshot
        self.runs = runs
        self.omittedCount = omittedCount
        self.attemptHistory = attemptHistory
        self.recordingID = recordingID
        self.recordingEntry = recordingEntry
        self.expansionOverride = initiallyExpanded
        self.selectedAttemptID = selectedAttemptID
        self.shownAttemptID = shownAttemptID
        self.onSelectAttempt = onSelectAttempt
        let copy = SettingsHistoryDiagnosticsCopy(snapshot: snapshot, runs: runs, omittedCount: omittedCount, attemptHistory: attemptHistory,
                                                 recordingID: recordingID, recordingEntry: recordingEntry)
        var initial = SettingsHistoryDiagnosticsDisclosure(selection: snapshot?.selection ?? attemptHistory?.recordingPath, defaultExpanded: copy.defaultExpanded)
        initial.expanded = initiallyExpanded ?? (initialDetailsExpanded || copy.defaultExpanded)
        _disclosure = State(initialValue: initial)
    }

    public var body: some View {
        let copy = SettingsHistoryDiagnosticsCopy(snapshot: snapshot, runs: runs, omittedCount: omittedCount,
                                                 attemptHistory: attemptHistory, recordingID: recordingID, recordingEntry: recordingEntry)
        VStack(alignment: .leading, spacing: 10) {
            header
            if disclosure.expanded {
                VStack(alignment: .leading, spacing: 12) {
                    recordingFacts
                    if !copy.summary.isEmpty { Text(copy.summary).font(.callout).fixedSize(horizontal: false, vertical: true) }
                    if !copy.logLines.isEmpty { log(copy) }
                    if let notice = copy.notice {
                        Text(notice).font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }.padding(.top, 4)
                .transition(.opacity)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityIdentifier("history-recording-details")
        .onChange(of: expansionOverride) { _, value in if let value { disclosure.expanded = value } }
        .onChange(of: snapshot?.selection ?? attemptHistory?.recordingPath) { _, key in disclosure.select(key, defaultExpanded: copy.defaultExpanded) }
        .onChange(of: copy.defaultExpanded) { _, value in disclosure.select(snapshot?.selection ?? attemptHistory?.recordingPath, defaultExpanded: value) }
    }

    /// The Recording ID lives in the header, beside (never inside) the disclosure button, so copying it
    /// does not toggle the section. It truncates in the middle before the title ever does.
    private var header: some View {
        HStack(alignment: .center, spacing: 6) {
            SettingsDisclosureHeader("Recording details", isExpanded: $disclosure.expanded,
                                     animation: .timingCurve(0.23, 1, 0.32, 1, duration: 0.23)) {
                Label("Recording details", systemImage: "list.bullet.rectangle").font(.callout.weight(.semibold))
            }
            if let recordingID, !recordingID.isEmpty {
                Text(recordingID).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                    .textSelection(.enabled)
                    .help(recordingID)
                    .accessibilityLabel("Recording ID")
                    .accessibilityValue(recordingID)
                SettingsHistoryCopyIconButton(text: recordingID, label: "recording ID")
            }
        }
    }

    static func legacyRecognitionFacts(_ entry: SettingsHistoryEntry?, hasAttempts: Bool) -> [(String, String)] {
        guard !hasAttempts, let entry else { return [] }
        var facts: [(String, String)] = []
        if let model = entry.modelLabel, !model.isEmpty { facts.append(("Model", model)) }
        if let preset = entry.performanceEffort?.displayName { facts.append(("Recognition preset", preset)) }
        return facts
    }

    @ViewBuilder private var recordingFacts: some View {
        let facts = SettingsHistoryDiagnosticsCopy.facts(snapshot: snapshot, entry: recordingEntry,
                                                        attemptHistory: attemptHistory, selectedAttemptID: selectedAttemptID)
        let reserved = Self.reservedFactTitles(facts: facts, snapshotLoaded: snapshot != nil,
                                               hasRecording: recordingEntry != nil || !(recordingID ?? "").isEmpty)
        if !facts.isEmpty || !reserved.isEmpty {
            VStack(alignment: .leading, spacing: 7) {
                ForEach(facts, id: \.title) { fact in
                    factRow(fact.title, value: fact.value)
                        .accessibilityElement(children: .combine)
                }
                // Holds the rows the archive read fills in, so the facts do not reflow when it lands.
                // Invisible and silent: no label or value is shown before the archive says what it is.
                ForEach(reserved, id: \.self) { title in
                    factRow(title, value: " ").hidden().accessibilityHidden(true)
                }
            }
        }
    }

    private func factRow(_ title: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title).font(.caption).foregroundStyle(.secondary).frame(width: 110, alignment: .leading)
            Text(value).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Language setting and (without reader attempts) Engine come only from the archive read. Until it
    /// lands, their space is held invisibly; once it lands nothing is reserved, so a recording whose
    /// archive lacks them never shows a placeholder or a guessed value.
    static func reservedFactTitles(facts: [SettingsHistoryFact], snapshotLoaded: Bool, hasRecording: Bool) -> [String] {
        guard !snapshotLoaded, hasRecording else { return [] }
        let shown = Set(facts.map(\.title))
        return ["Language setting", "Engine"].filter { !shown.contains($0) }
    }

    /// One quiet row per real event: time, outcome, and that row's own processing time.
    private func log(_ copy: SettingsHistoryDiagnosticsCopy) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text("Log").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
                SettingsHistoryCopyIconButton(text: copy.logCopyText, label: "log")
            }
            ForEach(copy.logLines) { line in
                if let attemptID = line.attemptID {
                    Button { onSelectAttempt?(attemptID) } label: {
                        logRow(line)
                            .background(selectedAttemptID == attemptID ? Color.accentColor.opacity(0.1) : Color.clear,
                                        in: RoundedRectangle(cornerRadius: 6))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(onSelectAttempt == nil)
                    .accessibilityIdentifier("history-attempt-\(attemptID)")
                    .accessibilityLabel(line.accessibilityText)
                    .accessibilityValue(isShown(line) ? "Shown" : (selectedAttemptID == attemptID ? "Selected" : ""))
                    .accessibilityAddTraits(selectedAttemptID == attemptID ? .isSelected : [])
                } else {
                    logRow(line)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(line.accessibilityText)
                        .accessibilityIdentifier("history-log-\(line.id)")
                }
            }
        }
    }

    /// One line per attempt whenever the whole line fits. In a narrow pane the same text folds into two
    /// lines (title and time, then outcome and processing) instead of pushing fixed-width times past the
    /// edge; the title truncates before anything overflows. Both forms show exactly the same facts.
    private func logRow(_ line: SettingsHistoryLogLine) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                logSymbol(line)
                Text(line.title).font(.callout).fixedSize()
                logTime(line)
                logOutcome(line).lineLimit(1).fixedSize()
                Spacer(minLength: 8)
                logProcessing(line)
                logShown(line)
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                logSymbol(line)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(line.title).font(.callout).lineLimit(1).truncationMode(.tail)
                        logTime(line)
                        Spacer(minLength: 8)
                        logShown(line)
                    }
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        logOutcome(line).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                        logProcessing(line)
                    }
                }
            }
        }
        .padding(.horizontal, 6).padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func logSymbol(_ line: SettingsHistoryLogLine) -> some View {
        Image(systemName: line.symbol).font(.caption).frame(width: 14)
            .foregroundStyle(line.isProblem ? Color.orange : Color.secondary)
            .accessibilityHidden(true)
    }

    @ViewBuilder private func logTime(_ line: SettingsHistoryLogLine) -> some View {
        if let time = line.time { Text(time).font(.caption.monospacedDigit()).foregroundStyle(.secondary).fixedSize() }
    }

    private func logOutcome(_ line: SettingsHistoryLogLine) -> some View {
        Text(line.outcome).font(.caption).foregroundStyle(.secondary)
    }

    @ViewBuilder private func logProcessing(_ line: SettingsHistoryLogLine) -> some View {
        if let processing = line.processing {
            Text(processing).font(.caption.monospacedDigit()).foregroundStyle(.secondary).fixedSize()
        }
    }

    @ViewBuilder private func logShown(_ line: SettingsHistoryLogLine) -> some View {
        if isShown(line) { Text("Shown").font(.caption).foregroundStyle(.secondary).fixedSize() }
    }

    private func isShown(_ line: SettingsHistoryLogLine) -> Bool {
        guard let id = line.attemptID, shownAttemptID == id else { return false }
        return attemptHistory?.attempts.first { $0.id == id }?.hasSavedText == true
    }
}

/// Icon-only copy: the symbol is the affordance; the tooltip and VoiceOver carry the words.
/// The checkmark swap is state feedback, not motion, and reverts after two seconds.
struct SettingsHistoryCopyIconButton: View {
    let text: String?
    let label: String
    @State private var copied = false

    var body: some View {
        if let payload = SettingsCopyPayload.nonempty(text) {
            Button {
                copied = SettingsCopyPayload.write(payload)
                // Only a successful write is confirmed; the label swap alone is silent for VoiceOver.
                if copied { AccessibilityNotification.Announcement("Copied \(label)").post() }
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.caption)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help(copied ? "Copied" : "Copy \(label)")
            .accessibilityLabel(copied ? "Copied \(label)" : "Copy \(label)")
            .onChange(of: text) { _, _ in copied = false }
            .task(id: copied) {
                guard copied else { return }
                try? await Task.sleep(for: .seconds(2))
                if !Task.isCancelled { copied = false }
            }
        }
    }
}

/// Identity is reset by the parent `.id(entry.id)`. A cancelled/stale read never crosses selections.
struct SettingsHistoryDiagnosticsView: View {
    let entry: SettingsHistoryEntry
    let load: @Sendable (URL) async -> SettingsHistoryDiagnostics
    let runs: [SettingsHistoryRunLog.Run]
    let omittedCount: Int
    var loadAttempts: SettingsHistoryAttemptLogReader = { _ in nil }
    @State private var attemptHistory: SettingsHistoryAttemptHistory?
    @State private var snapshot: SettingsHistoryDiagnostics?
    @State private var revision = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SettingsHistoryDiagnosticsPanel(snapshot: snapshot, runs: runs, omittedCount: omittedCount, attemptHistory: attemptHistory, recordingID: entry.recordingID)
        }
        .task(id: revision) {
            async let diagnostics = load(entry.audioPath)
            async let history = loadAttempts(entry.audioPath)
            let (result, attempts) = await (diagnostics, history)
            guard !Task.isCancelled else { return }
            snapshot = result
            attemptHistory = attempts?.matching(entry.audioPath)
        }
        .onReceive(NotificationCenter.default.publisher(for: .voiceBarHistoryArchiveDidChange)) { _ in revision &+= 1 }
    }
}

/// Pure state seam for selection changes; refreshing the same entry preserves the user's choice.
struct SettingsHistoryDiagnosticsDisclosure: Equatable {
    private(set) var selection: String?
    var expanded: Bool
    private var lastDefault: Bool
    init(selection: String?, defaultExpanded: Bool = false) {
        self.selection = selection; self.expanded = defaultExpanded; self.lastDefault = defaultExpanded
    }
    mutating func select(_ key: String?, defaultExpanded: Bool = false) {
        guard selection != key || lastDefault != defaultExpanded else { return }
        selection = key
        expanded = defaultExpanded
        lastDefault = defaultExpanded
    }
}
