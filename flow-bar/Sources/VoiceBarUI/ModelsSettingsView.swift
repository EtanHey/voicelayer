import SwiftUI

public struct ModelsSettingsView: View {
    public let state: ModelsSettingsState
    @Binding private var effort: VoiceBarPerformanceEffort
    private let notice: String?
    private let onSelectEffort: (VoiceBarPerformanceEffort) -> Void

    public init(
        state: ModelsSettingsState,
        effort: Binding<VoiceBarPerformanceEffort>,
        notice: String? = nil,
        onSelectEffort: @escaping (VoiceBarPerformanceEffort) -> Void
    ) {
        self.state = state
        _effort = effort
        self.notice = notice
        self.onSelectEffort = onSelectEffort
    }

    public var body: some View {
        Form {
            Section("Speech recognition") {
                LabeledContent("Configured model") {
                    Text(configuredName).accessibilityIdentifier("models-configured-model")
                }
                LabeledContent("Model file") {
                    Text(installedLabel).accessibilityIdentifier("models-model-file")
                }
                LabeledContent("Residency") {
                    Text(residencyLabel).accessibilityIdentifier("models-residency")
                }
                LabeledContent("Active model") {
                    Text(activeName).accessibilityIdentifier("models-active-model")
                }
                LabeledContent("Active effort") {
                    Text(state.activeEffort?.displayName ?? "Unknown")
                        .accessibilityIdentifier("models-active-effort")
                }
            }
            Section("Transcription effort") {
                Picker("Effort", selection: Binding(
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
                .pickerStyle(.segmented)
                .accessibilityIdentifier("models-effort-picker")
                .disabled(state.isBusy || state.availability != .available)
                if state.isBusy, state.availability == .available {
                    Text("Effort can be changed when recording and transcription are idle.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let notice {
                    Text(notice).font(.caption).foregroundStyle(.orange)
                }
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("models-settings-form")
    }

    private var configuredName: String {
        value(state.configuredModelName, missing: "Not found")
    }

    private var activeName: String {
        value(state.activeModelName, missing: "Unknown")
    }

    private var installedLabel: String {
        guard state.availability == .available else { return availabilityLabel }
        guard state.isInstalled == true else { return "Not installed" }
        guard let bytes = state.configuredModelSizeBytes else { return "Installed" }
        return "Installed · \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))"
    }

    private var residencyLabel: String {
        guard state.availability == .available else { return availabilityLabel }
        switch state.residency {
        case .loaded: return "Loaded"
        case .notLoaded: return "Not loaded"
        case .unknown: return "Unknown"
        }
    }

    private var availabilityLabel: String {
        state.availability == .loading ? "Checking…" : "Status unavailable"
    }

    private func value(_ value: String?, missing: String) -> String {
        guard state.availability == .available else { return availabilityLabel }
        return value ?? missing
    }
}
