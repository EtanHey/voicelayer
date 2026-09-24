import SwiftUI

public struct ModelsSettingsView: View {
    public let state: ModelsSettingsState
    @Binding private var effort: VoiceBarPerformanceEffort
    private let notice: String?
    private let residencyNotice: String?
    private let lastDictationLabel: String?
    private let degradation: STTPolishDegradation?
    private let onDismissDegradation: () -> Void
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
        onDismissDegradation: @escaping () -> Void = {}
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
                    processingRow(
                        "Polish: fixes punctuation and casing locally",
                        status: controls.modelPolish.effective.displayName,
                        source: controls.modelPolish.source
                    )
                    .accessibilityIdentifier("models-polish-mode")
                    processingRow(
                        "Closing-phrase filter: removes an invented ‘Thank you.’ at the end",
                        status: controls.outroGate.effective ? "On" : "Off",
                        source: controls.outroGate.source
                    )
                    .accessibilityIdentifier("models-outro-gate")
                    processingRow("Smart chunks: splits long recordings at pauses",
                                  status: controls.smartChunks.effective ? "On" : "Off",
                                  source: controls.smartChunks.source)
                        .accessibilityIdentifier("models-smart-chunks")
                    processingRow("Smart boundaries: turns false full stops into commas using your pauses",
                                  status: controls.smartBoundaries.effective ? "On" : "Off",
                                  source: controls.smartBoundaries.source)
                        .accessibilityIdentifier("models-smart-boundaries")
                    Text(
                        "Set in VoiceLayer's configuration; shown here for reference."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
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

    private func processingRow(_ description: String, status: String, source: PolishSettingSource) -> some View {
        LabeledContent(description) {
            Text(status)
                .help(source == .default ? "Daemon default" : "Environment setting")
        }
    }
}
