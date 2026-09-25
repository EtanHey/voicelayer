import SwiftUI

public struct VoiceBarFooterPresentation: Equatable {
    public let status: String
    public let privacy: String
    public let isReady: Bool
    public let isLocalOnly: Bool
    public let privacySymbol: String

    public static func resolve(
        isConnected: Bool,
        mode: VoiceMode,
        captureLive: Bool,
        errorMessage: String?,
        remoteSTTConfigured: Bool?,
        hasFreshHealth: Bool = false,
        healthUnreadable: Bool = false
    ) -> Self {
        let status: String = if !isConnected || mode == .disconnected {
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
            privacySymbol: privacySymbol
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
            healthUnreadable: state.modelsSettingsState.availability == .unreadable
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
                .fill(presentation.isReady ? .green : .orange)
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
