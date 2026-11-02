import SwiftUI

/// Read-only archive summary plus this app process's observed History requests.
/// It intentionally offers no retry, playback, paste or raw-log export action.
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
        let copy = SettingsHistoryDiagnosticsCopy(snapshot: snapshot, runs: runs, omittedCount: omittedCount, attemptHistory: attemptHistory, recordingID: recordingID)
        var initial = SettingsHistoryDiagnosticsDisclosure(selection: snapshot?.selection ?? attemptHistory?.recordingPath, defaultExpanded: copy.defaultExpanded)
        initial.expanded = initiallyExpanded ?? (initialDetailsExpanded || copy.defaultExpanded)
        initial.detailsExpanded = initialDetailsExpanded
        _disclosure = State(initialValue: initial)
    }

    public var body: some View {
        let copy = SettingsHistoryDiagnosticsCopy(snapshot: snapshot, runs: runs, omittedCount: omittedCount,
                                                 attemptHistory: attemptHistory, recordingID: recordingID)
        VStack(alignment: .leading, spacing: 10) {
            SettingsDisclosureHeader("Recording details", isExpanded: $disclosure.expanded,
                                     animation: .timingCurve(0.23, 1, 0.32, 1, duration: 0.23)) {
                Label("Recording details", systemImage: "list.bullet.rectangle").font(.callout.weight(.semibold))
            }
            if disclosure.expanded {
                VStack(alignment: .leading, spacing: 10) {
                    recordingFacts
                    if !copy.summary.isEmpty { Text(copy.summary).font(.callout).fixedSize(horizontal: false, vertical: true) }
                    if let update = copy.latestUpdate {
                        Text(update).font(.callout).fixedSize(horizontal: false, vertical: true)
                    }
                    if !copy.attempts.isEmpty {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(copy.attempts.enumerated()), id: \.element.id) { index, attempt in
                                Button { onSelectAttempt?(attempt.id) } label: {
                                    ViewThatFits(in: .horizontal) {
                                        HStack(spacing: 10) {
                                            attemptIdentity(attempt, index: index)
                                            executionDetails(attempt).fixedSize()
                                            Spacer(minLength: 4)
                                            shownBadge(attempt)
                                        }
                                        VStack(alignment: .leading, spacing: 5) {
                                            HStack(spacing: 8) {
                                                attemptIdentity(attempt, index: index)
                                                Spacer(minLength: 4)
                                                shownBadge(attempt)
                                            }
                                            executionDetails(attempt).padding(.leading, 22)
                                        }
                                    }
                                    .padding(.horizontal, 8).padding(.vertical, 7)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(selectedAttemptID == attempt.id ? Color.accentColor.opacity(0.1) : Color.clear,
                                                in: RoundedRectangle(cornerRadius: 6))
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .disabled(onSelectAttempt == nil)
                                .accessibilityIdentifier("history-attempt-\(attempt.id)")
                                .accessibilityLabel([SettingsHistoryAttemptRecord.title(at: index), attempt.statusTitle, attempt.localTimestamp(), attempt.failureReason, attempt.executionLabel, attempt.timingLabel].compactMap { $0 }.joined(separator: ", "))
                                .accessibilityValue(shownAttemptID == attempt.id && attempt.hasSavedText ? "Shown" : (selectedAttemptID == attempt.id ? "Selected" : ""))
                                .accessibilityAddTraits(selectedAttemptID == attempt.id ? .isSelected : [])
                            }
                        }
                    }
                    if let notice = copy.olderNotice ?? (snapshot?.languageSetting == nil || recordingEntry?.durationLabel == nil ? SettingsHistoryDiagnosticsCopy.olderDetails : nil) {
                        Text(notice).font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    SettingsDisclosureRow("Technical details", isExpanded: $disclosure.detailsExpanded, animation: .timingCurve(0.23, 1, 0.32, 1, duration: 0.23)) {
                        VStack(alignment: .leading, spacing: 8) {
                            ScrollView {
                                Text(copy.technicalDetails).font(.caption.monospaced()).textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .fixedSize(horizontal: false, vertical: true)
                            }.frame(maxHeight: 200)
                            SettingsCopyButton(text: copy.technicalDetails, label: "technical details")
                            if let entry = recordingEntry {
                                SettingsCopyButton(text: SettingsDiagnosticSummary.historyMetadata(entry), label: "recording metadata")
                            }
                        }.padding(.top, 6)
                    }.font(.caption)
                }.padding(.top, 8)
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

    static func legacyRecognitionFacts(_ entry: SettingsHistoryEntry?, hasAttempts: Bool) -> [(String, String)] {
        guard !hasAttempts, let entry else { return [] }
        var facts: [(String, String)] = []
        if let model = entry.modelLabel, !model.isEmpty { facts.append(("Model", model)) }
        if let preset = entry.performanceEffort?.displayName { facts.append(("Recognition preset", preset)) }
        return facts
    }

    @ViewBuilder private var recordingFacts: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let created = snapshot?.capturedAt ?? recordingEntry?.createdAt {
                fact("Created", created.formatted(.dateTime.day().month(.abbreviated).year().hour().minute()))
            }
            // These are stored input_device_name values, never the currently selected microphone.
            if let mic = snapshot?.inputDeviceName ?? recordingEntry?.inputDeviceLabel { fact("Microphone", mic) }
            if let duration = recordingEntry?.durationLabel { fact("Audio length", duration) }
            ForEach(Array(Self.legacyRecognitionFacts(recordingEntry, hasAttempts: !(attemptHistory?.attempts.isEmpty ?? true)).enumerated()), id: \.offset) { _, item in
                fact(item.0, item.1)
            }
            if let language = snapshot?.languageSetting { fact("Language setting", language) }
        }.padding(.bottom, 4)
    }
    private func fact(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title).font(.caption).foregroundStyle(.secondary).frame(width: 100, alignment: .leading)
            Text(value).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
    }
    private func attemptIdentity(_ attempt: SettingsHistoryAttemptRecord, index: Int) -> some View {
        HStack(spacing: 8) {
            Image(systemName: attempt.statusSymbol).frame(width: 14)
                .foregroundStyle(attempt.status == .failed || attempt.status == .timedOut ? Color.orange : Color.secondary)
            Text(SettingsHistoryAttemptRecord.title(at: index)).font(.callout.weight(.medium)).fixedSize()
            if let time = attempt.localTimestamp() { Text(time).font(.caption).foregroundStyle(.secondary).fixedSize() }
            Text(attempt.failureReason?.isEmpty == false ? attempt.failureReason! : attempt.statusTitle)
                .font(.caption).foregroundStyle(.secondary).lineLimit(2)
        }
    }
    private func executionDetails(_ attempt: SettingsHistoryAttemptRecord) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                if let execution = attempt.executionLabel { Text(execution).fixedSize() }
                if let timing = attempt.timingLabel { Text(timing).fixedSize() }
            }
            VStack(alignment: .leading, spacing: 2) {
                if let execution = attempt.executionLabel { Text(execution) }
                if let timing = attempt.timingLabel { Text(timing) }
            }
        }.font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
    @ViewBuilder private func shownBadge(_ attempt: SettingsHistoryAttemptRecord) -> some View {
        if shownAttemptID == attempt.id, attempt.hasSavedText {
            Text("Shown").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Color.secondary.opacity(0.12), in: Capsule())
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
    var detailsExpanded = false
    private var lastDefault: Bool
    init(selection: String?, defaultExpanded: Bool = false) {
        self.selection = selection; self.expanded = defaultExpanded; self.lastDefault = defaultExpanded
    }
    mutating func select(_ key: String?, defaultExpanded: Bool = false) {
        guard selection != key || lastDefault != defaultExpanded else { return }
        selection = key
        expanded = defaultExpanded
        detailsExpanded = false
        lastDefault = defaultExpanded
    }
}
