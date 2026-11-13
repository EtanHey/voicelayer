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

    public init(firstEngine: Engine?, writer: Engine?, fallbackReason: String? = nil) {
        self.firstEngine = firstEngine; self.writer = writer; self.fallbackReason = fallbackReason
    }

    public init?(backend: String?) {
        guard let backend = backend?.trimmingCharacters(in: .whitespacesAndNewlines), !backend.isEmpty else { return nil }
        let segments = backend.components(separatedBy: "->").map { $0.split(separator: "+").map(String.init) }
        let first = segments.first?.first.flatMap(Engine.init(backendID:))
        let writer = segments.last?.first.flatMap(Engine.init(backendID:))
        guard first != nil || writer != nil else { return nil }
        let reason = segments.dropLast().lazy.flatMap { $0.dropFirst() }
            .first { $0.hasPrefix("fallback-") }.map { String($0.dropFirst("fallback-".count)) }
        self.init(firstEngine: first ?? writer, writer: writer ?? first, fallbackReason: reason)
    }

    /// History keeps the failure and its machine reason visible, including future codes.
    public var errorNotice: String? {
        guard let writer, let first = firstEngine, first != writer else { return nil }
        let causes = [
            "parakeet-startup-failed": "failed to start", "whisper-startup-failed": "failed to start",
            "provider-error": "reported an error", "server-error": "reported a server error",
            "timeout": "took too long", "provider-timeout": "took too long",
            "input-format": "could not read the audio format", "input-identity": "returned mismatched audio evidence",
            "language": "could not use the requested language", "unsupported-language": "does not support this language",
            "prompt": "could not use the requested prompt", "uncovered-tail": "missed the ending",
            "uncovered-internal": "missed part of the recording", "sparse-response": "returned too few words",
            "invalid-timing": "returned invalid word timings", "incomplete-response": "returned only part of the recording",
            "provider-partial": "returned only part of the recording", "empty-response": "returned no text",
            "invalid-response": "returned an invalid response", "provider-invalid": "returned an invalid response",
            "zero-pcm-response": "received audio containing only silence"
        ]
        let reason = fallbackReason ?? "unknown"
        let cause = causes[reason] ?? "could not be used (\(reason))"
        return "\(first.name) \(cause), so \(writer.name) transcribed this recording."
    }

    /// One plain sentence about how this transcript was made, or nil when the engine asked first wrote it alone.
    public var notice: String? { notice(about: "this recording") }

    /// `subject` names the recording: History says "this recording", the picker "your last recording".
    public func notice(about subject: String) -> String? {
        guard let writer, let first = firstEngine, first != writer else { return nil }
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
