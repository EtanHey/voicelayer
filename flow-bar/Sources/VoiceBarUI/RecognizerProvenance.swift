import Foundation

/// Who really wrote a transcript, read from the daemon's backend chain.
///
/// The chain reads left to right: `<asked first>+fallback-<reason>-><wrote the text>+<suffixes>`, e.g. the live
/// `parakeet-resident+fallback-uncovered-tail->whisper.cpp+qualified-fallback`. The engine after the LAST `->` wrote
/// the delivered text; the first segment is the engine that was asked first. Copy built from this always names the
/// writer, and never says the first engine "couldn't transcribe" when its reason shows it returned text (Lane K-ui
/// row 1, lead ruling 00:17Z).
public struct RecognizerProvenance: Equatable, Sendable {
    public enum Engine: String, Equatable, Sendable {
        case parakeet, whisper, wisprFlow

        public var name: String {
            switch self {
            case .parakeet: "Parakeet"
            case .whisper: "Whisper"
            case .wisprFlow: "Wispr Flow"
            }
        }

        init?(backendID: String) {
            let id = backendID.lowercased()
            if id.hasPrefix("parakeet") { self = .parakeet }
            else if id.hasPrefix("wispr") { self = .wisprFlow }
            else if id.hasPrefix("whisper") { self = .whisper }
            else { return nil }
        }

        init?(_ engine: RecognizerPickerEngine?) {
            switch engine {
            case .parakeet: self = .parakeet
            case .whisper: self = .whisper
            case nil: return nil
            }
        }
    }

    /// The engine that was asked first.
    public let firstEngine: Engine?
    /// The engine whose text was delivered.
    public let writer: Engine?
    /// The first `+fallback-<reason>` on the way to the writer.
    public let fallbackReason: String?
    /// Another engine that re-checked only the ending while the writer's text was kept.
    public let endingRecheckedBy: Engine?

    public init(firstEngine: Engine?, writer: Engine?, fallbackReason: String? = nil, endingRecheckedBy: Engine? = nil) {
        self.firstEngine = firstEngine; self.writer = writer
        self.fallbackReason = fallbackReason; self.endingRecheckedBy = endingRecheckedBy
    }

    public init?(backend: String?) {
        guard let backend = backend?.trimmingCharacters(in: .whitespacesAndNewlines), !backend.isEmpty else { return nil }
        let segments = backend.components(separatedBy: "->").map { $0.split(separator: "+").map(String.init) }
        let first = segments.first?.first.flatMap(Engine.init(backendID:))
        let writer = segments.last?.first.flatMap(Engine.init(backendID:))
        guard first != nil || writer != nil else { return nil }
        let reason = segments.dropLast().lazy.flatMap { $0.dropFirst() }
            .first { $0.hasPrefix("fallback-") }.map { String($0.dropFirst("fallback-".count)) }
        // ADAPTER (lane K's tail re-check format is not posted yet): a kept transcript whose ending a second engine
        // re-checked is marked by a `+…tail…` token naming that engine, e.g. `parakeet-resident+tail-recheck-whisper`.
        let recheckToken = segments.last?.dropFirst().first { token in
            let t = token.lowercased()
            return t.contains("tail") && (t.contains("recheck") || t.contains("re-check") || t.contains("verif"))
        }
        let rechecker = recheckToken.flatMap { token -> Engine? in
            let t = token.lowercased()
            let named: Engine? = t.contains("whisper") ? .whisper : t.contains("parakeet") ? .parakeet : nil
            return named ?? writer.map { $0 == .parakeet ? .whisper : .parakeet }
        }
        self.init(firstEngine: first ?? writer, writer: writer ?? first, fallbackReason: reason,
                  endingRecheckedBy: rechecker == writer ? nil : rechecker)
    }

    /// One plain sentence about how this transcript was made, or nil when the engine asked first wrote it alone.
    public var notice: String? { notice(about: "this recording") }

    /// `subject` names the recording: History says "this recording", the picker "your last recording".
    public func notice(about subject: String) -> String? {
        guard let writer else { return nil }
        if let checker = endingRecheckedBy {
            return "\(writer.name) transcribed; \(checker.name) re-checked the ending."
        }
        guard let first = firstEngine, first != writer else { return nil }
        let wrote = "\(writer.name) transcribed \(subject)"
        switch fallbackReason {
        // Legacy routing reasons: report the writer without implying the first engine failed.
        case "language", "prompt", "input-format", "input-identity":
            return "Using \(writer.name) for \(subject)."
        // The first engine returned text, but the daemon judged it risky. It did transcribe.
        case "uncovered-tail":
            return "\(wrote): \(first.name)'s text stopped before the ending."
        case "sparse-response":
            return "\(wrote): \(first.name) returned too few words for its length."
        case "invalid-timing":
            return "\(wrote): \(first.name)'s word timings didn't line up with the audio."
        case "incomplete-response", "provider-partial":
            return "\(wrote): \(first.name) covered only part of it."
        case "empty-response":
            return "\(wrote): \(first.name) returned no text."
        case "zero-pcm-response":
            return "\(writer.name) checked \(subject): the microphone recorded only silence."
        case "unsupported-language":
            return "\(wrote): \(first.name) doesn't support this language."
        case "parakeet-startup-failed", "whisper-startup-failed":
            return "\(wrote): \(first.name) failed to load."
        case "timeout", "provider-timeout":
            return "\(wrote): \(first.name) took too long."
        // These are real failures: the first engine produced nothing usable.
        case "provider-error", "server-error", "invalid-response", "provider-invalid":
            return "\(wrote) because \(first.name) couldn't transcribe it."
        default:
            return "\(wrote) instead of \(first.name)."
        }
    }
}
