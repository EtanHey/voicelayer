// VoiceState.swift — Observable state model for Voice Bar.
//
// Single source of truth for all UI state. Maps socket protocol events
// (from VoiceLayer MCP server) to SwiftUI-friendly properties.
// VoiceMode values must match socket-protocol.ts VoiceLayerState.

import AppKit
import Foundation
import Observation
import SwiftUI

// MARK: - Voice mode enumeration

public enum VoiceMode: String, CaseIterable {
    case idle
    case speaking
    case recording
    case transcribing
    case error
    case disconnected
}

public struct QueueItemState: Equatable {
    public var text: String
    public var voice: String
    public var priority: String
    public var isCurrent: Bool
    public var progress: Double
}

public enum CommandModePhase: String, Equatable {
    case listening
    case capturing
    case applying
    case fallback
    case done
    case error
}

public struct CommandModeState: Equatable {
    public var phase: CommandModePhase
    public var operation: String
    public var prompt: String?
}

public struct ClipMarkerState: Equatable {
    public var id: String
    public var label: String
    public var source: String
    public var status: String
}

public struct PasteboardSnapshot: Equatable {
    public var changeCount: Int
    public var items: [[String: Data]]
}

private enum VoicePasteOutcome: Equatable {
    case insertedAtCursor
    case pasted
    case failed(String)
}

// MARK: - Observable state

@Observable
public final class VoiceState {
    private static let maxRecentTranscriptions = 8
    private static let recentTranscriptionsDefaultsKey = "VoiceBar.recentTranscriptions"
    private static let maxVocabularyTerms = 512
    private static let maxVocabularyAliases = 512

    // UI-bound properties -- all mutations must happen on the main thread.
    public var mode: VoiceMode = .idle {
        didSet { notifyPanelLayoutChangedIfNeeded(oldValue != mode) }
    }
    public var statusText: String = ""
    public var transcript: String = ""
    public var speechDetected: Bool = false
    public var isConnected: Bool = false
    public var errorMessage: String?

    // Recording metadata
    public var recordingMode: String? // "vad" or "ptt"
    public var silenceMode: String? // "quick" | "standard" | "thoughtful"

    /// Brief confirmation text shown after paste (e.g., "Pasted!").
    public var confirmationText: String? {
        didSet { notifyPanelLayoutChangedIfNeeded(oldValue != confirmationText) }
    }

    /// Keeps the post-record paste flow in one fixed panel envelope so loading,
    /// success, and failure substates crossfade instead of re-centering.
    public var keepsPasteFlowEnvelope: Bool = false {
        didSet { notifyPanelLayoutChangedIfNeeded(oldValue != keepsPasteFlowEnvelope) }
    }

    /// Real-time audio level (0.0–1.0) from RMS events.
    public var audioLevel: Double?
    private var socketAudioLevel: Double?
    private var localRecordingLevel: Double?

    /// Word boundary timestamps from TTS engine (ms offsets from audio start).
    public var wordBoundaries: [(offsetMs: Int, durationMs: Int, text: String)] = []

    /// Whether the last completed action was TTS playback (replay is valid).
    /// Set true when speaking state arrives, false when recording starts.
    public var canReplay: Bool = false

    /// Recent transcription history with the newest item first.
    public var recentTranscriptions: [String] = [] {
        didSet { notifyPanelLayoutChangedIfNeeded(oldValue.isEmpty != recentTranscriptions.isEmpty) }
    }

    /// Active STT vocabulary hints loaded from the daemon snapshot.
    public var transcriptionVocabularyTerms: [String] = [] {
        didSet { notifyPanelLayoutChangedIfNeeded(oldValue.isEmpty != transcriptionVocabularyTerms.isEmpty) }
    }
    public var transcriptionVocabularyAliases: [STTVocabularyAliasPreview] = [] {
        didSet { notifyPanelLayoutChangedIfNeeded(oldValue.isEmpty != transcriptionVocabularyAliases.isEmpty) }
    }

    /// Latest completed transcript safe for re-paste/copy actions.
    public var latestReusableTranscript: String {
        recentTranscriptions.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    /// Total queued + currently playing TTS items.
    public var queueDepth: Int = 0 {
        didSet { notifyPanelLayoutChangedIfNeeded(oldValue != queueDepth) }
    }
    public var queueItems: [QueueItemState] = [] {
        didSet { notifyPanelLayoutChangedIfNeeded(oldValue.count != queueItems.count) }
    }
    public var commandModeState: CommandModeState? {
        didSet { notifyPanelLayoutChangedIfNeeded(oldValue != commandModeState) }
    }
    public var activeClipMarker: ClipMarkerState? {
        didSet { notifyPanelLayoutChangedIfNeeded(oldValue != activeClipMarker) }
    }

    /// Global hotkey availability and live gesture hint state.
    public var hotkeyEnabled: Bool = false
    public var hotkeyPhase: HotkeyPhase = .idle {
        didSet { notifyPanelLayoutChangedIfNeeded(oldValue != hotkeyPhase) }
    }

    /// Whether the pill is collapsed (idle for too long).
    public var isCollapsed: Bool = false {
        didSet { notifyPanelLayoutChangedIfNeeded(oldValue != isCollapsed) }
    }

    /// Whether the mouse is hovering over the pill.
    public var isHovering: Bool = false

    /// Timer for idle collapse.
    private var collapseTimer: Task<Void, Never>?

    /// Tracks the last user intent sent to the daemon until the matching ack returns.
    public var pendingIntent: PendingIntent?

    /// Safety timeout for barInitiatedRecording — prevents stuck state.
    private var barInitiatedTimeout: Task<Void, Never>?
    private var transcriptionTimeoutTask: Task<Void, Never>?
    private var recordingIdleCleanupTask: Task<Void, Never>?
    private var deferredFinalTranscriptionTask: Task<Void, Never>?
    private var transcribingStartedAt: Date?
    private var pendingRecordingIdleAfterFinal = false
    private var pendingIdleAfterAutoPasteCompletion = false
    private var pendingRecoveredTranscriptionPaste = false

    /// Whether the current recording was initiated from the Voice Bar (vs MCP).
    /// When true, transcription result is auto-pasted at the cursor.
    /// Cleared after transcription, recording-idle cleanup, cancel, disconnect, or a rejected record ack.
    /// Never cleared by idle/error alone — those are ambiguous with multiple MCP clients.
    private var barInitiatedRecording = false

    /// The app that was frontmost when bar-initiated recording started.
    private var frontmostAppOnRecordStart: NSRunningApplication?
    private var recordStartInsertionHandler: ((String) -> Bool)?

    /// The most recent app we pasted into. Reused for Shift+F5 re-paste.
    private var lastPasteTargetApp: NSRunningApplication?

    /// Test seam for paste side effects. When set, bypasses system paste.
    public var pasteHandler: ((String) -> Bool)?
    public var commandModeApplyHandler: ((String) -> CommandModeApplyResult)?

    /// Delay before sending Cmd+V after activating the target app.
    public var pasteConfirmationDelay: TimeInterval = 0.25

    /// Test seam for delayed paste scheduling.
    public var pasteScheduler: (TimeInterval, @escaping () -> Void) -> Void = { delay, block in
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: block)
    }

    /// Test seam for re-activating the target app before paste.
    public var targetAppActivator: (NSRunningApplication) -> Void = { app in
        app.activate()
    }

    /// Test seam for the frontmost app at record/paste time.
    public var frontmostAppProvider: () -> NSRunningApplication? = {
        NSWorkspace.shared.frontmostApplication
    }

    /// Test seam for the final Cmd+V event posting.
    public var simulatedPasteHandler: () -> Bool = { false }

    /// Test seam for Accessibility permission checks.
    public var accessibilityTrustChecker: (_ prompt: Bool) -> Bool = { _ in false }

    /// Test seam for capturing a direct insertion closure tied to the focused input.
    public var dictationInsertionHandlerProvider: () -> ((String) -> Bool)? = { nil }

    /// Test seam for clipboard writes used by fallback paste.
    public var pasteboardWriter: (String) -> Void = { string in
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
    }
    public var pasteboardSnapshotter: () -> PasteboardSnapshot? = {
        VoiceState.capturePasteboardSnapshot()
    }
    public var pasteboardSnapshotRestorer: (PasteboardSnapshot) -> Void = { snapshot in
        VoiceState.restorePasteboardSnapshot(snapshot)
    }
    public var pasteboardChangeCountProvider: () -> Int = {
        NSPasteboard.general.changeCount
    }
    public var currentDateProvider: () -> Date = {
        Date()
    }
    public var pasteboardRestoreDelay: TimeInterval = 0.2

    private let recentTranscriptionsSaver: ([String]) -> Void
    private let transcriptionVocabularyLoader: () -> [String]
    private let transcriptionVocabularyAliasLoader: () -> [STTVocabularyAliasPreview]

    /// Transport-layer hook injected by AppDelegate.
    /// BarView calls stop()/toggle()/replay() which forward through this closure.
    public var sendCommand: (([String: Any]) -> Void)?

    /// Callback when the pill's rendered size changes — used to resize the NSPanel.
    public var onPillSizeChange: ((CGSize) -> Void)?

    /// Callback when socket connection state changes — used to suspend/resume polling.
    public var onConnectionChange: ((Bool) -> Void)?

    /// Callback when voice mode changes — used to lock/unlock pill dragging.
    public var onModeChange: ((VoiceMode) -> Void)?
    public var onPanelLayoutChange: (() -> Void)?
    public var diagnosticLogger: ((String, [String: String]) -> Void)?
    public var transcriptionTimeout: Duration = .seconds(30)
    public var barInitiatedTranscriptionTimeout: Duration = .seconds(900)
    public var barInitiatedSafetyTimeout: Duration = .seconds(3660)
    public var recordingIdleFinalTranscriptGrace: Duration = .seconds(2)
    public var minimumTranscribingDisplayDuration: TimeInterval = 0.65

    public init(
        recentTranscriptionsLoader: @escaping () -> [String] = {
            VoiceState.loadRecentTranscriptions()
        },
        recentTranscriptionsSaver: @escaping ([String]) -> Void = {
            VoiceState.saveRecentTranscriptions($0)
        },
        transcriptionVocabularyLoader: @escaping () -> [String] = { [] },
        transcriptionVocabularyAliasLoader: @escaping () -> [STTVocabularyAliasPreview] = { [] }
    ) {
        self.recentTranscriptionsSaver = recentTranscriptionsSaver
        self.transcriptionVocabularyLoader = transcriptionVocabularyLoader
        self.transcriptionVocabularyAliasLoader = transcriptionVocabularyAliasLoader
        recentTranscriptions = Self.normalizeRecentTranscriptions(recentTranscriptionsLoader())
        self.transcriptionVocabularyTerms = Self.normalizeVocabularyTerms(transcriptionVocabularyLoader())
        self.transcriptionVocabularyAliases = Self.normalizeVocabularyAliases(
            transcriptionVocabularyAliasLoader()
        )
    }

    // MARK: - Commands

    public func stop() {
        let shouldShowTranscribing = mode == .recording
        sendIntent(command: .stop, payload: ["cmd": "stop"])
        if shouldShowTranscribing {
            enterTranscribingMode()
        }
    }

    public func dismissError() {
        pendingIntent = nil
        errorMessage = nil
        deferredFinalTranscriptionTask?.cancel()
        pendingRecordingIdleAfterFinal = false
        pendingIdleAfterAutoPasteCompletion = false
        pendingRecoveredTranscriptionPaste = false
        keepsPasteFlowEnvelope = false
        transcribingStartedAt = nil
        frontmostAppOnRecordStart = nil
        recordStartInsertionHandler = nil
        speechDetected = false
        recordingMode = nil
        silenceMode = nil
        resetAudioLevels()

        if isConnected {
            mode = .idle
            onModeChange?(.idle)
            startCollapseTimer()
        } else {
            mode = .disconnected
            onModeChange?(.disconnected)
            collapseTimer?.cancel()
            isCollapsed = false
        }
    }

    public func cancel() {
        barInitiatedRecording = false
        barInitiatedTimeout?.cancel()
        transcriptionTimeoutTask?.cancel()
        recordingIdleCleanupTask?.cancel()
        deferredFinalTranscriptionTask?.cancel()
        pendingRecordingIdleAfterFinal = false
        pendingIdleAfterAutoPasteCompletion = false
        pendingRecoveredTranscriptionPaste = false
        keepsPasteFlowEnvelope = false
        transcribingStartedAt = nil
        frontmostAppOnRecordStart = nil
        recordStartInsertionHandler = nil
        speechDetected = false
        resetAudioLevels()
        hotkeyPhase = .idle
        statusText = ""
        sendIntent(command: .cancel, payload: ["cmd": "cancel"])
        if mode == .recording || mode == .transcribing || mode == .speaking {
            mode = isConnected ? .idle : .disconnected
            onModeChange?(mode)
            if mode == .idle {
                startCollapseTimer()
            } else {
                collapseTimer?.cancel()
                isCollapsed = false
            }
        }
    }

    public func toggle(scope: String = "all", enabled: Bool) {
        sendIntent(
            command: .toggle,
            payload: ["cmd": "toggle", "scope": scope, "enabled": enabled]
        )
    }

    public func replay() {
        sendIntent(command: .replay, payload: ["cmd": "replay"])
    }

    public func retranscribeLastCapture() {
        guard !pendingRecoveredTranscriptionPaste else { return }
        pendingRecoveredTranscriptionPaste = true
        sendIntent(
            command: .retranscribeLast,
            payload: ["cmd": "retranscribe_last"]
        )
    }

    public func snooze() {
        switch mode {
        case .recording, .transcribing:
            sendIntent(command: .cancel, payload: ["cmd": "cancel"], trackPending: false)
        case .speaking:
            sendIntent(command: .stop, payload: ["cmd": "stop"], trackPending: false)
        default:
            break
        }
        barInitiatedRecording = false
        barInitiatedTimeout?.cancel()
        transcriptionTimeoutTask?.cancel()
        recordingIdleCleanupTask?.cancel()
        deferredFinalTranscriptionTask?.cancel()
        pendingRecordingIdleAfterFinal = false
        pendingIdleAfterAutoPasteCompletion = false
        pendingRecoveredTranscriptionPaste = false
        keepsPasteFlowEnvelope = true
        transcribingStartedAt = nil
        frontmostAppOnRecordStart = nil
        recordStartInsertionHandler = nil
        speechDetected = false
        resetAudioLevels()
        hotkeyPhase = .idle
        mode = .disconnected
        onModeChange?(.disconnected)
        collapseTimer?.cancel()
        isCollapsed = false
    }

    public func unsnooze() {
        guard mode == .disconnected else { return }
        mode = .idle
        onModeChange?(.idle)
        startCollapseTimer()
    }

    public func setLocalRecordingLevel(_ level: Double?) {
        guard mode == .recording else { return }
        localRecordingLevel = level.map { min(1, max(0, $0)) }
        refreshAudioLevel()
    }

    /// Paste the most recent transcript into the current target app again.
    public func repasteLastTranscript() {
        repasteTranscript(latestReusableTranscript)
    }

    /// Paste a specific transcript from history into the current target app.
    public func repasteTranscript(_ text: String) {
        let reusableText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reusableText.isEmpty else { return }
        logDiagnostic("repaste_requested", details: [
            "transcriptLength": String(reusableText.count),
            "hasCapturedInsertion": boolString(recordStartInsertionHandler != nil),
        ])
        pasteTranscript(reusableText, for: resolvedPasteTarget(forRepaste: true), plan: .repaste)
    }

    public func copyLastTranscript() {
        copyTranscript(latestReusableTranscript)
    }

    public func copyTranscript(_ text: String) {
        let reusableText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reusableText.isEmpty else { return }
        pasteboardWriter(reusableText)
        logDiagnostic("copy_transcript", details: [
            "transcriptLength": String(reusableText.count),
        ])
        showConfirmation("Copied")
    }

    /// Start recording from the Voice Bar. Captures the frontmost app for paste-on-stop.
    public func record(pressToTalk: Bool = false) {
        guard mode == .idle || mode == .error else { return }
        guard pendingIntent?.command != .record else { return }
        deferredFinalTranscriptionTask?.cancel()
        pendingRecordingIdleAfterFinal = false
        pendingIdleAfterAutoPasteCompletion = false
        pendingRecoveredTranscriptionPaste = false
        keepsPasteFlowEnvelope = false
        transcribingStartedAt = nil
        confirmationText = nil
        errorMessage = nil
        let front = frontmostAppProvider()
        if front?.bundleIdentifier != Bundle.main.bundleIdentifier {
            frontmostAppOnRecordStart = front
            recordStartInsertionHandler = dictationInsertionHandlerProvider()
        } else {
            frontmostAppOnRecordStart = nil
            recordStartInsertionHandler = nil
        }
        logDiagnostic("record_start", details: [
            "pressToTalk": boolString(pressToTalk),
            "capturedTargetApp": frontmostAppOnRecordStart?.bundleIdentifier ?? "nil",
            "hasCapturedInsertion": boolString(recordStartInsertionHandler != nil),
        ])
        barInitiatedRecording = true
        if pressToTalk, isConnected {
            mode = .recording
            onModeChange?(.recording)
            expandFromCollapse()
        }

        // Safety timeout: keep bar-initiated dictation state from leaking if the
        // daemon disappears, without ending normal long-form dictation.
        barInitiatedTimeout?.cancel()
        recordingIdleCleanupTask?.cancel()
        barInitiatedTimeout = Task { @MainActor in
            try? await Task.sleep(for: barInitiatedSafetyTimeout)
            if !Task.isCancelled, barInitiatedRecording {
                guard mode != .transcribing else { return }
                barInitiatedRecording = false
                frontmostAppOnRecordStart = nil
                recordStartInsertionHandler = nil
            }
        }

        sendIntent(command: .record, payload: [
            "cmd": "record",
            "silence_mode": "thoughtful",
            "timeout_seconds": 3600,
            "press_to_talk": pressToTalk,
        ])
    }

    // MARK: - State updates from socket events

    public func handleEvent(_ event: [String: Any]) {
        guard let type = event["type"] as? String else { return }

        switch type {
        case "state":
            guard let stateStr = event["state"] as? String else { return }
            switch stateStr {
            case "idle":
                let idleSource = event["source"] as? String
                if barInitiatedRecording, mode == .transcribing {
                    if idleSource == "recording", deferredFinalTranscriptionTask != nil {
                        pendingRecordingIdleAfterFinal = true
                        return
                    }

                    // Ignore stale idle from losing clients so the bar keeps
                    // the thinking state until the winning transcription lands.
                    // If a final transcript is already pending its minimum UI
                    // display window, ignore even recording-sourced idle so the
                    // pill stays blue until paste/history handling completes.
                    if idleSource != "recording" {
                        return
                    }
                }
                // AIDEV-NOTE: Do not reset barInitiatedRecording on generic idle.
                // Non-recording idle can still arrive from passive clients or
                // playback while the command-owning daemon is transcribing. These
                // stale idle events would kill the paste flag. Recording-sourced
                // idle gets a short final-transcript grace before clearing it.
                if idleSource == "recording" {
                    barInitiatedTimeout?.cancel()
                    scheduleRecordingIdleCleanupIfNeeded()
                }
                enterIdleState(clearQueue: idleSource == "playback")
            case "speaking":
                deferredFinalTranscriptionTask?.cancel()
                pendingRecordingIdleAfterFinal = false
                pendingIdleAfterAutoPasteCompletion = false
                pendingRecoveredTranscriptionPaste = false
                transcribingStartedAt = nil
                mode = .speaking
                statusText = event["text"] as? String ?? ""
                canReplay = true
                hotkeyPhase = .idle
                onModeChange?(.speaking)
                expandFromCollapse()
            case "recording":
                deferredFinalTranscriptionTask?.cancel()
                pendingRecordingIdleAfterFinal = false
                pendingIdleAfterAutoPasteCompletion = false
                pendingRecoveredTranscriptionPaste = false
                transcribingStartedAt = nil
                mode = .recording
                recordingMode = event["mode"] as? String
                silenceMode = event["silence_mode"] as? String
                speechDetected = false
                localRecordingLevel = nil
                refreshAudioLevel()
                canReplay = false // User recording — replay not applicable
                onModeChange?(.recording)
                expandFromCollapse()
            case "transcribing":
                enterTranscribingMode()
            default:
                break
            }

        case "ack":
            handleAckEvent(event)

        case "speech":
            if let detected = event["detected"] as? Bool {
                speechDetected = detected
            }

        case "transcription":
            if let text = event["text"] as? String {
                let isPartial = (event["partial"] as? Bool) == true
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else {
                    if isPartial {
                        return
                    }
                    failTranscription()
                    return
                }

                if isPartial {
                    transcript = trimmed
                    return
                }

                if scheduleFinalTranscriptionAfterMinimumDisplayIfNeeded(trimmed) {
                    return
                }
                handleFinalTranscription(trimmed)
            }

        case "subtitle":
            if let words = event["words"] as? [[String: Any]] {
                wordBoundaries = words.compactMap { w in
                    // JSONSerialization may decode numbers as Int or Double
                    guard let offset = (w["offset_ms"] as? Int) ?? (w["offset_ms"] as? Double).map({ Int($0) }),
                          let duration = (w["duration_ms"] as? Int) ?? (w["duration_ms"] as? Double).map({ Int($0) }),
                          let text = w["text"] as? String
                    else { return nil }
                    return (offsetMs: offset, durationMs: duration, text: text)
                }
            }

        case "queue":
            if let depth = event["depth"] as? Int {
                queueDepth = max(0, depth)
            }
            if let items = event["items"] as? [[String: Any]] {
                queueItems = items.compactMap { item in
                    guard let text = item["text"] as? String,
                          let voice = item["voice"] as? String,
                          let priority = item["priority"] as? String,
                          let isCurrent = item["is_current"] as? Bool
                    else { return nil }
                    let rawProgress = (item["progress"] as? Double)
                        ?? (item["progress"] as? Int).map(Double.init)
                        ?? 0
                    return QueueItemState(
                        text: text,
                        voice: voice,
                        priority: priority,
                        isCurrent: isCurrent,
                        progress: min(1, max(0, rawProgress))
                    )
                }
            } else if queueDepth == 0 {
                queueItems = []
            }

        case "audio_level":
            if let rms = event["rms"] as? Double {
                socketAudioLevel = rms
                refreshAudioLevel()
            }

        case "command_mode":
            handleCommandModeEvent(event)

        case "clip_marker":
            if let id = event["marker_id"] as? String,
               let label = event["label"] as? String,
               let source = event["source"] as? String,
               let status = event["status"] as? String {
                activeClipMarker = ClipMarkerState(id: id, label: label, source: source, status: status)
                expandFromCollapse()
            }

        case "error":
            transcriptionTimeoutTask?.cancel()
            let showDuringBarRecording = event["show_during_bar_recording"] as? Bool ?? false
            pendingRecoveredTranscriptionPaste = false
            // AIDEV-NOTE: NEVER reset barInitiatedRecording on error.
            // With multiple MCP clients, failing clients broadcast errors while
            // the successful client is still recording. Show error UI only if
            // we're not in an active bar-initiated recording.
            if showDuringBarRecording {
                barInitiatedRecording = false
                barInitiatedTimeout?.cancel()
                recordingIdleCleanupTask?.cancel()
                deferredFinalTranscriptionTask?.cancel()
                pendingRecordingIdleAfterFinal = false
                pendingIdleAfterAutoPasteCompletion = false
                transcribingStartedAt = nil
                frontmostAppOnRecordStart = nil
                recordStartInsertionHandler = nil
            }
            if showDuringBarRecording || !barInitiatedRecording {
                mode = .error
                errorMessage = event["message"] as? String ?? "Unknown error"
                expandFromCollapse()
            }

        default:
            break
        }
    }

    public func setConnectionStatus(_ connected: Bool) {
        let previous = isConnected
        isConnected = connected
        guard previous != connected else { return }

        onConnectionChange?(connected)

        if connected {
            if mode == .disconnected {
                mode = .idle
                onModeChange?(.idle)
                startCollapseTimer()
            }
            return
        }

        transcriptionTimeoutTask?.cancel()
        barInitiatedTimeout?.cancel()
        recordingIdleCleanupTask?.cancel()
        deferredFinalTranscriptionTask?.cancel()
        pendingRecordingIdleAfterFinal = false
        pendingIdleAfterAutoPasteCompletion = false
        pendingRecoveredTranscriptionPaste = false
        keepsPasteFlowEnvelope = false
        transcribingStartedAt = nil
        barInitiatedRecording = false
        pendingIntent = nil
        frontmostAppOnRecordStart = nil
        recordStartInsertionHandler = nil
        speechDetected = false
        recordingMode = nil
        silenceMode = nil
        errorMessage = nil
        resetAudioLevels()
        mode = .disconnected
        onModeChange?(.disconnected)
        collapseTimer?.cancel()
        isCollapsed = false
    }

    // MARK: - Idle collapse

    private func startCollapseTimer() {
        collapseTimer?.cancel()
        collapseTimer = Task { @MainActor in
            try? await Task.sleep(for: .seconds(Theme.collapseDelay))
            if !Task.isCancelled, mode == .idle, !isHovering {
                withAnimation(.smooth(duration: 0.3)) {
                    isCollapsed = true
                }
            }
        }
    }

    private func expandFromCollapse() {
        collapseTimer?.cancel()
        withAnimation(.smooth(duration: 0.3)) {
            isCollapsed = false
        }
    }

    /// Called when hover state changes.
    public func setHovering(_ hovering: Bool) {
        isHovering = hovering
        if hovering, isCollapsed {
            withAnimation(.smooth(duration: 0.3)) {
                isCollapsed = false
            }
        }
        if !hovering, mode == .idle {
            startCollapseTimer()
        }
    }

    public func setHotkeyEnabled(_ enabled: Bool) {
        hotkeyEnabled = enabled
        if !enabled {
            hotkeyPhase = .idle
        }
    }

    public func setHotkeyPhase(_ phase: HotkeyPhase) {
        hotkeyPhase = hotkeyEnabled ? phase : .idle
        if hotkeyPhase != .idle {
            expandFromCollapse()
        }
    }

    private func rememberRecentTranscription(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        recentTranscriptions.removeAll { $0 == trimmed }
        recentTranscriptions.insert(trimmed, at: 0)
        if recentTranscriptions.count > Self.maxRecentTranscriptions {
            recentTranscriptions = Array(recentTranscriptions.prefix(Self.maxRecentTranscriptions))
        }
        recentTranscriptionsSaver(recentTranscriptions)
    }

    private func refreshTranscriptionVocabulary() {
        transcriptionVocabularyTerms = Self.normalizeVocabularyTerms(transcriptionVocabularyLoader())
        transcriptionVocabularyAliases = Self.normalizeVocabularyAliases(
            transcriptionVocabularyAliasLoader()
        )
    }

    private func refreshAudioLevel() {
        if mode == .recording, let localRecordingLevel {
            audioLevel = localRecordingLevel
        } else {
            audioLevel = socketAudioLevel
        }
    }

    private func resetAudioLevels() {
        socketAudioLevel = nil
        localRecordingLevel = nil
        audioLevel = nil
    }

    private static func normalizeRecentTranscriptions(_ items: [String]) -> [String] {
        var unique: [String] = []
        for raw in items {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !unique.contains(trimmed) else { continue }
            unique.append(trimmed)
            if unique.count == maxRecentTranscriptions {
                break
            }
        }
        return unique
    }

    private static func normalizeVocabularyTerms(_ items: [String]) -> [String] {
        var unique: [String] = []
        for raw in items {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !unique.contains(trimmed) else { continue }
            unique.append(trimmed)
            if unique.count == maxVocabularyTerms {
                break
            }
        }
        return unique
    }

    private static func normalizeVocabularyAliases(
        _ items: [STTVocabularyAliasPreview]
    ) -> [STTVocabularyAliasPreview] {
        var unique: [STTVocabularyAliasPreview] = []
        for item in items {
            let from = item.from.trimmingCharacters(in: .whitespacesAndNewlines)
            let to = item.to.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !from.isEmpty, !to.isEmpty else { continue }
            let normalized = STTVocabularyAliasPreview(from: from, to: to)
            guard !unique.contains(normalized) else { continue }
            unique.append(normalized)
            if unique.count == maxVocabularyAliases {
                break
            }
        }
        return unique
    }

    public static func loadRecentTranscriptions() -> [String] {
        UserDefaults.standard.stringArray(forKey: recentTranscriptionsDefaultsKey) ?? []
    }

    public static func saveRecentTranscriptions(_ items: [String]) {
        UserDefaults.standard.set(items, forKey: recentTranscriptionsDefaultsKey)
    }

    private func startTranscriptionTimeout() {
        transcriptionTimeoutTask?.cancel()
        let timeout = barInitiatedRecording ? barInitiatedTranscriptionTimeout : transcriptionTimeout
        transcriptionTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: timeout)
            guard let self, !Task.isCancelled, mode == .transcribing else { return }
            failTranscription()
        }
    }

    private func enterIdleState(clearQueue: Bool) {
        mode = .idle
        statusText = ""
        speechDetected = false
        recordingMode = nil
        silenceMode = nil
        errorMessage = nil
        transcriptionTimeoutTask?.cancel()
        transcribingStartedAt = nil
        resetAudioLevels()
        wordBoundaries = []
        if clearQueue {
            queueDepth = 0
            queueItems = []
        }
        hotkeyPhase = .idle
        onModeChange?(.idle)
        startCollapseTimer()
    }

    private func enterTranscribingMode() {
        let modeChanged = mode != .transcribing
        mode = .transcribing
        if modeChanged || transcribingStartedAt == nil {
            transcribingStartedAt = currentDateProvider()
        }
        statusText = ""
        localRecordingLevel = nil
        refreshAudioLevel()
        startTranscriptionTimeout()
        hotkeyPhase = .idle
        logDiagnostic("state_transcribing", details: [
            "barInitiatedRecording": boolString(barInitiatedRecording),
            "capturedTargetApp": frontmostAppOnRecordStart?.bundleIdentifier ?? "nil",
            "hasCapturedInsertion": boolString(recordStartInsertionHandler != nil),
            "source": modeChanged ? "transition" : "refresh",
        ])
        if modeChanged {
            onModeChange?(.transcribing)
        }
        expandFromCollapse()
    }

    private func scheduleFinalTranscriptionAfterMinimumDisplayIfNeeded(_ text: String) -> Bool {
        guard mode == .transcribing, let transcribingStartedAt else { return false }

        let elapsed = currentDateProvider().timeIntervalSince(transcribingStartedAt)
        let remainingDisplayDuration = minimumTranscribingDisplayDuration - elapsed
        guard remainingDisplayDuration > 0 else { return false }

        deferredFinalTranscriptionTask?.cancel()
        deferredFinalTranscriptionTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(remainingDisplayDuration))
            guard let self, !Task.isCancelled else { return }
            deferredFinalTranscriptionTask = nil
            handleFinalTranscription(text)
        }
        return true
    }

    private func handleFinalTranscription(_ text: String) {
        transcriptionTimeoutTask?.cancel()
        deferredFinalTranscriptionTask?.cancel()
        deferredFinalTranscriptionTask = nil
        transcribingStartedAt = nil
        transcript = text
        rememberRecentTranscription(text)
        refreshTranscriptionVocabulary()
        logDiagnostic("transcription_final", details: [
            "textLength": String(text.count),
            "barInitiatedRecording": boolString(barInitiatedRecording),
            "capturedTargetApp": frontmostAppOnRecordStart?.bundleIdentifier ?? "nil",
            "hasCapturedInsertion": boolString(recordStartInsertionHandler != nil),
        ])

        let shouldAutoPaste = barInitiatedRecording
        let shouldPasteRecoveredTranscription = pendingRecoveredTranscriptionPaste
        let shouldApplyPendingRecordingIdle = pendingRecordingIdleAfterFinal
        pendingRecordingIdleAfterFinal = false
        pendingRecoveredTranscriptionPaste = false
        pendingIdleAfterAutoPasteCompletion =
            (shouldAutoPaste || shouldPasteRecoveredTranscription) && mode == .transcribing

        if shouldAutoPaste {
            barInitiatedRecording = false
            barInitiatedTimeout?.cancel()
            recordingIdleCleanupTask?.cancel()
            pasteTranscript(text, for: resolvedPasteTarget(forRepaste: false), plan: .autoPaste)
        } else if shouldPasteRecoveredTranscription {
            pasteTranscript(text, for: resolvedPasteTarget(forRepaste: true), plan: .repaste)
        }

        if shouldApplyPendingRecordingIdle && !shouldAutoPaste && !shouldPasteRecoveredTranscription {
            enterIdleState(clearQueue: false)
        }
    }

    private func scheduleRecordingIdleCleanupIfNeeded() {
        guard barInitiatedRecording else { return }

        recordingIdleCleanupTask?.cancel()
        let grace = recordingIdleFinalTranscriptGrace
        recordingIdleCleanupTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: grace)
            guard let self, !Task.isCancelled, barInitiatedRecording, mode != .transcribing else { return }
            barInitiatedRecording = false
            frontmostAppOnRecordStart = nil
            recordStartInsertionHandler = nil
        }
    }

    private func failTranscription() {
        transcriptionTimeoutTask?.cancel()
        barInitiatedTimeout?.cancel()
        recordingIdleCleanupTask?.cancel()
        deferredFinalTranscriptionTask?.cancel()
        pendingRecordingIdleAfterFinal = false
        pendingIdleAfterAutoPasteCompletion = false
        pendingRecoveredTranscriptionPaste = false
        keepsPasteFlowEnvelope = false
        transcribingStartedAt = nil
        barInitiatedRecording = false
        pendingIntent = nil
        frontmostAppOnRecordStart = nil
        recordStartInsertionHandler = nil
        speechDetected = false
        recordingMode = nil
        silenceMode = nil
        resetAudioLevels()
        mode = .error
        errorMessage = "Transcription failed"
        onModeChange?(.error)
        expandFromCollapse()
    }

    // MARK: - Paste transcription at cursor

    private func resolvedPasteTarget(forRepaste repaste: Bool) -> NSRunningApplication? {
        let currentFront = frontmostAppProvider()
        let isSelf = currentFront?.bundleIdentifier == Bundle.main.bundleIdentifier

        if repaste {
            return (!isSelf ? currentFront : nil) ?? lastPasteTargetApp
        }

        return (!isSelf ? currentFront : nil) ?? frontmostAppOnRecordStart
    }

    /// Refocuses the target app and pastes text via Cmd+V.
    private func pasteTranscript(
        _ text: String,
        for targetApp: NSRunningApplication?,
        plan: VoicePastePlan
    ) {
        let recordStartTargetApp = frontmostAppOnRecordStart
        let insertionHandler = plan == .autoPaste ? recordStartInsertionHandler : nil
        let targetBundleID = targetApp?.bundleIdentifier ?? "nil"
        logDiagnostic("paste_begin", details: [
            "plan": String(describing: plan),
            "targetApp": targetBundleID,
            "textLength": String(text.count),
            "hasCapturedInsertion": boolString(insertionHandler != nil),
            "axTrusted": boolString(accessibilityTrustChecker(false)),
        ])

        if let pasteHandler {
            if let targetApp {
                lastPasteTargetApp = targetApp
            }
            frontmostAppOnRecordStart = nil
            recordStartInsertionHandler = nil
            finishPasteConfirmation(
                outcome: pasteHandler(text) ? .pasted : .failed(Self.genericPasteFailureMessage),
                text: text
            )
            return
        } else {
            guard let targetApp else {
                frontmostAppOnRecordStart = nil
                recordStartInsertionHandler = nil
                logDiagnostic("paste_no_target", details: [
                    "plan": String(describing: plan),
                    "hasCapturedInsertion": boolString(insertionHandler != nil),
                ])
                finishPasteConfirmation(outcome: .failed(Self.genericPasteFailureMessage), text: text)
                return
            }

            let pasteDelay = plan == .autoPaste ? pasteConfirmationDelay : plan.pasteDelay
            pasteScheduler(plan.activationDelay) { [weak self] in
                guard let self else { return }
                let currentFront = frontmostAppProvider()
                let currentIsSelf = currentFront?.bundleIdentifier == Bundle.main.bundleIdentifier
                let pasteTarget: NSRunningApplication?
                if plan == .autoPaste {
                    pasteTarget = (!currentIsSelf ? currentFront : nil) ?? targetApp
                } else {
                    pasteTarget = targetApp
                }
                let pasteTargetBundleID = pasteTarget?.bundleIdentifier ?? "nil"
                let capturedInsertionHandler =
                    plan == .autoPaste && (currentFront == nil || currentIsSelf) && Self.sameApp(pasteTarget, recordStartTargetApp)
                    ? insertionHandler
                    : nil

                guard let pasteTarget else {
                    logDiagnostic("paste_no_target", details: [
                        "plan": String(describing: plan),
                        "hasCapturedInsertion": boolString(capturedInsertionHandler != nil),
                    ])
                    finishPasteConfirmation(outcome: .failed(Self.genericPasteFailureMessage), text: text)
                    return
                }

                logDiagnostic("paste_before_activate", details: [
                    "plan": String(describing: plan),
                    "targetApp": pasteTargetBundleID,
                    "hasCapturedInsertion": boolString(capturedInsertionHandler != nil),
                ])
                targetAppActivator(pasteTarget)
                lastPasteTargetApp = pasteTarget
                logDiagnostic("paste_after_activate", details: [
                    "plan": String(describing: plan),
                    "targetApp": pasteTargetBundleID,
                    "hasCapturedInsertion": boolString(capturedInsertionHandler != nil),
                ])

                pasteScheduler(pasteDelay) { [weak self] in
                    guard let self else { return }
                    if let capturedInsertionHandler, capturedInsertionHandler(text) {
                        logDiagnostic("paste_ax_insert_success", details: [
                            "plan": String(describing: plan),
                            "targetApp": pasteTargetBundleID,
                        ])
                        finishPasteConfirmation(outcome: .insertedAtCursor, text: text)
                        return
                    }

                    logDiagnostic("paste_ax_insert_miss", details: [
                        "plan": String(describing: plan),
                        "targetApp": pasteTargetBundleID,
                        "hadCapturedInsertion": boolString(capturedInsertionHandler != nil),
                    ])
                    let pasteboardSnapshot = pasteboardSnapshotter()
                    pasteboardWriter(text)
                    let changeCountAfterWrite = pasteboardChangeCountProvider()
                    let pasted = simulatedPasteHandler()
                    scheduleClipboardRestoreIfNeeded(
                        from: pasteboardSnapshot,
                        expectedChangeCount: changeCountAfterWrite
                    )
                    logDiagnostic("paste_cmdv_result", details: [
                        "plan": String(describing: plan),
                        "targetApp": pasteTargetBundleID,
                        "pasted": boolString(pasted),
                    ])
                    finishPasteConfirmation(
                        outcome: Self.pasteOutcome(
                            pasted: pasted,
                            plan: plan
                        ),
                        text: text
                    )
                }
            }
            frontmostAppOnRecordStart = nil
            recordStartInsertionHandler = nil
            return
        }
    }

    private static let genericPasteFailureMessage = "Paste failed — click back into the input and retry"
    private static let pasteFailureRetryMessage = "Paste failed — click input and press Shift+F5"

    private static func pasteOutcome(
        pasted: Bool,
        plan: VoicePastePlan
    ) -> VoicePasteOutcome {
        guard pasted else { return .failed(Self.genericPasteFailureMessage) }
        return .pasted
    }

    private static func sameApp(_ lhs: NSRunningApplication?, _ rhs: NSRunningApplication?) -> Bool {
        guard let lhs, let rhs else { return false }
        return lhs.processIdentifier == rhs.processIdentifier
    }

    private func scheduleClipboardRestoreIfNeeded(
        from snapshot: PasteboardSnapshot?,
        expectedChangeCount: Int
    ) {
        guard let snapshot else { return }

        pasteScheduler(pasteboardRestoreDelay) { [weak self] in
            guard let self else { return }
            let currentChangeCount = pasteboardChangeCountProvider()
            guard currentChangeCount == expectedChangeCount else {
                logDiagnostic("paste_clipboard_restore_skipped", details: [
                    "expectedChangeCount": String(expectedChangeCount),
                    "currentChangeCount": String(currentChangeCount),
                ])
                return
            }

            pasteboardSnapshotRestorer(snapshot)
            logDiagnostic("paste_clipboard_restored", details: [
                "restoredItems": String(snapshot.items.count),
            ])
        }
    }

    private func finishPasteConfirmation(outcome: VoicePasteOutcome, text: String) {
        logDiagnostic("paste_confirmation", details: [
            "outcome": String(describing: outcome),
        ])
        switch outcome {
        case .insertedAtCursor:
            showConfirmation(text, duration: 5.0)
        case .pasted:
            showConfirmation(text, duration: 5.0)
        case let .failed(message):
            showConfirmation(Self.failureMessageWithRetryHint(message), duration: 4.0)
        }

        if pendingIdleAfterAutoPasteCompletion {
            pendingIdleAfterAutoPasteCompletion = false
            pendingRecoveredTranscriptionPaste = false
            enterIdleState(clearQueue: false)
        }
    }

    private func showConfirmation(_ message: String, duration: TimeInterval = 1.5) {
        confirmationText = message
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            if self?.confirmationText == message {
                self?.confirmationText = nil
                self?.keepsPasteFlowEnvelope = false
            }
        }
    }

    private static func failureMessageWithRetryHint(_ message: String) -> String {
        if message == genericPasteFailureMessage {
            return pasteFailureRetryMessage
        }
        return message
    }

    private func sendIntent(
        command: IntentCommand,
        payload: [String: Any],
        trackPending: Bool = true
    ) {
        let id = UUID().uuidString
        var payloadWithID = payload
        payloadWithID["id"] = id
        if trackPending {
            pendingIntent = PendingIntent(id: id, command: command)
        }
        sendCommand?(payloadWithID)
    }

    private func logDiagnostic(_ event: String, details: [String: String] = [:]) {
        diagnosticLogger?(event, details)
    }

    private func boolString(_ value: Bool) -> String {
        value ? "true" : "false"
    }

    private func notifyPanelLayoutChangedIfNeeded(_ changed: Bool) {
        guard changed else { return }
        DispatchQueue.main.async { [weak self] in
            self?.onPanelLayoutChange?()
        }
    }

    private func handleAckEvent(_ event: [String: Any]) {
        guard let ack = SocketAckEvent(event: event),
              pendingIntent?.id == ack.id,
              pendingIntent?.command == ack.command
        else {
            return
        }

        pendingIntent = nil

        if ack.command == .retranscribeLast, ack.outcome != .accept {
            pendingRecoveredTranscriptionPaste = false
            showConfirmation(ack.reason ?? "Nothing to transcribe")
            return
        }

        guard ack.command == .record, ack.outcome == .reject else { return }

        barInitiatedRecording = false
        barInitiatedTimeout?.cancel()
        recordingIdleCleanupTask?.cancel()
        keepsPasteFlowEnvelope = false
        frontmostAppOnRecordStart = nil
        recordStartInsertionHandler = nil
        mode = .error
        errorMessage = ack.reason ?? "Unable to start recording"
        onModeChange?(.error)
        expandFromCollapse()
    }

    private func handleCommandModeEvent(_ event: [String: Any]) {
        guard let phaseString = event["phase"] as? String,
              let phase = CommandModePhase(rawValue: phaseString),
              let operation = event["operation"] as? String else {
            return
        }

        commandModeState = CommandModeState(
            phase: phase,
            operation: operation,
            prompt: event["prompt"] as? String
        )
        expandFromCollapse()

        guard phase == .applying, let replacementText = event["replacement_text"] as? String else {
            return
        }

        guard let commandModeApplyHandler else { return }
        let result = commandModeApplyHandler(replacementText)

        switch result {
        case let .axVerified(message):
            commandModeState = CommandModeState(phase: .done, operation: operation, prompt: event["prompt"] as? String)
            showConfirmation(message)
        case let .clipboardFallback(message):
            commandModeState = CommandModeState(
                phase: .fallback,
                operation: operation,
                prompt: event["prompt"] as? String
            )
            showConfirmation(message)
        case let .failed(message):
            commandModeState = CommandModeState(phase: .error, operation: operation, prompt: event["prompt"] as? String)
            mode = .error
            errorMessage = message
        }
    }

    private static func capturePasteboardSnapshot() -> PasteboardSnapshot? {
        let pasteboard = NSPasteboard.general
        let items = pasteboard.pasteboardItems?.compactMap { item -> [String: Data]? in
            let values = item.types.reduce(into: [String: Data]()) { result, type in
                if let data = item.data(forType: type) {
                    result[type.rawValue] = data
                }
            }
            return values.isEmpty ? nil : values
        } ?? []

        guard !items.isEmpty else { return nil }
        return PasteboardSnapshot(changeCount: pasteboard.changeCount, items: items)
    }

    private static func restorePasteboardSnapshot(_ snapshot: PasteboardSnapshot) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let items = snapshot.items.map { itemSnapshot -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in itemSnapshot {
                item.setData(data, forType: NSPasteboard.PasteboardType(type))
            }
            return item
        }
        pasteboard.writeObjects(items)
    }
}
