import Foundation

public enum PolishSettingSource: String, Equatable, Sendable {
    case environment
    /// Saved by the Processing toggles (the daemon's processing-settings.json).
    case settings
    case `default`
}

/// The four Processing toggles, keyed as the daemon names them (P1).
public enum ProcessingKey: String, CaseIterable, Equatable, Hashable, Sendable {
    case modelPolish = "model_polish"
    case outroGate = "outro_gate"
    case smartChunks = "smart_chunks"
    case smartBoundaries = "smart_boundaries"

    /// The environment variable that, when set, overrides the saved toggle.
    public var environmentVariable: String {
        switch self {
        case .modelPolish: "QA_VOICE_STT_POLISH"
        case .outroGate: "VOICELAYER_STT_OUTRO_GATE"
        case .smartChunks: "VOICELAYER_STT_SMART_CHUNKS"
        case .smartBoundaries: "VOICELAYER_STT_SMART_BOUNDARIES"
        }
    }

    public var title: String {
        switch self {
        case .modelPolish: "Polish"
        case .outroGate: "Closing-phrase filter"
        case .smartChunks: "Smart chunks"
        case .smartBoundaries: "Smart boundaries"
        }
    }
}

public enum ModelPolishMode: String, Equatable, Sendable {
    case off
    case shadow
    case on

    public var displayName: String {
        switch self {
        case .off: "Off"
        case .shadow: "Preview only"
        case .on: "On"
        }
    }
}

public struct PolishSetting<Value: Equatable & Sendable>: Equatable, Sendable {
    public let source: PolishSettingSource
    public let raw: String?
    public let effective: Value
}

public struct PolishControlsState: Equatable, Sendable {
    public let modelPolish: PolishSetting<ModelPolishMode>
    public let outroGate: PolishSetting<Bool>
    public let smartChunks: PolishSetting<Bool>
    public let smartBoundaries: PolishSetting<Bool>

    public init?(healthEvent: [String: Any]) {
        guard healthEvent["type"] as? String == "health",
              let controls = healthEvent["polish_controls"] as? [String: Any]
        else { return nil }
        self.init(controls: controls)
    }

    /// The bare `polish_controls` object, as a health event or a processing ack carries it.
    public init?(controls: [String: Any]) {
        guard let model = Self.parse(
            controls["model_polish"],
            value: { ModelPolishMode(rawValue: $0 as? String ?? "") }
        ),
            let outro = Self.parse(controls["outro_gate"], value: { $0 as? Bool }),
            let chunks = Self.parse(controls["smart_chunks"], value: { $0 as? Bool }),
            let boundaries = Self.parse(controls["smart_boundaries"], value: { $0 as? Bool })
        else { return nil }
        modelPolish = model
        outroGate = outro
        smartChunks = chunks
        smartBoundaries = boundaries
    }

    private static func parse<Value: Equatable & Sendable>(
        _ value: Any?,
        value decode: (Any) -> Value?
    ) -> PolishSetting<Value>? {
        guard let data = value as? [String: Any],
              let sourceRaw = data["source"] as? String,
              let source = PolishSettingSource(rawValue: sourceRaw),
              let effectiveRaw = data["effective"],
              let effective = decode(effectiveRaw)
        else { return nil }
        let raw = data["raw"] as? String
        guard ((source == .default || source == .settings) && data["raw"] is NSNull)
            || (source == .environment && raw != nil) else { return nil }
        return PolishSetting(source: source, raw: raw, effective: effective)
    }
}
