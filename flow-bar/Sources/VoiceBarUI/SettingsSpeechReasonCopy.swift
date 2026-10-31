import Foundation

/// The sentence Settings › History › Speech shows for a record's state and reason.
/// Display only: the reason codes are the daemon's wire values and are never rewritten here.
/// `src/__tests__/speech-reason-copy-guard.test.ts` fails when `speechReasons` gains a code this file does not map.
enum SettingsSpeechReasonCopy {
    static let knownReasons: Set<String> = ["PROCESS_RESTART", "PROCESS_EXIT", "REJECTED", "SYNTH_FAILED", "PLAYER_FAILED", "OUTPUT_UNAVAILABLE", "ARCHIVE_INCOMPLETE", "SPEECH_FAILED", "USER_STOP", "USER_STOP_PREPARING", "USER_CANCEL", "QUEUE_CLEARED", "PLAYBACK_COMPLETED", "REPLACED"]

    /// `status` is `speech.state`, or the top-level archive status for records without a speech block.
    /// Nil means no reason line: a read that played to the end needs no explanation (Etan, D1 2026-10-31).
    static func sentence(status: String, reason: String?) -> String? {
        if status == "completed" || reason == "PLAYBACK_COMPLETED" { return nil }
        switch status {
        case "requested", "received": return "Waiting to start."
        case "preparing": return "Preparing narration…"
        case "playing": return "Playing now."
        case "paused": return "Paused."
        default: break
        }
        switch reason {
        case nil: return "No reason was recorded."
        // A stop that lands before the first audio is archived as cancelled with USER_STOP.
        case "USER_STOP": return status == "cancelled" ? "You stopped it before any audio played." : "You stopped it."
        case "USER_STOP_PREPARING": return "You stopped it before any audio played."
        case "USER_CANCEL": return "You cancelled it."
        case "QUEUE_CLEARED": return "The queue was cleared before this played."
        case "REPLACED": return "A newer read replaced this one."
        case "PROCESS_EXIT": return "VoiceLayer shut down before this finished."
        case "PROCESS_RESTART": return "VoiceLayer restarted before this finished."
        case "SYNTH_FAILED": return "The voice couldn't generate this speech."
        case "PLAYER_FAILED": return "Audio playback failed."
        case "OUTPUT_UNAVAILABLE": return "No audio output was available."
        case "REJECTED": return "VoiceLayer turned this request down before playing it."
        case "SPEECH_FAILED": return "Speech failed before it finished."
        case "ARCHIVE_INCOMPLETE": return "This read was only partly saved."
        default: return "Ended for a reason this version doesn't recognise."
        }
    }
}
