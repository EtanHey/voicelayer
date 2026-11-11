import Foundation

/// Values read from `VoiceState` (and the app's presentation/gate owners) at one instant. Plain values only, so
/// the adapter stays a pure function and lanes editing VoiceState admission never have to edit it.
public struct VoiceStateReading: Equatable {
    /// Mirrors `VoiceState.CaptureAdmissionPhase` (lane L4b): opening covers the unacknowledged record intent,
    /// handoff, deferred take and reserved microphone before live PCM; capturing requires `captureLive`.
    public enum CaptureAdmission: String, Equatable, Sendable, CaseIterable { case idle, opening, capturing, draining }
    /// An agent Ask outside its capture. VoiceState has no public read for this at 9b8a83ef; the owner lane adds one.
    public enum AgentAskSession: Equatable, Sendable, CaseIterable { case none, speaking, answering }

    public var mode: VoiceMode
    public var isConnected: Bool
    /// `ControlVoiceGate(permitsNewVoice: NativeUpdateGate.permitsNewVoice())` or a ledger kind.
    public var gate: ControlVoiceGate
    public var captureAdmission: CaptureAdmission
    /// `VoiceState.recordingMode`: "vad" or "ptt".
    public var recordingMode: String?
    public var isRecordingPaused: Bool
    /// `VoiceState.isAskCapture`.
    public var isAskCapture: Bool
    public var agentAskSession: AgentAskSession
    public var hasQueuedRecording: Bool
    public var processingTakeCount: Int
    public var isHistoryRetranscriptionPending: Bool
    /// `VoiceState.supportsRecordingJobs`.
    public var supportsRecordingJobs: Bool
    public var isPlaybackPreparing: Bool
    public var isPlaybackPaused: Bool
    public var isTeleprompterReadback: Bool
    /// `historyPlayback.playingURL != nil`: the History player's OWN clip, independent of external admission.
    public var isHistoryPlaybackActive: Bool
    /// `historyPlayback.isVoiceBusy`: external voice owners or the player's `canPlay` admission refusal.
    public var isHistoryVoiceBusy: Bool
    public var isHidden: Bool
    public var drawer: DrawerState
    public var isModalPresented: Bool
    public var hotkeyPhase: HotkeyPhase
    public var modelsSettings: SettingsService
    public var pending: Set<PendingOperation>

    public init(mode: VoiceMode, isConnected: Bool, gate: ControlVoiceGate, captureAdmission: CaptureAdmission,
                recordingMode: String?, isRecordingPaused: Bool, isAskCapture: Bool,
                agentAskSession: AgentAskSession, hasQueuedRecording: Bool, processingTakeCount: Int,
                isHistoryRetranscriptionPending: Bool, supportsRecordingJobs: Bool, isPlaybackPreparing: Bool,
                isPlaybackPaused: Bool, isTeleprompterReadback: Bool, isHistoryPlaybackActive: Bool,
                isHistoryVoiceBusy: Bool,
                isHidden: Bool, drawer: DrawerState, isModalPresented: Bool, hotkeyPhase: HotkeyPhase,
                modelsSettings: SettingsService, pending: Set<PendingOperation>) {
        self.mode = mode; self.isConnected = isConnected; self.gate = gate
        self.captureAdmission = captureAdmission; self.recordingMode = recordingMode
        self.isRecordingPaused = isRecordingPaused; self.isAskCapture = isAskCapture
        self.agentAskSession = agentAskSession; self.hasQueuedRecording = hasQueuedRecording
        self.processingTakeCount = processingTakeCount
        self.isHistoryRetranscriptionPending = isHistoryRetranscriptionPending
        self.supportsRecordingJobs = supportsRecordingJobs; self.isPlaybackPreparing = isPlaybackPreparing
        self.isPlaybackPaused = isPlaybackPaused; self.isTeleprompterReadback = isTeleprompterReadback
        self.isHistoryPlaybackActive = isHistoryPlaybackActive; self.isHistoryVoiceBusy = isHistoryVoiceBusy
        self.isHidden = isHidden; self.drawer = drawer
        self.isModalPresented = isModalPresented; self.hotkeyPhase = hotkeyPhase
        self.modelsSettings = modelsSettings; self.pending = pending
    }
}

/// The one adapter from app state to `ControlFacts`. Every surface calls this; none re-derives phases.
public enum ControlAvailabilityAdapter {
    /// Read both independent facts from the actual History player in the same actor turn.
    /// L5 uses this overload when the surface owns a player; it never derives playback from `isVoiceBusy`.
    @MainActor
    public static func facts(_ reading: VoiceStateReading, historyPlayback: SettingsAudioPlayback) -> ControlFacts {
        var r = reading
        r.isHistoryPlaybackActive = historyPlayback.playingURL != nil
        r.isHistoryVoiceBusy = historyPlayback.isVoiceBusy
        return facts(r)
    }

    public static func facts(_ r: VoiceStateReading) -> ControlFacts {
        ControlFacts(
            connection: r.isConnected && r.mode != .disconnected
                ? .connected(canQueueRecording: r.supportsRecordingJobs) : .disconnected,
            gate: r.gate,
            capture: capture(r),
            processing: processing(r),
            playback: playback(r),
            historyVoiceBusy: r.isHistoryVoiceBusy,
            presentation: PresentationFacts(hidden: r.isHidden, drawer: r.drawer, modal: r.isModalPresented),
            voiceError: r.mode == .error,
            physicalGesture: r.hotkeyPhase != .idle,
            settingsService: r.modelsSettings,
            pending: r.pending
        )
    }

    static func capture(_ r: VoiceStateReading) -> CapturePhase {
        if r.isAskCapture { return .askCapturing }
        // A queued successor waits only behind a take that still holds the microphone or its drain.
        if r.hasQueuedRecording, r.captureAdmission != .capturing { return .draining(successorQueued: true) }
        switch r.captureAdmission {
        case .idle: return .none
        // Reserved before live PCM, even while `mode` still reads idle: the resume/previous race window.
        case .opening: return .reservedOpening
        case .capturing:
            // True pause exists only for push-to-talk takes; a stale flag on a VAD take is not a pause.
            if r.recordingMode == "vad" { return .capturing(.vad) }
            return r.isRecordingPaused ? .paused : .capturing(.pushToTalk)
        case .draining: return .draining(successorQueued: false)
        }
    }

    static func processing(_ r: VoiceStateReading) -> ProcessingWork {
        var work: ProcessingWork = []
        if r.agentAskSession == .answering { work.insert(.askAnswer) }
        if r.processingTakeCount > 0 || (r.mode == .transcribing && r.agentAskSession != .answering) {
            work.insert(.transcription)
        }
        if r.isHistoryRetranscriptionPending { work.insert(.historyRetranscription) }
        return work
    }

    static func playback(_ r: VoiceStateReading) -> PlaybackPhase {
        if r.agentAskSession == .speaking { return .askSpeaking }
        if r.isPlaybackPreparing { return .preparing }
        if r.isPlaybackPaused { return .paused }
        if r.mode == .speaking || r.isHistoryPlaybackActive { return .playing }
        if r.isTeleprompterReadback { return .readback }
        return .none
    }
}
