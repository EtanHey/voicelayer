import SwiftUI

public struct ModelsSettingsView: View {
    public let state: ModelsSettingsState
    private let notice: String?
    private let residencyNotice: String?
    private let degradation: STTPolishDegradation?
    private let onDismissDegradation: () -> Void
    private let processingPending: [ProcessingKey: Bool]
    private let processingNotice: String?
    private let onToggleProcessing: ((ProcessingKey, Bool) -> Void)?
    private let onSelectResidency: ((VoiceModelResidency) -> Void)?

    public init(
        state: ModelsSettingsState,
        notice: String? = nil,
        residencyNotice: String? = nil,
        onSelectResidency: ((VoiceModelResidency) -> Void)? = nil,
        degradation: STTPolishDegradation? = nil,
        onDismissDegradation: @escaping () -> Void = {},
        processingPending: [ProcessingKey: Bool] = [:],
        processingNotice: String? = nil,
        onToggleProcessing: ((ProcessingKey, Bool) -> Void)? = nil
    ) {
        self.state = state
        self.notice = notice
        self.residencyNotice = residencyNotice
        self.onSelectResidency = onSelectResidency
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
                LabeledContent("Local recognizer") {
                    HStack(spacing: 10) {
                        VStack(alignment: .trailing, spacing: 3) {
                            Text(modelSummary)
                                .fixedSize(horizontal: false, vertical: true)
                                .multilineTextAlignment(.trailing)
                                .accessibilityIdentifier("models-recognizer")
                            if state.availability == .available {
                                Text(residencyLabel)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .accessibilityIdentifier("models-residency")
                            }
                        }
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
                if state.availability == .available, let reason = Self.effortDisabledReason(for: state) {
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("models-busy-reason")
                }
                if state.availability == .available {
                    DisclosureGroup("Recognizer details") {
                        LabeledContent("Configured model", value: VoiceModelDisplayName.normalize(state.configuredModelName) ?? "Unknown")
                        LabeledContent("Active model", value: VoiceModelDisplayName.normalize(state.activeModelName) ?? "Unknown")
                        LabeledContent("Configured effort", value: state.configuredEffort?.displayName ?? "Unknown")
                        LabeledContent("Active effort", value: state.activeEffort?.displayName ?? "Unknown")
                        if let note = Self.effortStatusNote(for: state) {
                            Text(note).font(.caption).foregroundStyle(.orange)
                        }
                        if let notice {
                            Text(notice).font(.caption).foregroundStyle(.orange)
                        }
                    }
                }
                if let residencyNotice {
                    Text(residencyNotice).font(.caption).foregroundStyle(.orange)
                }
            }

            Section("Processing") {
                if let controls = state.polishControls, state.availability == .available {
                    ForEach(Self.processingRows(for: controls), id: \.key) { row in
                        processingToggle(row)
                    }
                    if let busyReason = Self.processingBusyReason(for: state) {
                        Text(busyReason)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("models-processing-busy-reason")
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
        switch state.availability {
        case .loading: "Checking…"
        case .unreadable: "Status unreadable"
        case .disconnected, .available: "Not connected"
        }
    }

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
        case .disconnected:
            "Available when VoiceLayer is running"
        case .unreadable:
            "VoiceLayer is connected, but its status couldn't be read"
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
        case .disconnected:
            "VoiceLayer isn't connected. These appear when it reconnects."
        case .unreadable:
            "VoiceLayer is connected, but its status couldn't be read. These appear when it answers."
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
            ForEach(row.captionLines, id: \.self) { caption in
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// One Processing toggle: what it does, and why it cannot be changed here, if it cannot.
    struct ProcessingRow: Equatable {
        let key: ProcessingKey
        let line: String
        let experimental: Bool
        let isOn: Bool
        let lockedReason: String?

        /// C22: the explanation always shows; a lock adds its reason below instead of replacing it.
        var captionLines: [String] {
            [line] + (lockedReason.map { [$0] } ?? [])
        }
    }

    /// Busy always shows a reason beside the Processing controls. nil when the
    /// section already shows its own placeholder (status unavailable or still loading).
    static func processingBusyReason(for state: ModelsSettingsState) -> String? {
        state.availability == .available ? effortDisabledReason(for: state) : nil
    }

    /// D194-r1: smart chunks exist only on the resident Whisper server path (src/stt.ts);
    /// whisper-cli and Wispr Flow return no segments, and a server request that falls back to the CLI skips them.
    static let whisperServerOnly = "Whisper server only: the whisper-cli and Wispr Flow fallbacks skip it."

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
                line: "Recordings of 90 s or more split at your pauses instead of every 30 s; shorter ones are "
                    + "never split. " + Self.whisperServerOnly,
                experimental: true,
                isOn: controls.smartChunks.effective,
                lockedReason: locked(.smartChunks, controls.smartChunks)
            ),
        ]
    }
}
