import Foundation

/// L4 → L5 contract. Presentation consumes this value; handlers re-evaluate current facts.
/// An explanation is an accepted intent, never evidence that media or a mutation succeeded.
public struct ControlAvailability: Equatable, Sendable {
    public enum Outcome: Equatable, Sendable { case available, unavailable(String), explain(String), hidden }
    public let outcome: Outcome
    public init(_ outcome: Outcome) {
        switch outcome {
        case .unavailable(let text) where text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty:
            self.outcome = .unavailable("This action is unavailable")
        case .explain(let text) where text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty:
            self.outcome = .explain("This action is unavailable")
        default: self.outcome = outcome
        }
    }
    public var isVisible: Bool { outcome != .hidden }
    public var isEnabled: Bool {
        switch outcome { case .available, .explain: true; default: false }
    }
    public var reason: String? {
        switch outcome { case .unavailable(let text), .explain(let text): text; default: nil }
    }
    /// Attach to native hover AND accessibility; SwiftUI help alone fails in the notch panel.
    public var tooltip: String? { reason }
    public var accessibilityHint: String? { reason }
}

public enum VoiceControl: String, CaseIterable, Sendable {
    case archiveDrawer, archiveWindow, archiveLatest, restartListener, update, checkUpdates
    case readClipboard, readSelectionKey, microphoneEdit, selectRecognizer, loadRecognizer
    case unloadRecognizer, downloadRecognizer, cancelDownload, requestDelete, confirmDelete
    case cloneStart, cloneRestart, cloneStop, preview, historyPlay
    case record, recordingHold, recordingPause, stop, cancel, pairedRelease
    case pausePlayback, resumePlayback, previousRead, nextRead, replay, seek
    case hide, show, navigate, copy, dictionaryEdit, dictionaryCommit, quit
}

/// Gate normalization preserves OPEN/DRAINING and diagnosed UNKNOWN fail-open voice policy.
public enum ControlVoiceGate: Sendable { case open, draining, prepared, committed, unknown
    public var permitsNewVoice: Bool { self != .prepared && self != .committed }
}

/// Operation-specific input, including callback/data/AX eligibility supplied by each actual surface.
/// `ownerReason` carries extra existing owner constraints, not a replacement for final admission.
public struct ControlAvailabilityFacts: Sendable {
    public var visible = true, callbackAvailable = false, dataAvailable = true
    public var connected = false, gate = ControlVoiceGate.unknown
    public var capturing = false, unfinished = false, draining = false, queued = false
    public var capable = false, agentAsk = false, hidden = false, nativeIdle = true
    public var gesture = false, pending = false, selectedHealthy = false, transitioning = false
    public var foreignOwner = false, targetEligible = true, neighborAvailable = true
    public var timingAvailable = true, identityCurrent = true, readOnly = false
    public var ownerReason: String?
    public init() {}
}

/// Required policy from the existing formal contract; conservative proposals stay with the lead.
public enum VoiceControlAvailability {
    public static func evaluate(_ control: VoiceControl, _ f: ControlAvailabilityFacts) -> ControlAvailability {
        guard f.visible else { return .init(.hidden) }
        // Emergency/paired intents remain reachable through gate, pending ACK and disconnect.
        // The existing owner still resolves the take, locked release and local retention mechanics.
        if [.stop, .cancel, .pairedRelease].contains(control) { return .init(.available) }
        guard f.callbackAvailable else { return .init(.unavailable("This action is unavailable")) }
        let reason = refusal(control, f)
        if let reason {
            return .init(control == .readSelectionKey || control == .requestDelete || control == .quit
                ? .explain(reason) : .unavailable(reason))
        }
        return .init(.available)
    }

    private static func refusal(_ c: VoiceControl, _ f: ControlAvailabilityFacts) -> String? {
        if [.navigate, .show, .checkUpdates, .copy].contains(c) {
            return f.dataAvailable ? f.ownerReason : "Nothing available"
        }
        if c == .hide { return f.unfinished ? "Finish or cancel this take before hiding VoiceBar." : f.ownerReason }
        if c == .microphoneEdit {
            return f.capturing ? "Finish recording to change microphones"
                : !f.targetEligible ? "No microphone move is available" : f.ownerReason
        }
        if c == .restartListener {
            return f.capturing || f.gesture ? "Finish recording or release F5 before restarting the listener" : f.ownerReason
        }
        if c == .update {
            return f.unfinished || !f.nativeIdle || f.gesture ? "Finish the active operation before updating"
                : f.pending ? "An update operation is in progress" : f.ownerReason
        }
        if [.cloneStart, .cloneRestart, .cloneStop].contains(c) {
            if c != .cloneStart && f.capturing { return "Finish recording to change the clone engine" }
            if f.pending || f.transitioning { return "Waiting for the clone engine" }
            if c != .cloneStart && f.foreignOwner { return "Another process owns this engine" }
            return f.ownerReason // Start/speech restrictions remain unresolved proposals.
        }
        if c == .dictionaryEdit { return f.readOnly ? "Included terms are read-only" : f.ownerReason }
        if c == .requestDelete { return f.ownerReason } // Explain-or-confirm stays actionable.
        if c == .quit { return f.ownerReason } // Preserve save/lease policy; no new Quit disable.
        if c == .historyPlay { // Local player does not depend on the daemon connection.
            if !f.gate.permitsNewVoice { return "An update owns VoiceBar" }
        } else if !f.connected { return "VoiceLayer is disconnected" }
        if !f.identityCurrent { return "This operation is no longer current" }
        if c == .cancelDownload { return f.ownerReason } // Cancellation bypasses new-media gating.
        if ![.recordingHold, .recordingPause, .pausePlayback, .dictionaryCommit].contains(c), !f.gate.permitsNewVoice {
            return "An update owns VoiceBar"
        }
        if f.pending { return "Waiting for acknowledgement" }
        if !f.dataAvailable { return "Required data is unavailable" }
        if [.recordingHold, .recordingPause].contains(c) {
            return f.capturing ? f.ownerReason : "No live recording"
        }
        if c == .record {
            if f.hidden { return "Show VoiceBar before recording" }
            if f.agentAsk { return "An agent Ask owns the microphone" }
            if f.queued { return "The next recording is already queued" }
            if f.capturing && !f.draining { return "A recording owns the microphone" }
            return f.unfinished && !f.capable ? "This connection cannot queue another recording" : f.ownerReason
        }
        if c == .pausePlayback || c == .dictionaryCommit { return f.ownerReason }
        if c == .previousRead && !f.neighborAvailable { return "No previous read in this queue" }
        if c == .nextRead && !f.neighborAvailable { return "Nothing queued after this read" }
        if c == .seek && !f.timingAvailable { return "Word timing unavailable" }
        if f.capturing { return "Finish recording before this action" }
        if [.archiveDrawer, .archiveWindow, .archiveLatest, .selectRecognizer, .loadRecognizer, .unloadRecognizer,
             .preview, .historyPlay, .readClipboard, .readSelectionKey].contains(c), f.unfinished {
            return "Finish or cancel the current take and re-transcription first"
        }
        if [.archiveDrawer, .archiveWindow, .archiveLatest].contains(c), !f.nativeIdle || f.agentAsk {
            return "Finish speech or Ask before re-transcribing"
        }
        if [.selectRecognizer, .loadRecognizer, .unloadRecognizer].contains(c), f.transitioning {
            return "Wait for the recognizer transition"
        }
        if c == .selectRecognizer && f.selectedHealthy { return "Already selected and healthy" }
        return f.ownerReason
    }
}
