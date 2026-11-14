import SwiftUI

/// A pop-up choice the app owns but Settings only shows (Transcription › Language).
///
/// AIDEV-NOTE: the recognizer language is not reported to Settings yet; a nil input hides the row rather than
/// showing a picker that changes nothing.
public struct SettingsChoiceInput {
    public let options: [String]
    public let selected: () -> String
    public let select: (String) -> Void

    public init(options: [String], selected: @escaping () -> String, select: @escaping (String) -> Void) {
        self.options = options; self.selected = selected; self.select = select
    }
}

/// K-ui: which engine wrote the last dictation, and when.
///
/// AIDEV-NOTE: the last-dictation entry Settings receives carries no backend chain; the app must supply the newest
/// recording's writer (RecognizerProvenance over its archived backend). Until it does, no note shows.
public struct SettingsLastDictationNote: Equatable {
    public let at: Date
    public let engine: RecognizerProvenance.Engine

    public init(at: Date, engine: RecognizerProvenance.Engine) { self.at = at; self.engine = engine }

    public func text(calendar: Calendar = .current) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = calendar.locale ?? .current
        formatter.setLocalizedDateFormatFromTemplate("jmm")
        return "Your last dictation, at \(formatter.string(from: at)), was transcribed by \(engine.name)."
    }
}

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
    private let recognizerState: RecognizerPickerState
    private let onManageRecognizer: ((RecognizerPickerEngine, RecognizerManagementAction) -> Void)?
    private let onSelectRecognizer: ((RecognizerPickerEngine) -> Void)?
    private let onSetUnloadWhenIdle: ((Bool) -> Void)?
    private let language: SettingsChoiceInput?
    private let lastDictationNote: SettingsLastDictationNote?
    @State private var detailsExpanded = false

    public init(
        state: ModelsSettingsState,
        notice: String? = nil,
        residencyNotice: String? = nil,
        onSelectResidency: ((VoiceModelResidency) -> Void)? = nil,
        degradation: STTPolishDegradation? = nil,
        onDismissDegradation: @escaping () -> Void = {},
        processingPending: [ProcessingKey: Bool] = [:],
        processingNotice: String? = nil,
        onToggleProcessing: ((ProcessingKey, Bool) -> Void)? = nil,
        recognizerState: RecognizerPickerState = .unavailable,
        onSelectRecognizer: ((RecognizerPickerEngine) -> Void)? = nil,
        onManageRecognizer: ((RecognizerPickerEngine, RecognizerManagementAction) -> Void)? = nil,
        onSetUnloadWhenIdle: ((Bool) -> Void)? = nil,
        language: SettingsChoiceInput? = nil,
        lastDictationNote: SettingsLastDictationNote? = nil
    ) {
        self.language = language
        self.lastDictationNote = lastDictationNote
        self.onSetUnloadWhenIdle = onSetUnloadWhenIdle
        self.onManageRecognizer = onManageRecognizer
        self.recognizerState = recognizerState
        self.onSelectRecognizer = onSelectRecognizer
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

            Section("Recognizer") {
                RecognizerPickerView(state: recognizerState, onSelect: onSelectRecognizer, onManage: onManageRecognizer,
                    suppressDisabledExplanation: state.availability == .available && state.isBusy && recognizerState.selected != nil)
                if let row = Self.unloadWhenIdleRow(for: recognizerState, canChange: onSetUnloadWhenIdle != nil) {
                    unloadWhenIdleToggle(row)
                }
                if let lastDictationNote {
                    Label(lastDictationNote.text(), systemImage: "info.circle")
                        .font(SettingsRowLabel.descriptionFont).foregroundStyle(SettingsPanePalette.helper)
                        .accessibilityIdentifier("recognizer-last-dictation")
                }
                // One shared reason above the controls it disables. The picker keeps
                // command/fallback notices, but omits its duplicate disabled explanation.
                if state.availability == .available, let reason = Self.effortDisabledReason(for: state) {
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("models-busy-reason")
                }
            }

            if let language {
                Section("Language") {
                    SettingsRow(title: "Language", description: "Auto detects English and Hebrew per recording.") {
                        Picker("Language", selection: Binding(get: language.selected, set: language.select)) {
                            ForEach(language.options, id: \.self) { Text($0).tag($0) }
                        }
                        .labelsHidden().fixedSize()
                    }
                }
            }

            Section("Processing") {
                if let controls = state.polishControls, state.availability == .available {
                    ForEach(Self.processingRows(for: controls, recognizer: recognizerState), id: \.key) { row in
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

            SettingsDisclosureRow("Recognizer details", isExpanded: $detailsExpanded) {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Self.detailFacts(state: state, recognizer: recognizerState), id: \.label) { row in
                        LabeledContent(row.label) { Text(row.value).textSelection(.enabled) }
                    }
                    recognizerNotes
                }
                .padding(.top, 6)
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("models-settings-form")
    }

    @ViewBuilder private var recognizerNotes: some View {
        if let note = Self.effortStatusNote(for: state) {
            Text(note).font(.caption).foregroundStyle(.orange)
        }
        if let notice {
            Text(notice).font(.caption).foregroundStyle(.orange)
        }
    }

    struct RecognizerDetailRow: Equatable {
        let label: String
        let value: String
    }

    /// Reported 2026-10-19 (SETUI1): merge matching configured and active model facts into one row.
    /// Keep both rows when the facts differ or the model is not loaded.
    static func recognizerDetailRows(for state: ModelsSettingsState) -> [RecognizerDetailRow] {
        func rows(_ noun: String, configured: String?, active: String?) -> [RecognizerDetailRow] {
            if state.residency == .loaded, let configured, configured == active {
                return [RecognizerDetailRow(label: noun, value: configured)]
            }
            return [
                RecognizerDetailRow(label: "Configured \(noun.lowercased())", value: configured ?? "Unknown"),
                RecognizerDetailRow(label: "Active \(noun.lowercased())", value: active ?? "Unknown"),
            ]
        }
        return rows(
            "Model",
            configured: VoiceModelDisplayName.normalize(state.configuredModelName),
            active: VoiceModelDisplayName.normalize(state.activeModelName)
        ) + (state.residency == .loaded && state.configuredEffort == state.activeEffort
            ? [] : rows("Recognition preset", configured: state.configuredEffort?.displayName, active: state.activeEffort?.displayName))
    }

    /// Spec 2.3 Recognizer details: the chosen recognizer, the one running now, and the effort.
    static func detailFacts(state: ModelsSettingsState, recognizer: RecognizerPickerState) -> [RecognizerDetailRow] {
        var rows: [RecognizerDetailRow] = []
        if let chosen = recognizer.selected { rows.append(.init(label: "Chosen", value: chosen.title)) }
        if let running = recognizer.effective, recognizer.residency(for: running) == .loaded {
            rows.append(.init(label: "Running now", value: running.title))
        } else if recognizer.selected != nil {
            rows.append(.init(label: "Running now", value: "Nothing loaded"))
        }
        if state.availability == .available, let effort = state.configuredEffort {
            let active = state.activeEffort.map { $0 == effort ? "" : " (running \($0.displayName))" } ?? ""
            rows.append(.init(label: "Effort", value: effort.displayName + active))
        }
        return rows
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
        let disabled = row.lockedReason != nil || busyReason != nil || onToggleProcessing == nil
            || processingPending[row.key] != nil
        return SettingsRow(title: row.key.title, description: row.line,
                           titleBadge: row.experimental ? SettingsPill(text: "Experimental", tint: .orange) : nil) {
            Toggle(row.key.title, isOn: Binding(
                get: { processingPending[row.key] ?? row.isOn },
                set: { onToggleProcessing?(row.key, $0) }
            ))
            .labelsHidden().toggleStyle(.switch)
            .disabled(disabled)
            .accessibilityIdentifier("models-processing-\(row.key.rawValue)")
            // Etan (QA 2026-11-11, shot 5): why it is locked shows on hover of the switch, never in the text.
            .settingsLockedReason(disabled ? row.lockedReason ?? busyReason : nil)
        }
        // SwiftUI's default macOS Form toggle leaves a saved-on switch looking active.
        // Keep its saved value but mute the entire row when it cannot be used.
        .opacity(disabled ? 0.45 : 1)
        .settingsLockedReasonBubble()
    }

    /// Row 2 (Etan ruling: Parakeet stays resident). OFF by default; nil while the daemon does not report it. The switch
    /// governs Parakeet's idle eviction (K2), so it names Parakeet and measures Parakeet's reported size, whichever
    /// engine is selected.
    struct UnloadWhenIdleRow: Equatable {
        let title: String
        let isOn: Bool
        let line: String
        let lockedReason: String?
        let disabled: Bool

        /// Same rule as the Processing rows: the explanation always shows; the lock's reason is on the switch's hover.
        var captionLines: [String] { [line] + (lockedReason.map { [$0] } ?? []) }
    }

    static func unloadWhenIdleRow(for recognizer: RecognizerPickerState, canChange: Bool = true) -> UnloadWhenIdleRow? {
        guard let setting = recognizer.unloadWhenIdle else { return nil }
        let engine = RecognizerPickerEngine.parakeet
        let size = recognizer.assetsPresent(for: engine) ? recognizer.diskBytes[engine].flatMap(approximateSize) : nil
        let idle = recognizer.idleUnloadSeconds.map { "after \(RecognizerPickerState.idleText($0)) without dictation" }
            ?? "when you are not dictating"
        return UnloadWhenIdleRow(
            title: "Unload when idle",
            isOn: recognizer.unloadWhenIdlePending ?? setting.effective,
            // The load cost is not measured on this Mac yet, so the copy says "a few seconds", never a number.
            line: "Frees \(size.map { "about \($0) of " } ?? "")memory \(idle). The next dictation loads \(engine.shortName) again, which adds a few seconds.",
            lockedReason: setting.lockedReason,
            disabled: setting.lockedReason != nil || recognizer.unloadWhenIdlePending != nil
                || recognizer.selected == nil || !canChange)
    }

    /// "~2.5 GB" from the reported 2.51 GB, to the nearest half gigabyte: the saving is approximate (memory, measured
    /// by the model's size on disk), and the number is always the model's own, never a literal.
    static func approximateSize(_ bytes: Int) -> String? {
        guard bytes > 0 else { return nil }
        let gigabytes = Double(bytes) / 1_000_000_000
        if gigabytes >= 1 {
            let rounded = (gigabytes * 2).rounded() / 2
            return (rounded == rounded.rounded() ? String(Int(rounded)) : String(format: "%.1f", rounded)) + " GB"
        }
        return "\(max(1, Int((Double(bytes) / 1_000_000).rounded()))) MB"
    }

    private func unloadWhenIdleToggle(_ row: UnloadWhenIdleRow) -> some View {
        SettingsRow(title: row.title, description: row.line) {
            Toggle(row.title, isOn: Binding(get: { row.isOn }, set: { onSetUnloadWhenIdle?($0) }))
                .labelsHidden().toggleStyle(.switch)
                .disabled(row.disabled)
                .accessibilityIdentifier("recognizer-unload-when-idle")
                .settingsLockedReason(row.lockedReason)
        }
        // Matches the Processing rows: a locked switch is muted whole, keeping its real value.
        .opacity(row.lockedReason != nil ? 0.45 : 1)
        .settingsLockedReasonBubble()
        .padding(.top, 4)
    }

    /// One Processing toggle: what it does, and why it cannot be changed here, if it cannot.
    struct ProcessingRow: Equatable {
        let key: ProcessingKey
        let line: String
        let experimental: Bool
        let isOn: Bool
        let lockedReason: String?

        /// C22: the explanation always shows; a lock adds its reason. The row paints only `line`; the reason shows
        /// on hover of the switch (Etan, QA 2026-11-11).
        var captionLines: [String] {
            [line] + (lockedReason.map { [$0] } ?? [])
        }
    }


    /// D194-r1: smart chunks exist only on the resident Whisper server path (src/stt.ts);
    /// whisper-cli and Wispr Flow return no segments, and a server request that falls back to the CLI skips them.
    /// Etan's note #2 (2.3): smart chunks are Whisper-only, so with Parakeet the row is disabled with this tooltip.
    static let unavailableWithParakeet = "Unavailable with Parakeet"

    static let whisperServerOnly = "Whisper server only: the whisper-cli and Wispr Flow fallbacks skip it."

    static func processingRows(for controls: PolishControlsState, recognizer: RecognizerPickerState? = nil) -> [ProcessingRow] {
        func locked(_ key: ProcessingKey, _ setting: PolishSetting<some Any>) -> String? {
            setting.source == .environment ? "Set by \(key.environmentVariable)" : nil
        }
        let polishLock = controls.modelPolish.effective == .shadow
            ? "Preview only (set by \(ProcessingKey.modelPolish.environmentVariable))"
            : locked(.modelPolish, controls.modelPolish)
        return [
            ProcessingRow(
                key: .modelPolish,
                line: "Fixes punctuation and capitals. If polish would add or drop a word, VoiceBar keeps the raw text instead.",
                experimental: false,
                isOn: controls.modelPolish.effective == .on,
                lockedReason: polishLock
            ),
            ProcessingRow(
                key: .outroGate,
                line: "Drops a “Thank you.” the recognizer invents in silence. Words you really said stay.",
                experimental: false,
                isOn: controls.outroGate.effective,
                lockedReason: locked(.outroGate, controls.outroGate)
            ),
            ProcessingRow(
                key: .smartChunks,
                line: "Splits long Whisper recordings at pauses.",
                experimental: true,
                isOn: controls.smartChunks.effective,
                lockedReason: recognizer.map { $0.smartChunkingApplicable ? locked(.smartChunks, controls.smartChunks) : unavailableWithParakeet } ?? locked(.smartChunks, controls.smartChunks)
            ),
        ]
    }
}
