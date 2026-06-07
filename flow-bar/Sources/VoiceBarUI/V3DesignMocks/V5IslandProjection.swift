import Foundation

public enum V5IslandRenderKind: Equatable {
    case idle
    case recording
    case transcribing
    case speaking
    case error
}

public struct V5IslandHistoryRow: Equatable, Identifiable {
    public var id: Int
    public var text: String
}

public struct V5IslandPreservedTerm: Equatable, Identifiable {
    public var id: Int
    public var term: String
}

public struct V5IslandCorrectedTerm: Equatable, Identifiable {
    public var id: Int
    public var from: String
    public var to: String
}

public struct V5IslandProjection: Equatable {
    public var renderKind: V5IslandRenderKind
    public var micOpacity: Double
    public var allowsHoverReveal: Bool
    public var audioLevel: Double?
    public var recordingStartedAt: Date?
    public var usesStaticSpeakingBars: Bool
    public var errorTTL: TimeInterval
    public var errorMessage: String?
    public var historyRows: [V5IslandHistoryRow]
    public var preservedTerms: [V5IslandPreservedTerm]
    public var correctedTerms: [V5IslandCorrectedTerm]

    public static func make(
        mode: VoiceMode,
        audioLevel: Double? = nil,
        recordingStartedAt: Date? = nil,
        recentTranscriptions: [String] = [],
        vocabularyTerms: [String] = [],
        vocabularyAliases: [STTVocabularyAliasPreview] = [],
        errorMessage: String? = nil
    ) -> V5IslandProjection {
        let renderKind: V5IslandRenderKind = switch mode {
        case .idle, .disconnected:
            .idle
        case .recording:
            .recording
        case .transcribing:
            .transcribing
        case .speaking:
            .speaking
        case .error:
            .error
        }

        return V5IslandProjection(
            renderKind: renderKind,
            micOpacity: mode == .disconnected ? 0.35 : 1.0,
            allowsHoverReveal: mode == .idle,
            audioLevel: audioLevel,
            recordingStartedAt: mode == .recording ? recordingStartedAt : nil,
            usesStaticSpeakingBars: mode == .speaking && audioLevel == nil,
            errorTTL: mode == .error ? 2.0 : 0,
            errorMessage: errorMessage,
            historyRows: recentTranscriptions.enumerated().map { index, text in
                V5IslandHistoryRow(id: index, text: text)
            },
            preservedTerms: vocabularyTerms.enumerated().map { index, term in
                V5IslandPreservedTerm(id: index, term: term)
            },
            correctedTerms: vocabularyAliases.enumerated().map { index, alias in
                V5IslandCorrectedTerm(id: index, from: alias.from, to: alias.to)
            }
        )
    }
}
