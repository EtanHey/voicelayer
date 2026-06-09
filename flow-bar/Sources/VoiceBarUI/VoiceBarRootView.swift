import SwiftUI

public struct VoiceBarRootView: View {
    public var state: VoiceState
    public var commandRouter: BarCommandRouting
    public var usesNotchIsland: Bool

    public init(
        state: VoiceState,
        commandRouter: BarCommandRouting,
        usesNotchIsland: Bool
    ) {
        self.state = state
        self.commandRouter = commandRouter
        self.usesNotchIsland = usesNotchIsland
    }

    public var body: some View {
        let layout = Self.layout(for: state, usesNotchIsland: usesNotchIsland)
        let bar = BarView(
            state: state,
            commandRouter: commandRouter,
            usesExternalChrome: usesNotchIsland && !state.isCollapsed
        )

        if usesNotchIsland, !state.isCollapsed {
            NotchIslandContainer(contentSize: layout.contentRect.size) {
                bar
            }
        } else {
            bar
        }
    }

    public static func layout(for state: VoiceState?, usesNotchIsland: Bool) -> VoiceBarPanelLayout {
        let mode = state?.mode ?? .idle
        let previewText = VoiceBarPresentation.transcriptPreviewText(
            mode: mode,
            confirmationText: state?.confirmationText,
            commandModeState: state?.commandModeState,
            activeClipMarker: state?.activeClipMarker
        )
        let statusText = VoiceBarPresentation.liveStatusText(
            mode: mode,
            transcript: state?.transcript ?? "",
            confirmationText: state?.confirmationText,
            hotkeyPhase: state?.hotkeyPhase ?? .idle,
            hotkeyEnabled: state?.hotkeyEnabled ?? false,
            errorMessage: state?.errorMessage,
            transcribingStatusText: state?.transcribingStatusText,
            commandModeState: state?.commandModeState,
            activeClipMarker: state?.activeClipMarker
        )
        return VoiceBarPanelLayout.make(
            mode: mode,
            isCollapsed: state?.isCollapsed ?? false,
            previewText: previewText,
            statusText: statusText,
            idleAccessoryButtonCount: VoiceBarPresentation.idleAccessoryButtonCount(
                recentTranscriptions: state?.recentTranscriptions ?? [],
                transcriptionVocabularyTerms: state?.transcriptionVocabularyTerms ?? [],
                transcriptionVocabularyAliases: state?.transcriptionVocabularyAliases ?? [],
                canReplay: state?.canReplay ?? false
            ),
            queueItemCount: state?.queueItems.count ?? 0,
            isPasteFlowActive: state?.keepsPasteFlowEnvelope ?? false,
            padding: Theme.panelPadding,
            usesNotchIsland: usesNotchIsland
        )
    }
}
