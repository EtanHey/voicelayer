import SwiftUI

public struct VoiceBarFooterPresentation: Equatable {
    public let status: String
    public let privacy: String
    public let isReady: Bool
    public let isLocalOnly: Bool
    public let privacySymbol: String
    /// Hidden by choice ("Hide for 1 hour") with the daemon still connected: not broken, so no "Disconnected".
    public var isHidden: Bool = false

    public static func resolve(
        isConnected: Bool,
        mode: VoiceMode,
        captureLive: Bool,
        errorMessage: String?,
        remoteSTTConfigured: Bool?,
        hasFreshHealth: Bool = false,
        healthUnreadable: Bool = false,
        isHidden: Bool = false,
        hiddenUntil: Date? = nil
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
            case .idle: hasFreshHealth ? "Ready" : healthUnreadable ? "Status unreadable" : "Starting…"
            case .recording: captureLive ? "Recording" : "Starting microphone"
            case .transcribing: "Transcribing"
            case .speaking: "Agent speaking"
            case .error: "Error"
            case .disconnected: "Disconnected"
            }
        }

        let privacy = switch remoteSTTConfigured {
        case .some(false): "Transcribed on this Mac"
        case .some(true): "Remote speech backend configured"
        case .none: "Processing location unavailable"
        }
        let privacySymbol = switch remoteSTTConfigured {
        case .some(false): "lock.fill"
        case .some(true): "network"
        case .none: "questionmark.circle"
        }
        return Self(
            status: status,
            privacy: privacy,
            isReady: status == "Ready",
            isLocalOnly: remoteSTTConfigured == false,
            privacySymbol: privacySymbol,
            isHidden: showsHidden
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
            hiddenUntil: state.hiddenUntil
        )
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

public struct VoiceBarStatusFooter: View {
    public let presentation: VoiceBarFooterPresentation

    public init(presentation: VoiceBarFooterPresentation) {
        self.presentation = presentation
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            VoiceBarStatusIndicator(presentation: presentation)
            Label(
                presentation.privacy,
                systemImage: presentation.privacySymbol
            )
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
