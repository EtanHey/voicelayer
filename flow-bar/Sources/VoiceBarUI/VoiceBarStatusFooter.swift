import SwiftUI

public struct VoiceBarFooterPresentation: Equatable {
    public let status: String
    /// Only a configured remote backend earns a line. Local transcription is the only shipped path, so the
    /// default says nothing (S2, Etan 2026-11-02: no local-processing line anywhere).
    public let remoteNotice: String?
    public let isReady: Bool
    /// Hidden by choice ("Hide for 1 hour") with the daemon still connected: not broken, so no "Disconnected".
    public var isHidden: Bool = false
    public var errorDetails: String? = nil

    public static func resolve(
        isConnected: Bool,
        mode: VoiceMode,
        captureLive: Bool,
        errorMessage: String?,
        remoteSTTConfigured: Bool?,
        hasFreshHealth: Bool = false,
        healthUnreadable: Bool = false,
        isHidden: Bool = false,
        hiddenUntil: Date? = nil,
        loadingRecognizer: RecognizerPickerEngine? = nil
    ) -> Self {
        // An agent can still speak or record while the bar is hidden; that activity reads as itself.
        let showsHidden = isHidden && isConnected && (mode == .idle || mode == .disconnected)
        let status: String = if showsHidden {
            SettingsVisibility.hiddenStatus(until: hiddenUntil)
        } else if !isConnected || mode == .disconnected {
            "Disconnected"
        } else if mode == .error || errorMessage != nil {
            "Error"
        } else {
            switch mode {
            // QA-32: not "Ready" while the selected recognizer is still loading.
            case .idle: hasFreshHealth
                ? loadingRecognizer.map { "Loading \($0.shortName)…" } ?? "Ready"
                : healthUnreadable ? "Status unreadable" : "Starting…"
            case .recording: captureLive ? "Recording" : "Starting microphone"
            case .transcribing: "Transcribing"
            case .speaking: "Agent speaking"
            case .error: "Error"
            case .disconnected: "Disconnected"
            }
        }

        return Self(
            status: status,
            remoteNotice: remoteSTTConfigured == true ? "Remote speech backend configured" : nil,
            isReady: status == "Ready",
            isHidden: showsHidden,
            errorDetails: status == "Error"
                ? SettingsCopyPayload.nonempty(errorMessage) ?? "No error details are available."
                : nil
        )
    }

    public static func resolve(state: VoiceState) -> Self {
        resolve(
            isConnected: state.isConnected,
            mode: state.mode,
            captureLive: state.captureLive,
            errorMessage: state.errorMessage,
            remoteSTTConfigured: state.remoteSTTConfigured,
            hasFreshHealth: state.modelsSettingsState.availability == .available,
            healthUnreadable: state.modelsSettingsState.availability == .unreadable,
            isHidden: state.isHidden,
            hiddenUntil: state.hiddenUntil,
            loadingRecognizer: loadingRecognizer(state.recognizerPickerState)
        )
    }

    /// The selected recognizer while it is still loading, else nil (QA-32).
    static func loadingRecognizer(_ recognizer: RecognizerPickerState) -> RecognizerPickerEngine? {
        recognizer.selected.flatMap { recognizer.residency(for: $0) == .loading ? $0 : nil }
    }
}

public struct VoiceBarStatusIndicator: View {
    public let presentation: VoiceBarFooterPresentation

    public init(presentation: VoiceBarFooterPresentation) {
        self.presentation = presentation
    }

    public var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(presentation.isReady ? .green : presentation.isHidden ? .secondary : .orange)
                .frame(width: 7, height: 7)
            Text(presentation.status)
                .font(.system(size: 12, weight: .medium))
        }
    }
}
