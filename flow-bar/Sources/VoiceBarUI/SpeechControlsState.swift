import Foundation

public enum SpeechProfile: String, CaseIterable, Sendable {
    case short, long
    public var title: String { self == .short ? "Short speaks" : "Long reads" }
}

public enum SpeechValue: Equatable, Sendable {
    case string(String), number(Int)
    public var payload: Any { switch self { case .string(let v): v; case .number(let v): v } }
}

public struct SpeechSetting<Value: Equatable & Sendable>: Equatable, Sendable {
    public let source: PolishSettingSource
    public let raw: SpeechValue?
    public let effective: Value
}

public struct SpeechControlsState: Equatable, Sendable {
    public struct Profile: Equatable, Sendable {
        public let engine: SpeechSetting<String>
        public let voice: SpeechSetting<String>
        public let rate: SpeechSetting<String>
        public let firstAudioMS: Double?
        public var latencyLabel: String {
            firstAudioMS.map { String(format: "First audio: %.1f s", $0 / 1000) } ?? "First audio: —"
        }
    }
    public struct Voice: Equatable, Sendable { public let engine: String; public let voice: String }
    public let profiles: [SpeechProfile: Profile]
    public let shortLimit: SpeechSetting<Int>
    public let availableVoices: [Voice]
    public let cloneRunning: Bool

    public init?(controls: [String: Any]) {
        func field<T: Equatable & Sendable>(_ data: Any?, _ decode: (Any) -> T?) -> SpeechSetting<T>? {
            guard let data = data as? [String: Any], let source = data["source"] as? String,
                  let source = PolishSettingSource(rawValue: source), let raw = data["effective"],
                  let effective = decode(raw) else { return nil }
            let stored: SpeechValue?
            if data["raw"] is NSNull { stored = nil }
            else if let string = data["raw"] as? String { stored = .string(string) }
            else if let number = data["raw"] as? Int { stored = .number(number) }
            else { return nil }
            if source == .environment, stored == nil { return nil }
            return SpeechSetting(source: source, raw: stored, effective: effective)
        }
        guard let raw = controls["profiles"] as? [String: [String: Any]],
              let limit = field(controls["short_limit_chars"], { $0 as? Int }), limit.effective > 0,
              let voices = controls["available_voices"] as? [[String: String]],
              let daemon = controls["clone_daemon"] as? String, ["up", "down"].contains(daemon) else { return nil }
        var profiles: [SpeechProfile: Profile] = [:]
        for kind in SpeechProfile.allCases {
            guard let p = raw[kind.rawValue],
                  let engine = field(p["engine"], { $0 as? String }), ["edge", "clone"].contains(engine.effective),
                  let voice = field(p["voice"], { $0 as? String }),
                  let rate = field(p["rate"], { $0 as? String }) else { return nil }
            let latency = (p["last_first_audio_ms"] as? NSNumber)?.doubleValue
            profiles[kind] = Profile(engine: engine, voice: voice, rate: rate,
                                     firstAudioMS: latency.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil })
        }
        self.profiles = profiles
        shortLimit = limit
        availableVoices = voices.compactMap {
            guard let engine = $0["engine"], ["edge", "clone"].contains(engine), let voice = $0["voice"] else { return nil }
            return Voice(engine: engine, voice: voice)
        }
        cloneRunning = daemon == "up"
    }

    public func voices(for engine: String) -> [String] { availableVoices.filter { $0.engine == engine }.map(\.voice) }
    public func preferredVoice(for engine: String, current: String) -> String? {
        let candidates = voices(for: engine)
        return candidates.contains(current) ? current : candidates.first
    }
    public func lockReason(for key: String) -> String? {
        let parts = key.split(separator: ".")
        guard parts.count == 2, let kind = SpeechProfile(rawValue: String(parts[0])), let p = profiles[kind] else { return nil }
        if parts[1] == "engine", p.engine.source == .environment { return "Set by QA_VOICE_TTS_VOICE" }
        if parts[1] == "voice", p.voice.source == .environment { return "Set by QA_VOICE_TTS_VOICE" }
        if parts[1] == "rate", p.rate.source == .environment { return "Set by QA_VOICE_TTS_RATE" }
        return nil
    }
}
