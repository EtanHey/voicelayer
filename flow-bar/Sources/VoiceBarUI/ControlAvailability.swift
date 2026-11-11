import Foundation

// L4 → L5 control-availability contract. Rules follow `formal/control-availability` (model 4bf20052,
// vendored at docs/control-availability/model/ControlAvailability.tla). Every rule reads typed phases;
// no surface passes a loose busy/unfinished flag. Handlers still re-check after their final await.

// MARK: - Result

public struct ControlAvailability: Equatable, Sendable {
    public enum Outcome: Equatable, Sendable {
        case available
        case unavailable(String)
        /// An accepted intent that explains instead of acting (Option+F5 selection key). Not proof of media.
        case explain(String)
        case hidden
        /// Contract fault: the surface renders the control without a handler. Never a working-looking button.
        case unwired
    }

    public static let unwiredReason = "VoiceBar did not connect this control"
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
    public var isContractFault: Bool { outcome == .unwired }
    public var reason: String? {
        switch outcome {
        case .unavailable(let text), .explain(let text): text
        case .unwired: Self.unwiredReason
        case .available, .hidden: nil
        }
    }
    /// Attach to native hover (PillControlTooltip in the notch panel) AND accessibility.
    public var tooltip: String? { reason }
    public var accessibilityHint: String? { reason }
}

// MARK: - Facts (the model's phases; impossible combinations are not expressible)

/// Update-gate admission. DRAINING and a diagnosed UNKNOWN admit voice; healthy PREPARED/COMMITTED refuse.
/// Never `kind != OPEN`. There is no default: every surface passes the gate it read.
public enum ControlVoiceGate: Equatable, Sendable, CaseIterable {
    case open, draining, prepared, committed, unknownFailOpen

    /// Ledger `kind` from update-gate.json. A missing or unreadable kind is the existing fail-open policy.
    public init(ledgerKind: String?) {
        switch ledgerKind {
        case "OPEN": self = .open
        case "DRAINING": self = .draining
        case "PREPARED": self = .prepared
        case "COMMITTED": self = .committed
        default: self = .unknownFailOpen
        }
    }

    /// `NativeUpdateGate.permitsNewVoice()` is the read the app has today: true covers OPEN, DRAINING and
    /// UNKNOWN; false is a healthy PREPARED/COMMITTED ledger.
    public init(permitsNewVoice: Bool) { self = permitsNewVoice ? .open : .committed }

    public var admitsNewVoice: Bool { self != .prepared && self != .committed }
}

public enum ControlConnection: Equatable, Sendable {
    case disconnected
    /// `canQueueRecording`: the daemon supports recording jobs, so a fresh take may start over older work.
    case connected(canQueueRecording: Bool)
}

public enum RecordingKind: Equatable, Sendable, CaseIterable { case pushToTalk, vad }

/// Who holds the microphone. Model `phase` minus `transcribing` (which is `ProcessingWork.transcription`).
public enum CapturePhase: Equatable, Sendable {
    case none
    /// Admission reserved (record intent sent, handoff, deferred take, reserved mic) before live PCM.
    /// The foreground mode may still read idle here: this is where the resume/previous owner races live.
    case reservedOpening
    case capturing(RecordingKind)
    /// True PTT pause: the take is unfinished and still owns the microphone.
    case paused
    /// Recorder exit / archive drain. A successor can only be queued behind a drain.
    case draining(successorQueued: Bool)
    /// An agent Ask owns the microphone (opening through recorder exit).
    case askCapturing

    public static let allCases: [CapturePhase] = [.none, .reservedOpening, .capturing(.pushToTalk), .capturing(.vad),
                                                  .paused, .draining(successorQueued: false),
                                                  .draining(successorQueued: true), .askCapturing]
}

/// Unfinished work that no longer holds the microphone. Any combination can be true at once.
public struct ProcessingWork: OptionSet, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    /// A dictation take (foreground or older) is being transcribed.
    public static let transcription = ProcessingWork(rawValue: 1)
    /// A History re-transcription job, including the idle-before-dispatch request.
    public static let historyRetranscription = ProcessingWork(rawValue: 2)
    /// An agent Ask's answer is being transcribed after its recorder exited.
    public static let askAnswer = ProcessingWork(rawValue: 4)
}

public enum PlaybackPhase: Equatable, Sendable, CaseIterable {
    case none
    case preparing
    /// A read, a previous-read replay or History audio is audible.
    case playing
    case paused
    /// A finished read stays on screen with no live audio.
    case readback
    /// An agent Ask's prompt is speaking.
    case askSpeaking
}

public enum DrawerState: Equatable, Sendable, CaseIterable { case none, history, settings }

public struct PresentationFacts: Equatable, Sendable {
    public var hidden: Bool, drawer: DrawerState, modal: Bool
    public init(hidden: Bool, drawer: DrawerState, modal: Bool) {
        self.hidden = hidden; self.drawer = drawer; self.modal = modal
    }
}

/// Status of the daemon settings service (Models/Processing), read from `ModelsSettingsState`.
public enum SettingsService: Equatable, Sendable {
    case ready
    case busy(String)
    case unavailable(String)
}

public enum SpeechSettingKey: String, Equatable, Hashable, Sendable, CaseIterable {
    case shortProfile, longProfile, longTextThreshold
}

/// One pending acknowledgement per operation. A rule reads only its own operation's pending.
public enum PendingOperation: Hashable, Sendable {
    case recordingHold, recordingPause
    case update, updateCheck
    case clone
    /// A recognizer select/load/unload/download/delete in flight: the model's `transition`.
    case recognizerMutation
    case processing(ProcessingKey)
    case speech(SpeechSettingKey)
    case speechPreview
    case dictionaryCommit
    case shortcutCheck
}

public struct ControlFacts: Equatable, Sendable {
    public var connection: ControlConnection
    public var gate: ControlVoiceGate
    public var capture: CapturePhase
    public var processing: ProcessingWork
    public var playback: PlaybackPhase
    public var presentation: PresentationFacts
    /// `VoiceMode.error` is showing.
    public var voiceError: Bool
    /// A physical F5/side-button gesture is outstanding (`hotkeyPhase != .idle`).
    public var physicalGesture: Bool
    public var settingsService: SettingsService
    public var pending: Set<PendingOperation>

    /// Every fact is required: there is no silent default for the gate or any phase.
    public init(connection: ControlConnection, gate: ControlVoiceGate, capture: CapturePhase,
                processing: ProcessingWork, playback: PlaybackPhase, presentation: PresentationFacts,
                voiceError: Bool, physicalGesture: Bool, settingsService: SettingsService,
                pending: Set<PendingOperation>) {
        self.connection = connection; self.gate = gate; self.capture = capture
        self.processing = processing; self.playback = playback; self.presentation = presentation
        self.voiceError = voiceError; self.physicalGesture = physicalGesture
        self.settingsService = settingsService; self.pending = pending
    }

    public var isConnected: Bool { connection != .disconnected }
    /// Model `Capturing`: opening, open or paused (an Ask capture included). Draining is not capturing.
    public var ownsMicrophone: Bool {
        switch capture {
        case .reservedOpening, .capturing, .paused, .askCapturing: true
        case .none, .draining: false
        }
    }
    /// Model `Unfinished`: any capture phase, queued successor, transcription or History job.
    public var hasUnfinishedTake: Bool { capture != .none || !processing.isEmpty }
    public var agentAsk: Bool {
        capture == .askCapturing || playback == .askSpeaking || processing.contains(.askAnswer)
    }
    /// Model `Speech`: audible or resumable speech. A readback has no live audio.
    public var speech: Bool {
        switch playback {
        case .preparing, .playing, .paused, .askSpeaking: true
        case .none, .readback: false
        }
    }
    public var successorQueued: Bool { capture == .draining(successorQueued: true) }
    /// Model `Mode(x) = "idle"`.
    public var voiceIdle: Bool { !voiceError && isConnected && !hasUnfinishedTake && !speech }
    /// Model `DrawerAllowed`.
    public var drawerAllowed: Bool {
        !presentation.hidden && !presentation.modal && !agentAsk && !speech
    }
}

// MARK: - Controls (every visible control has a case)

public enum ArchiveSurface: String, Equatable, Hashable, Sendable, CaseIterable { case drawer, window, latest }
public enum MicrophoneEdit: String, Equatable, Hashable, Sendable, CaseIterable {
    case makeDefault, reorder, move, visibleFirst
}

public struct RecognizerRow: Equatable, Hashable, Sendable {
    public enum Selection: Equatable, Hashable, Sendable, CaseIterable { case selectedHealthy, other, retry }
    public var selection: Selection, assetsPresent: Bool, resident: Bool, downloading: Bool
    public init(selection: Selection, assetsPresent: Bool, resident: Bool, downloading: Bool) {
        self.selection = selection; self.assetsPresent = assetsPresent
        self.resident = resident; self.downloading = downloading
    }
}

public enum RecognizerAction: String, Equatable, Hashable, Sendable, CaseIterable {
    case select
    /// The Load button on a row that is NOT selected: `VoiceState.manageRecognizer` turns it into a select,
    /// so it shows where Load shows and follows Select's rules.
    case loadAndSelect
    case load, unload, download, cancelDownload, requestDelete, confirmDelete
}

public struct CloneEngineFacts: Equatable, Hashable, Sendable {
    public enum Lifecycle: Equatable, Hashable, Sendable, CaseIterable { case stopped, running, transitioning }
    public var lifecycle: Lifecycle, foreignOwner: Bool
    public init(lifecycle: Lifecycle, foreignOwner: Bool) { self.lifecycle = lifecycle; self.foreignOwner = foreignOwner }
}

public enum CloneAction: String, Equatable, Hashable, Sendable, CaseIterable { case start, restart, stop }

public enum VoiceControl: Equatable, Hashable, Sendable {
    // Capture owner
    case record
    /// Take-scoped stop (F5/side button, notch Stop recording). Never a bare speech stop.
    case stopRecording
    case cancel
    case pairedRelease
    case recordingHold
    case recordingPause
    // Speech and playback
    /// `scope:"speech"` stop: reads, an Ask's prompt, History audio. Never ends a take.
    case stopSpeaking
    case pausePlayback, resumePlayback, replay, seek
    case previousRead(available: Bool)
    case nextRead(queued: Bool)
    case speedChip
    case readClipboard
    case readSelectionKey
    case preview(SpeechProfile)
    case historyPlay(audio: Bool)
    // History and transcripts
    case retranscribe(ArchiveSurface, audio: Bool)
    case historyCopy, historyPaste, historyReveal, historyNavigate
    case copyLastTranscript, pasteLastTranscript
    // Presentation and local navigation
    case hide, show, openHistory, openSettings, closeDrawer
    case drawerTab(SettingsTab)
    case windowTab(SettingsTab)
    case dismissTeleprompter, showTeleprompter, dismissError
    case chooseMicrophone
    case checkUpdates
    // Settings
    case microphone(MicrophoneEdit, eligible: Bool)
    case restartListener
    case checkShortcut
    case permissionFix
    case update
    /// `lockedBy`: the environment variable that overrides the saved value, if set.
    case processingToggle(ProcessingKey, lockedBy: String?)
    case speechSetting(SpeechSettingKey)
    case dictionaryEdit(readOnly: Bool)
    case dictionaryCommit
    case recognizer(RecognizerAction, RecognizerRow)
    case clone(CloneAction, CloneEngineFacts)
    case quit

    /// The one pending acknowledgement this control waits on, if any.
    public var pendingOperation: PendingOperation? {
        switch self {
        case .recordingHold: .recordingHold
        case .recordingPause: .recordingPause
        case .update: .update
        case .checkUpdates: .updateCheck
        case .clone: .clone
        case .recognizer(let action, _) where action != .cancelDownload && action != .requestDelete: .recognizerMutation
        case .processingToggle(let key, _): .processing(key)
        case .speechSetting(let key): .speech(key)
        case .preview: .speechPreview
        case .dictionaryCommit: .dictionaryCommit
        case .checkShortcut: .shortcutCheck
        default: nil
        }
    }

    /// Local navigation: visible ⇒ enabled, whatever the take, gate, connection or pending state.
    public var isLocalNavigation: Bool {
        switch self {
        case .show, .openHistory, .openSettings, .closeDrawer, .drawerTab, .windowTab, .dismissTeleprompter,
             .showTeleprompter, .dismissError, .chooseMicrophone, .checkUpdates, .historyCopy, .historyNavigate,
             .historyReveal, .copyLastTranscript, .permissionFix:
            true
        default: false
        }
    }
}

// MARK: - Policy

public enum VoiceControlAvailability {
    public static let disconnected = "VoiceLayer is disconnected"
    public static let updateOwns = "An update owns VoiceBar"
    public static let answeringQuestion = "Answering a question"
    public static let noUnfinishedTake = "No unfinished take"
    public static let nothingSpeaking = "Nothing is speaking"
    public static let waitingForAcknowledgement = "Waiting for acknowledgement"

    /// `handlerInstalled` is required: a rendered control with no handler is reported as a contract fault.
    public static func evaluate(_ control: VoiceControl, _ facts: ControlFacts,
                                handlerInstalled: Bool) -> ControlAvailability {
        guard isVisible(control, facts) else { return .init(.hidden) }
        guard handlerInstalled else { return .init(.unwired) }
        if control == .readSelectionKey {
            return .init(selectionRefusal(facts).map(ControlAvailability.Outcome.explain) ?? .available)
        }
        if control.isLocalNavigation { return .init(.available) }
        return .init(refusal(control, facts).map(ControlAvailability.Outcome.unavailable) ?? .available)
    }

    /// Model `Visible`, plus the contract's always-visible emergency/stop-speaking controls (disabled with a
    /// reason when there is nothing to stop). Controls the model leaves to the surface stay visible.
    static func isVisible(_ c: VoiceControl, _ f: ControlFacts) -> Bool {
        let modal = f.presentation.modal, hidden = f.presentation.hidden
        switch c {
        case .retranscribe(.drawer, let audio): return audio && f.presentation.drawer == .history && f.drawerAllowed
        case .retranscribe(_, let audio), .historyPlay(let audio): return audio && !modal
        case .stopRecording, .cancel, .pairedRelease, .stopSpeaking, .record, .readSelectionKey: return true
        case .hide: return !hidden && !modal
        case .show: return hidden
        case .drawerTab: return f.presentation.drawer == .settings && f.drawerAllowed
        case .closeDrawer: return f.presentation.drawer != .none && !hidden
        case .openHistory, .openSettings: return f.drawerAllowed
        case .clone(.start, let e): return e.lifecycle == .stopped && !modal
        case .clone(_, let e): return e.lifecycle == .running && !modal
        case .recognizer(let action, let row):
            switch action {
            case .cancelDownload: return row.downloading && !modal
            case .download: return !row.assetsPresent && !modal
            case .load, .loadAndSelect: return row.assetsPresent && !row.resident && !modal
            case .unload: return row.assetsPresent && row.resident && !modal
            case .requestDelete, .confirmDelete: return row.assetsPresent && !modal
            case .select: return !modal
            }
        case .pausePlayback, .resumePlayback, .previousRead, .nextRead, .replay, .seek, .speedChip:
            return f.playback != .none && !hidden && !modal
        default: return !modal
        }
    }

    /// Option+F5 always delivers; this is the explanation when it cannot read. Model `SelectionReason`.
    static func selectionRefusal(_ f: ControlFacts) -> String? {
        if !f.isConnected { return disconnected }
        if !f.gate.admitsNewVoice { return updateOwns }
        if f.agentAsk { return answeringQuestion }
        if f.hasUnfinishedTake { return "Finish capture or transcription before reading" }
        return nil
    }

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    static func refusal(_ c: VoiceControl, _ f: ControlFacts) -> String? {
        let pending = c.pendingOperation.map { f.pending.contains($0) } ?? false
        switch c {
        // Emergency: reachable through gate, modal, hidden, pending and disconnection whenever a take exists.
        case .stopRecording, .cancel, .pairedRelease:
            return f.hasUnfinishedTake ? nil : noUnfinishedTake
        case .stopSpeaking:
            return f.speech ? nil : nothingSpeaking

        case .record:
            if !f.isConnected { return disconnected }
            if f.presentation.hidden { return "Show VoiceBar before recording" }
            if !f.gate.admitsNewVoice { return updateOwns }
            if f.agentAsk { return "An agent Ask owns the microphone" }
            if f.successorQueued { return "The next recording is already queued" }
            if f.ownsMicrophone { return "A recording owns the microphone" }
            if f.hasUnfinishedTake, f.connection == .connected(canQueueRecording: false) {
                return "This connection cannot queue another recording"
            }
            return nil

        case .recordingHold, .recordingPause:
            if !f.isConnected { return disconnected }
            if pending { return waitingForAcknowledgement }
            switch (c, f.capture) {
            case (.recordingHold, .capturing(.vad)), (.recordingPause, .capturing(.pushToTalk)),
                 (.recordingPause, .paused):
                return nil
            case (.recordingHold, .capturing(.pushToTalk)), (.recordingHold, .paused):
                return "Hold needs a voice-activated recording"
            case (.recordingPause, .capturing(.vad)): return "Pause needs push-to-talk"
            default: return "No live recording"
            }

        case .readClipboard, .preview, .historyPlay:
            if !f.isConnected, !isHistoryPlay(c) { return disconnected }
            if !f.gate.admitsNewVoice { return updateOwns }
            if f.agentAsk { return answeringQuestion }
            if f.hasUnfinishedTake { return "Finish capture or transcription before reading" }
            if c != .readClipboard, f.speech { return "Finish the current playback first" }
            if pending { return "Preview in progress…" }
            return nil

        case .pausePlayback, .resumePlayback, .previousRead, .nextRead, .replay, .seek:
            // Model rule minus the conservative transcription-only block (CONFORMANCE proposal, lead-owned):
            // any capture phase, draining included, blocks new playback; transcription alone does not.
            if c != .pausePlayback, f.capture != .none { return "Finish capture or transcription before playback" }
            if !f.isConnected { return disconnected }
            if c != .pausePlayback, !f.gate.admitsNewVoice { return updateOwns }
            switch c {
            case .previousRead(false): return "No previous read in this queue"
            case .nextRead(false): return "Nothing queued"
            case .resumePlayback where f.playback != .paused: return "Playback is not paused"
            case .pausePlayback where !f.speech: return "No live playback to pause"
            case .seek where f.playback == .preparing: return "Preparing audio; seeking is not ready"
            default: return nil
            }
        case .speedChip:
            return f.isConnected ? nil : disconnected

        case .retranscribe:
            if !f.isConnected { return disconnected }
            if !f.gate.admitsNewVoice { return updateOwns }
            if f.hasUnfinishedTake { return "Finish or cancel the current take and re-transcription first" }
            if f.speech || f.agentAsk { return "Finish speech or Ask before re-transcribing" }
            if !f.voiceIdle { return "Recover VoiceBar before re-transcribing" }
            return nil
        case .historyPaste, .pasteLastTranscript:
            return nil // Local insertion of immutable text; the handler validates non-empty text and target.

        case .hide:
            return f.hasUnfinishedTake ? "Finish or cancel this take before hiding VoiceBar" : nil

        case .microphone(_, let eligible):
            if f.ownsMicrophone { return "Finish recording to change microphones" }
            return eligible ? nil : "No microphone move is available"
        case .restartListener:
            return f.ownsMicrophone || f.physicalGesture
                ? "Finish recording or release F5 before restarting the listener" : nil
        case .checkShortcut:
            return pending ? "Checking the shortcut…" : nil
        case .update:
            // Model order; the closed-gate refusal is a CONFORMANCE proposal and stays with the lead.
            if pending { return "An update operation is in progress" }
            if f.hasUnfinishedTake || !f.voiceIdle || f.physicalGesture { return "Finish the active operation before updating" }
            return nil

        case .processingToggle(_, let lockedBy):
            if let lockedBy { return "Set by \(lockedBy)" }
            if !f.isConnected { return disconnected }
            if let reason = settingsServiceRefusal(f.settingsService) { return reason }
            return pending ? "Saving…" : nil
        case .speechSetting:
            if !f.isConnected { return disconnected }
            return pending ? "Saving speech settings…" : nil
        case .dictionaryEdit(let readOnly):
            return readOnly ? "Included terms are read-only" : nil
        case .dictionaryCommit:
            if !f.isConnected { return disconnected }
            return pending ? waitingForAcknowledgement : nil

        case .recognizer(let action, let row):
            return recognizerRefusal(action, row, f, transition: f.pending.contains(.recognizerMutation))
        case .clone(let action, let engine):
            // Model rule minus the Start capture lock and the speech lock (CONFORMANCE proposals, lead-owned).
            if action != .start, f.ownsMicrophone { return "Finish recording to change the clone engine" }
            if pending { return "Waiting for the clone engine" }
            if action != .start, engine.foreignOwner { return "Another process owns this engine" }
            return nil
        case .quit:
            return nil // Closed-gate Quit disable is a CONFORMANCE proposal; termination keeps its own policy.

        case .readSelectionKey, .show, .openHistory, .openSettings, .closeDrawer, .drawerTab, .windowTab,
             .dismissTeleprompter, .showTeleprompter, .dismissError, .chooseMicrophone, .checkUpdates,
             .historyCopy, .historyNavigate, .historyReveal, .copyLastTranscript, .permissionFix:
            return nil
        }
    }

    private static func isHistoryPlay(_ c: VoiceControl) -> Bool {
        if case .historyPlay = c { return true }
        return false
    }

    private static func settingsServiceRefusal(_ service: SettingsService) -> String? {
        switch service {
        case .ready: nil
        case .busy(let reason), .unavailable(let reason): reason
        }
    }

    private static func recognizerRefusal(_ action: RecognizerAction, _ row: RecognizerRow, _ f: ControlFacts,
                                          transition: Bool) -> String? {
        switch action {
        case .cancelDownload, .requestDelete: return nil // Cancellation works disconnected; Delete explains or confirms.
        default: break
        }
        if !f.isConnected { return disconnected }
        if !f.gate.admitsNewVoice { return updateOwns }
        // The unfinished-take lock on Download and ConfirmDelete is a CONFORMANCE proposal (lead-owned).
        if f.hasUnfinishedTake, action != .download, action != .confirmDelete {
            return "Finish the current take before changing recognizers"
        }
        if transition { return "Wait for the recognizer transition" }
        switch action {
        case .select, .loadAndSelect:
            if row.selection == .selectedHealthy { return "Already selected and healthy" }
            if !row.assetsPresent { return "Download this recognizer first" }
        case .confirmDelete where row.selection != .other || row.resident:
            return "Choose another recognizer and unload this model first"
        default: break
        }
        return nil
    }
}
