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
        public let measuredEngine: String?
        public let measurementOrigin: String?
        public let measurementFallback: Bool
        public var latencyLabel: String {
            guard let ms = firstAudioMS, let engine = measuredEngine, let origin = measurementOrigin else {
                return "Not measured yet. Press Preview."
            }
            let name = engine == "edge-tts" ? "Fast voice" : "Cloned voice"
            let source = origin == "preview" ? "Last preview" : "Last speech"
            return String(format: "%@: first sound after %.1f s · %@%@", source, ms / 1000, name,
                          measurementFallback ? " (fallback)" : "")
        }
    }
    public struct Voice: Equatable, Sendable { public let engine: String; public let voice: String }
    public let profiles: [SpeechProfile: Profile]
    public let shortLimit: SpeechSetting<Int>
    public let availableVoices: [Voice]
    public let cloneRunning: Bool
    public let previewActive: Bool?

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
            let measured = p["last_first_audio"] as? [String: Any]
            let engineName = measured?["engine"] as? String
            let origin = measured?["origin"] as? String
            let validMeasurement = ["edge-tts", "xtts-v2", "f5-tts-mlx", "qwen3-tts"].contains(engineName ?? "")
                && ["preview", "speak"].contains(origin ?? "")
            profiles[kind] = Profile(engine: engine, voice: voice, rate: rate,
                                     firstAudioMS: latency.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil },
                                     measuredEngine: validMeasurement ? engineName : nil,
                                     measurementOrigin: validMeasurement ? origin : nil,
                                     measurementFallback: measured?["fallback"] as? Bool ?? false)
        }
        self.profiles = profiles
        shortLimit = limit
        availableVoices = voices.compactMap {
            guard let engine = $0["engine"], ["edge", "clone"].contains(engine), let voice = $0["voice"],
                  engine == "edge" || voice == "theo-c4s" || voice == "ben-c1" else { return nil }
            return Voice(engine: engine, voice: voice)
        }
        cloneRunning = daemon == "up"
        previewActive = controls["preview_active"] as? Bool
    }

    public func voices(for engine: String) -> [String] { availableVoices.filter { $0.engine == engine }.map(\.voice) }
    public func preferredVoice(for engine: String, current: String) -> String? {
        let candidates = voices(for: engine)
        return candidates.contains(current) ? current : candidates.first
    }
    public func lockReason(for key: String) -> String? {
        if key == "short_limit_chars", shortLimit.source == .environment { return "Set by environment" }
        let parts = key.split(separator: ".")
        guard parts.count == 2, let kind = SpeechProfile(rawValue: String(parts[0])), let p = profiles[kind] else { return nil }
        if parts[1] == "engine", p.engine.source == .environment { return "Set by QA_VOICE_TTS_VOICE" }
        if parts[1] == "voice", p.voice.source == .environment { return "Set by QA_VOICE_TTS_VOICE" }
        if parts[1] == "rate", p.rate.source == .environment { return "Set by QA_VOICE_TTS_RATE" }
        return nil
    }
}

/// Local input only. Confirmed values always come from daemon controls, never pending writes.
struct SpeechThresholdDraft: Equatable {
    private(set) var text: String?
    static let maximum = 9_007_199_254_740_991 // Number.MAX_SAFE_INTEGER in validTTSSetting.

    func displayedText(_ limit: SpeechSetting<Int>?) -> String {
        text ?? limit.map { String($0.effective) } ?? ""
    }
    static func value(_ text: String) -> Int? {
        guard let value = Int(text), value > 0, value <= maximum else { return nil }
        return value
    }
    var validationMessage: String? {
        guard let text, Self.value(text) == nil else { return nil }
        return "Enter a positive whole number no greater than \(Self.maximum)."
    }
    mutating func edit(_ text: String) { self.text = text }
    mutating func revert() { text = nil }
    mutating func reconcile(_ limit: SpeechSetting<Int>?) {
        if let limit, let text, let value = Self.value(text), value == limit.effective { self.text = nil }
    }
    static let reportStatus = "Profile descriptions and Revert use the last reported cutoff; current settings may differ."
    static let captionContext = "Based on the last reported cutoff."
    static let revertHelp = "Restore the last reported cutoff locally without changing VoiceLayer."
    static func confirmedLabel(_ limit: SpeechSetting<Int>?) -> String {
        guard let limit else { return "No reported cutoff available; waiting for VoiceLayer." }
        switch limit.source {
        case .environment:
            return "Last reported effective cutoff: \(limit.effective) characters · Environment override; saved value not reported."
        case .settings:
            let source = limit.raw == .number(limit.effective) ? "Saved in settings at that report" : "Settings source at that report"
            return "Last reported cutoff: \(limit.effective) characters · \(source)"
        case .default:
            return "Last reported cutoff: \(limit.effective) characters · Default at that report; no saved value reported."
        }
    }
    static func blockedReason(controls: SpeechControlsState?, connected: Bool, busy: Bool,
                              pending: [String: SpeechValue], callbackAvailable: Bool) -> String? {
        guard connected else { return "VoiceLayer isn't connected. Draft retained." }
        guard let controls else { return "Waiting for Speech settings." }
        if let lock = controls.lockReason(for: "short_limit_chars") { return "\(lock). Threshold is locked." }
        if case .number(let value) = pending["short_limit_chars"] {
            return "Applying \(value) characters… Awaiting confirmation."
        }
        if !pending.isEmpty { return "A speech request is pending." }
        if busy { return "Voice session in progress." }
        return callbackAvailable ? nil : "Speech setting changes are unavailable."
    }
    func canApply(controls: SpeechControlsState?, connected: Bool, busy: Bool,
                  pending: [String: SpeechValue], callbackAvailable: Bool) -> Bool {
        guard Self.blockedReason(controls: controls, connected: connected, busy: busy,
                                 pending: pending, callbackAvailable: callbackAvailable) == nil,
              let text, let value = Self.value(text) else { return false }
        return value != controls?.shortLimit.effective
    }
    func apply(controls: SpeechControlsState?, connected: Bool, busy: Bool,
               pending: [String: SpeechValue], onChange: ((String, SpeechValue) -> Void)?) {
        guard canApply(controls: controls, connected: connected, busy: busy,
                       pending: pending, callbackAvailable: onChange != nil),
              let text, let value = Self.value(text) else { return }
        onChange?("short_limit_chars", .number(value))
    }
}
