import SwiftUI

public struct ModelsSettingsView: View {
    public let state: ModelsSettingsState
    @Binding private var effort: VoiceBarPerformanceEffort
    private let notice: String?
    private let residencyNotice: String?
    private let lastDictationLabel: String?
    private let degradation: STTPolishDegradation?
    private let onDismissDegradation: () -> Void
    private let processingPending: [ProcessingKey: Bool]
    private let processingNotice: String?
    private let onToggleProcessing: ((ProcessingKey, Bool) -> Void)?
    private let onSelectEffort: (VoiceBarPerformanceEffort) -> Void
    private let onSelectResidency: ((VoiceModelResidency) -> Void)?

    public init(
        state: ModelsSettingsState,
        effort: Binding<VoiceBarPerformanceEffort>,
        notice: String? = nil,
        onSelectEffort: @escaping (VoiceBarPerformanceEffort) -> Void,
        residencyNotice: String? = nil,
        onSelectResidency: ((VoiceModelResidency) -> Void)? = nil,
        lastDictationLabel: String? = nil,
        degradation: STTPolishDegradation? = nil,
        onDismissDegradation: @escaping () -> Void = {},
        processingPending: [ProcessingKey: Bool] = [:],
        processingNotice: String? = nil,
        onToggleProcessing: ((ProcessingKey, Bool) -> Void)? = nil
    ) {
        self.state = state
        _effort = effort
        self.notice = notice
        self.onSelectEffort = onSelectEffort
        self.residencyNotice = residencyNotice
        self.onSelectResidency = onSelectResidency
        self.lastDictationLabel = lastDictationLabel
        self.degradation = degradation
        self.onDismissDegradation = onDismissDegradation
        self.processingPending = processingPending
        self.processingNotice = processingNotice
        self.onToggleProcessing = onToggleProcessing
    }

    public var body: some View {
        Form {
            if let degradation {
                Section {
                    HStack {
                        Label(degradation.hint, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Spacer()
                        Button("Dismiss", action: onDismissDegradation)
                            .accessibilityLabel("Dismiss STT polish warning")
                    }
                }
            }

            Section {
                LabeledContent("Speech model") {
                    Text(modelSummary)
                        .accessibilityIdentifier("models-configured-model")
                }
                LabeledContent("In memory") {
                    HStack(spacing: 10) {
                        Text(residencyLabel)
                            .accessibilityIdentifier("models-residency")
                        if state.availability == .available,
                           let onSelectResidency,
                           state.residency != .unknown {
                            Button(state.residency == .loaded ? "Unload" : "Load") {
                                onSelectResidency(state.residency == .loaded ? .notLoaded : .loaded)
                            }
                            .disabled(state.isBusy)
                            .accessibilityIdentifier("models-residency-control")
                        }
                    }
                }
                LabeledContent("Last dictation used") {
                    Text(lastDictationLabel ?? "Unavailable")
                        .accessibilityIdentifier("models-last-dictation")
                }
                if let residencyNotice {
                    Text(residencyNotice).font(.caption).foregroundStyle(.orange)
                }
            }

            Section("Transcription effort") {
                Picker("Transcription effort", selection: Binding(
                    get: { effort },
                    set: { selected in
                        effort = selected
                        onSelectEffort(selected)
                    }
                )) {
                    ForEach(VoiceBarPerformanceEffort.allCases) { option in
                        Text(option.displayName).tag(option)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("models-effort-picker")
                .disabled(Self.effortDisabledReason(for: state) != nil)
                if let reason = Self.effortDisabledReason(for: state) {
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("models-busy-reason")
                }
                Text(Self.effortExplanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let note = Self.effortStatusNote(for: state) {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .accessibilityIdentifier("models-effort-status")
                }
                if let notice {
                    Text(notice).font(.caption).foregroundStyle(.orange)
                }
            }

            Section("Processing") {
                if let controls = state.polishControls, state.availability == .available {
                    ForEach(Self.processingRows(for: controls), id: \.key) { row in
                        processingToggle(row)
                    }
                    Text("Applies to your next dictation.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let processingNotice {
                        Text(processingNotice).font(.caption).foregroundStyle(.orange)
                    }
                } else if let placeholder = Self.processingPlaceholder(for: state) {
                    Text(placeholder)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("models-polish-unavailable")
                }
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("models-settings-form")
    }

    private var modelSummary: String {
        guard state.availability == .available else { return availabilityLabel }
        let name = VoiceModelDisplayName.normalize(state.configuredModelName) ?? "Not found"
        guard let bytes = state.configuredModelSizeBytes, bytes > 0 else { return name }
        return "\(name) · \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))"
    }

    private var residencyLabel: String {
        guard state.availability == .available else { return availabilityLabel }
        switch state.residency {
        case .loaded: return "Loaded"
        case .notLoaded: return "Not loaded"
        case .unknown: return "Unavailable"
        }
    }

    private var availabilityLabel: String {
        state.availability == .loading ? "Checking…" : "Not connected"
    }

    /// Why the effort picker is disabled, shown directly under it (spec §5). nil means it is enabled.
    /// The daemon owns effort, so the picker stays disabled until VoiceLayer reports it is available.
    // AIDEV-NOTE: numbers from r4-e1/findings.md (M4 Max, 3 clips): Fast→Accurate
    // +15–35 % decode time, identical words on 10 s/33 s clips, 2–4 of 158 on 100 s
    // (inside Balanced's own run-to-run noise). Final wording/placement waits on
    // Etan (bundled plan, answer A).
    static let effortExplanation =
        "Fast is the quickest. Balanced and Accurate use beam search: about 15–35 % slower, "
            + "with no measurable word difference in our tests. Changing it reloads the model "
            + "(about 2 s). History shows which one each transcript used."

    /// Truth when the running server's effort is not the setting (a server VoiceLayer
    /// did not launch keeps its own flags until it restarts).
    static func effortStatusNote(for state: ModelsSettingsState) -> String? {
        guard state.availability == .available,
              state.residency == .loaded,
              !state.isBusy,
              let active = state.activeEffort,
              let configured = state.configuredEffort,
              active != configured
        else { return nil }
        return "Running \(active.displayName) until the model server restarts."
    }

    static func effortDisabledReason(for state: ModelsSettingsState) -> String? {
        switch state.availability {
        case .unavailable:
            "Available when VoiceLayer is running"
        case .loading:
            state.busyReason ?? "Checking VoiceLayer…"
        case .available:
            state.isBusy ? state.busyReason ?? "Voice session in progress" : nil
        }
    }

    /// What the Processing section says instead of its rows (spec §8: a named reason, never a bare
    /// "Status unavailable"). nil means the rows are shown.
    static func processingPlaceholder(for state: ModelsSettingsState) -> String? {
        switch state.availability {
        case .loading:
            "Checking…"
        case .unavailable:
            "VoiceLayer isn't connected. These appear when it reconnects."
        case .available:
            state.polishControls == nil ? "Not reported by this VoiceLayer version" : nil
        }
    }

    private func processingToggle(_ row: ProcessingRow) -> some View {
        let busyReason = Self.effortDisabledReason(for: state)
        return VStack(alignment: .leading, spacing: 2) {
            Toggle(isOn: Binding(
                get: { processingPending[row.key] ?? row.isOn },
                set: { onToggleProcessing?(row.key, $0) }
            )) {
                HStack(spacing: 6) {
                    Text(row.key.title)
                    if row.experimental {
                        Text("Experimental")
                            .font(.caption2)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.quaternary, in: Capsule())
                    }
                }
            }
            .disabled(row.lockedReason != nil || busyReason != nil || onToggleProcessing == nil
                || processingPending[row.key] != nil)
            .accessibilityIdentifier("models-processing-\(row.key.rawValue)")
            Text(row.lockedReason ?? row.line)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// One Processing toggle: what it does, and why it cannot be changed here, if it cannot.
    struct ProcessingRow: Equatable {
        let key: ProcessingKey
        let line: String
        let experimental: Bool
        let isOn: Bool
        let lockedReason: String?
    }

    static func processingRows(for controls: PolishControlsState) -> [ProcessingRow] {
        func locked(_ key: ProcessingKey, _ setting: PolishSetting<some Any>) -> String? {
            setting.source == .environment ? "Set by \(key.environmentVariable)" : nil
        }
        let polishLock = controls.modelPolish.effective == .shadow
            ? "Preview only (set by \(ProcessingKey.modelPolish.environmentVariable))"
            : locked(.modelPolish, controls.modelPolish)
        return [
            ProcessingRow(
                key: .modelPolish,
                line: "Fixes punctuation and capitals with a small local model.",
                experimental: false,
                isOn: controls.modelPolish.effective == .on,
                lockedReason: polishLock
            ),
            ProcessingRow(
                key: .outroGate,
                line: "Removes a ‘Thank you.’ the model invented over silence.",
                experimental: false,
                isOn: controls.outroGate.effective,
                lockedReason: locked(.outroGate, controls.outroGate)
            ),
            ProcessingRow(
                key: .smartChunks,
                line: "Long recordings (90 s+): cut at your pauses instead of every 30 s.",
                experimental: true,
                isOn: controls.smartChunks.effective,
                lockedReason: locked(.smartChunks, controls.smartChunks)
            ),
            ProcessingRow(
                key: .smartBoundaries,
                line: "Turns a full stop into a comma when you didn't actually pause.",
                experimental: true,
                isOn: controls.smartBoundaries.effective,
                lockedReason: locked(.smartBoundaries, controls.smartBoundaries)
            ),
        ]
    }
}
