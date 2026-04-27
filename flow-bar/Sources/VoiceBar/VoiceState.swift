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

enum VoiceMode: String, CaseIterable {
    case idle
    case speaking
    case recording
    case transcribing
    case error
    case disconnected
}

struct QueueItemState: Equatable {
    var text: String
    var voice: String
    var priority: String
    var isCurrent: Bool
    var progress: Double
}

enum CommandModePhase: String, Equatable {
    case listening
    case capturing
    case applying
    case fallback
    case done
    case error
}

struct CommandModeState: Equatable {
    var phase: CommandModePhase
    var operation: String
    var prompt: String?
}

struct ClipMarkerState: Equatable {
    var id: String
    var label: String
    var source: String
    var status: String
}

struct PasteboardSnapshot: Equatable {
    var changeCount: Int
    var items: [[String: Data]]
}

private enum VoicePasteOutcome: Equatable {
    case insertedAtCursor
    case pasted
    case failed(String)
}

// MARK: - Observable state

@Observable
final class VoiceState {
    private static let maxRecentTranscriptions = 8
    private static let recentTranscriptionsDefaultsKey = "VoiceBar.recentTranscriptions"
    private static let maxVocabularyTerms = 512
    private static let maxVocabularyAliases = 512

    // UI-bound properties -- all mutations must happen on the main thread.
    var mode: VoiceMode = .idle
    var statusText: String = ""
    var transcript: String = ""
    var speechDetected: Bool = false
    var isConnected: Bool = false
    var errorMessage: String?

    // Recording metadata
    var recordingMode: String? // "vad" or "ptt"
    var silenceMode: String? // "quick" | "standard" | "thoughtful"

    /// Brief confirmation text shown after paste (e.g., "Pasted!").
    var confirmationText: String?

    /// Real-time audio level (0.0–1.0) from RMS events.
    var audioLevel: Double?
    private var socketAudioLevel: Double?
    private var localRecordingLevel: Double?

    /// Word boundary timestamps from TTS engine (ms offsets from audio start).
    var wordBoundaries: [(offsetMs: Int, durationMs: Int, text: String)] = []

    /// Whether the last completed action was TTS playback (replay is valid).
    /// Set true when speaking state arrives, false when recording starts.
    var canReplay: Bool = false

    /// Recent transcription history with the newest item first.
    var recentTranscriptions: [String] = []

    /// Active STT vocabulary hints loaded from the daemon snapshot.
    var transcriptionVocabularyTerms: [String] = []
    var transcriptionVocabularyAliases: [STTVocabularyAliasPreview] = []

    /// Latest completed transcript safe for re-paste/copy actions.
    var latestReusableTranscript: String {
        recentTranscriptions.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    /// Total queued + currently playing TTS items.
    var queueDepth: Int = 0
    var queueItems: [QueueItemState] = []
    var commandModeState: CommandModeState?
    var activeClipMarker: ClipMarkerState?

    /// Global hotkey availability and live gesture hint state.
    var hotkeyEnabled: Bool = false
    var hotkeyPhase: HotkeyPhase = .idle

    /// Whether the pill is collapsed (idle for too long).
    var isCollapsed: Bool = false

    /// Whether the mouse is hovering over the pill.
    var isHovering: Bool = false

    /// Timer for idle collapse.
    private var collapseTimer: Task<Void, Never>?

    /// Tracks the last user intent sent to the daemon until the matching ack returns.
    var pendingIntent: PendingIntent?

    /// Safety timeout for barInitiatedRecording — prevents stuck state.
    private var barInitiatedTimeout: Task<Void, Never>?
    private var transcriptionTimeoutTask: Task<Void, Never>?

    /// Whether the current recording was initiated from the Voice Bar (vs MCP).
    /// When true, transcription result is auto-pasted at the cursor.
    /// Cleared after transcription, cancel, disconnect, or a rejected record ack.
    /// Never cleared by idle/error alone — those are ambiguous with multiple MCP clients.
    private var barInitiatedRecording = false

    /// The app that was frontmost when bar-initiated recording started.
    private var frontmostAppOnRecordStart: NSRunningApplication?
    private var recordStartInsertionHandler: ((String) -> Bool)?

    /// The most recent app we pasted into. Reused for Cmd+Shift+V re-paste.
    private var lastPasteTargetApp: NSRunningApplication?

    /// Test seam for paste side effects. When set, bypasses system paste.
    var pasteHandler: ((String) -> Bool)?
    var commandModeApplyHandler: ((String) -> CommandModeApplyResult)?

    /// Delay before sending Cmd+V after activating the target app.
    var pasteConfirmationDelay: TimeInterval = 0.25

    /// Test seam for delayed paste scheduling.
    var pasteScheduler: (TimeInterval, @escaping () -> Void) -> Void = { delay, block in
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: block)
    }

    /// Test seam for re-activating the target app before paste.
    var targetAppActivator: (NSRunningApplication) -> Void = { app in
        app.activate()
    }

    /// Test seam for the frontmost app at record/paste time.
    var frontmostAppProvider: () -> NSRunningApplication? = {
        NSWorkspace.shared.frontmostApplication
    }

    /// Test seam for the final Cmd+V event posting.
    var simulatedPasteHandler: () -> Bool = {
        VoiceState.simulatePaste()
    }

    /// Test seam for Accessibility permission checks.
    var accessibilityTrustChecker: (_ prompt: Bool) -> Bool = { prompt in
        VoiceState.isAccessibilityTrusted(prompt: prompt)
    }

    /// Test seam for capturing a direct insertion closure tied to the focused input.
    var dictationInsertionHandlerProvider: () -> ((String) -> Bool)? = {
        CommandModeAXHelper.captureFocusedInsertionHandler()
    }

    /// Test seam for clipboard writes used by fallback paste.
    var pasteboardWriter: (String) -> Void = { string in
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
    }
    var pasteboardSnapshotter: () -> PasteboardSnapshot? = {
        VoiceState.capturePasteboardSnapshot()
    }
    var pasteboardSnapshotRestorer: (PasteboardSnapshot) -> Void = { snapshot in
        VoiceState.restorePasteboardSnapshot(snapshot)
    }
    var pasteboardChangeCountProvider: () -> Int = {
        NSPasteboard.general.changeCount
    }
    var pasteboardRestoreDelay: TimeInterval = 0.2

    private let commandModeAXHelper = CommandModeAXHelper()
    private let recentTranscriptionsSaver: ([String]) -> Void
    private let transcriptionVocabularyLoader: () -> [String]
    private let transcriptionVocabularyAliasLoader: () -> [STTVocabularyAliasPreview]

    /// Transport-layer hook injected by AppDelegate.
    /// BarView calls stop()/toggle()/replay() which forward through this closure.
    var sendCommand: (([String: Any]) -> Void)?

    /// Callback when the pill's rendered size changes — used to resize the NSPanel.
    var onPillSizeChange: ((CGSize) -> Void)?

    /// Callback when socket connection state changes — used to suspend/resume polling.
    var onConnectionChange: ((Bool) -> Void)?

    /// Callback when voice mode changes — used to lock/unlock pill dragging.
    var onModeChange: ((VoiceMode) -> Void)?
    var diagnosticLogger: ((String, [String: String]) -> Void)?
    var transcriptionTimeout: Duration = .seconds(30)

    init(
        recentTranscriptionsLoader: @escaping () -> [String] = {
            VoiceState.loadRecentTranscriptions()
        },
        recentTranscriptionsSaver: @escaping ([String]) -> Void = {
            VoiceState.saveRecentTranscriptions($0)
        },
        transcriptionVocabularyLoader: @escaping () -> [String] = {
            STTVocabularySnapshotLoader.load().promptTerms
        },
        transcriptionVocabularyAliasLoader: @escaping () -> [STTVocabularyAliasPreview] = {
            STTVocabularySnapshotLoader.load().aliases
        }
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

    func stop() {
        sendIntent(command: .stop, payload: ["cmd": "stop"])
    }

    func dismissError() {
        pendingIntent = nil
        errorMessage = nil
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

    func cancel() {
        barInitiatedRecording = false
        barInitiatedTimeout?.cancel()
        transcriptionTimeoutTask?.cancel()
        frontmostAppOnRecordStart = nil
        recordStartInsertionHandler = nil
        speechDetected = false
        resetAudioLevels()
        statusText = ""
        sendIntent(command: .cancel, payload: ["cmd": "cancel"])
    }

    func toggle(scope: String = "all", enabled: Bool) {
        sendIntent(
            command: .toggle,
            payload: ["cmd": "toggle", "scope": scope, "enabled": enabled]
        )
    }

    func replay() {
        sendIntent(command: .replay, payload: ["cmd": "replay"])
    }

    func retranscribeLastCapture() {
        sendIntent(
            command: .retranscribeLast,
            payload: ["cmd": "retranscribe_last"]
        )
    }

    func snooze() {
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

    func unsnooze() {
        guard mode == .disconnected else { return }
        mode = .idle
        onModeChange?(.idle)
        startCollapseTimer()
    }

    func setLocalRecordingLevel(_ level: Double?) {
        guard mode == .recording else { return }
        localRecordingLevel = level.map { min(1, max(0, $0)) }
        refreshAudioLevel()
    }

    /// Paste the most recent transcript into the current target app again.
    func repasteLastTranscript() {
        repasteTranscript(latestReusableTranscript)
    }

    /// Paste a specific transcript from history into the current target app.
    func repasteTranscript(_ text: String) {
        let reusableText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reusableText.isEmpty else { return }
        logDiagnostic("repaste_requested", details: [
            "transcriptLength": String(reusableText.count),
            "hasCapturedInsertion": boolString(recordStartInsertionHandler != nil),
        ])
        pasteTranscript(reusableText, for: resolvedPasteTarget(forRepaste: true), plan: .repaste)
    }

    func copyLastTranscript() {
        copyTranscript(latestReusableTranscript)
    }

    func copyTranscript(_ text: String) {
        let reusableText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reusableText.isEmpty else { return }
        pasteboardWriter(reusableText)
        logDiagnostic("copy_transcript", details: [
            "transcriptLength": String(reusableText.count),
        ])
        showConfirmation("Copied")
    }

    /// Start recording from the Voice Bar. Captures the frontmost app for paste-on-stop.
    func record(pressToTalk: Bool = false) {
        guard mode == .idle || mode == .error else { return }
        guard pendingIntent?.command != .record else { return }
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

        // Safety timeout: if no transcription arrives within 2.5 minutes, clear the flag
        barInitiatedTimeout?.cancel()
        barInitiatedTimeout = Task { @MainActor in
            try? await Task.sleep(for: .seconds(150))
            if !Task.isCancelled, barInitiatedRecording {
                barInitiatedRecording = false
                frontmostAppOnRecordStart = nil
                recordStartInsertionHandler = nil
            }
        }

        sendIntent(command: .record, payload: [
            "cmd": "record",
            "silence_mode": "thoughtful",
            "timeout_seconds": 120,
            "press_to_talk": pressToTalk,
        ])
    }

    // MARK: - State updates from socket events

    func handleEvent(_ event: [String: Any]) {
        guard let type = event["type"] as? String else { return }

        switch type {
        case "state":
            guard let stateStr = event["state"] as? String else { return }
            switch stateStr {
            case "idle":
                if barInitiatedRecording, mode == .transcribing {
                    // Ignore stale idle from losing clients so the bar keeps
                    // the thinking state until the winning transcription lands.
                    return
                }
                // AIDEV-NOTE: NEVER reset barInitiatedRecording on idle.
                // Multiple MCP clients receive the record command via sendToAll.
                // Clients that fail (no sox, session busy) broadcast error+idle
                // BEFORE the successful client finishes. These stale idle events
                // would kill the paste flag. Only transcription and cancel() reset it.
                mode = .idle
                statusText = ""
                speechDetected = false
                recordingMode = nil
                silenceMode = nil
                errorMessage = nil
                transcriptionTimeoutTask?.cancel()
                resetAudioLevels()
                wordBoundaries = []
                if (event["source"] as? String) == "playback" {
                    queueDepth = 0
                    queueItems = []
                }
                hotkeyPhase = .idle
                onModeChange?(.idle)
                startCollapseTimer()
            case "speaking":
                mode = .speaking
                statusText = event["text"] as? String ?? ""
                canReplay = true
                hotkeyPhase = .idle
                onModeChange?(.speaking)
                expandFromCollapse()
            case "recording":
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
                mode = .transcribing
                statusText = ""
                localRecordingLevel = nil
                refreshAudioLevel()
                startTranscriptionTimeout()
                hotkeyPhase = .idle
                logDiagnostic("state_transcribing", details: [
                    "barInitiatedRecording": boolString(barInitiatedRecording),
                    "capturedTargetApp": frontmostAppOnRecordStart?.bundleIdentifier ?? "nil",
                    "hasCapturedInsertion": boolString(recordStartInsertionHandler != nil),
                ])
                onModeChange?(.transcribing)
                expandFromCollapse()
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

                transcriptionTimeoutTask?.cancel()
                transcript = trimmed
                rememberRecentTranscription(trimmed)
                refreshTranscriptionVocabulary()
                logDiagnostic("transcription_final", details: [
                    "textLength": String(trimmed.count),
                    "barInitiatedRecording": boolString(barInitiatedRecording),
                    "capturedTargetApp": frontmostAppOnRecordStart?.bundleIdentifier ?? "nil",
                    "hasCapturedInsertion": boolString(recordStartInsertionHandler != nil),
                ])
                if barInitiatedRecording {
                    barInitiatedRecording = false
                    barInitiatedTimeout?.cancel()
                    pasteTranscript(trimmed, for: resolvedPasteTarget(forRepaste: false), plan: .autoPaste)
                }
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
            // AIDEV-NOTE: NEVER reset barInitiatedRecording on error.
            // With multiple MCP clients, failing clients broadcast errors while
            // the successful client is still recording. Show error UI only if
            // we're not in an active bar-initiated recording.
            if !barInitiatedRecording {
                mode = .error
                errorMessage = event["message"] as? String ?? "Unknown error"
                expandFromCollapse()
            }

        default:
            break
        }
    }

    func setConnectionStatus(_ connected: Bool) {
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
    func setHovering(_ hovering: Bool) {
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

    func setHotkeyEnabled(_ enabled: Bool) {
        hotkeyEnabled = enabled
        if !enabled {
            hotkeyPhase = .idle
        }
    }

    func setHotkeyPhase(_ phase: HotkeyPhase) {
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

    private static func loadRecentTranscriptions() -> [String] {
        UserDefaults.standard.stringArray(forKey: recentTranscriptionsDefaultsKey) ?? []
    }

    private static func saveRecentTranscriptions(_ items: [String]) {
        UserDefaults.standard.set(items, forKey: recentTranscriptionsDefaultsKey)
    }

    private func startTranscriptionTimeout() {
        transcriptionTimeoutTask?.cancel()
        let timeout = transcriptionTimeout
        transcriptionTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: timeout)
            guard let self, !Task.isCancelled, mode == .transcribing else { return }
            failTranscription()
        }
    }

    private func failTranscription() {
        transcriptionTimeoutTask?.cancel()
        barInitiatedTimeout?.cancel()
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
                outcome: pasteHandler(text) ? .pasted : .failed(Self.genericPasteFailureMessage)
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
                finishPasteConfirmation(outcome: .failed(Self.genericPasteFailureMessage))
                return
            }

            let pasteDelay = plan == .autoPaste ? pasteConfirmationDelay : plan.pasteDelay
            pasteScheduler(plan.activationDelay) { [weak self] in
                guard let self else { return }
                logDiagnostic("paste_before_activate", details: [
                    "plan": String(describing: plan),
                    "targetApp": targetBundleID,
                    "hasCapturedInsertion": boolString(insertionHandler != nil),
                ])
                targetAppActivator(targetApp)
                lastPasteTargetApp = targetApp
                logDiagnostic("paste_after_activate", details: [
                    "plan": String(describing: plan),
                    "targetApp": targetBundleID,
                    "hasCapturedInsertion": boolString(insertionHandler != nil),
                ])

                pasteScheduler(pasteDelay) { [weak self] in
                    guard let self else { return }
                    if let insertionHandler, insertionHandler(text) {
                        logDiagnostic("paste_ax_insert_success", details: [
                            "plan": String(describing: plan),
                            "targetApp": targetBundleID,
                        ])
                        finishPasteConfirmation(outcome: .insertedAtCursor)
                        return
                    }

                    logDiagnostic("paste_ax_insert_miss", details: [
                        "plan": String(describing: plan),
                        "targetApp": targetBundleID,
                        "hadCapturedInsertion": boolString(insertionHandler != nil),
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
                        "targetApp": targetBundleID,
                        "pasted": boolString(pasted),
                    ])
                    finishPasteConfirmation(
                        outcome: pasted ? .pasted : .failed(Self.genericPasteFailureMessage)
                    )
                }
            }
            frontmostAppOnRecordStart = nil
            recordStartInsertionHandler = nil
            return
        }
    }

    private static let genericPasteFailureMessage = "Paste failed — click back into the input and retry"

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

    private func finishPasteConfirmation(outcome: VoicePasteOutcome) {
        logDiagnostic("paste_confirmation", details: [
            "outcome": String(describing: outcome),
        ])
        switch outcome {
        case .insertedAtCursor:
            showConfirmation("Inserted at cursor")
        case .pasted:
            showConfirmation("Pasted!")
        case let .failed(message):
            showConfirmation(message, duration: 4.0)
        }
    }

    private func showConfirmation(_ message: String, duration: TimeInterval = 1.5) {
        confirmationText = message
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            if self?.confirmationText == message {
                self?.confirmationText = nil
            }
        }
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

    private func handleAckEvent(_ event: [String: Any]) {
        guard let ack = SocketAckEvent(event: event),
              pendingIntent?.id == ack.id,
              pendingIntent?.command == ack.command
        else {
            return
        }

        pendingIntent = nil

        guard ack.command == .record, ack.outcome == .reject else { return }

        barInitiatedRecording = false
        barInitiatedTimeout?.cancel()
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

        let result = (commandModeApplyHandler ?? { [commandModeAXHelper] text in
            commandModeAXHelper.applyReplacement(text)
        })(replacementText)

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

    /// Simulate Cmd+V via CGEvent. Requires Accessibility permission.
    /// Returns true if paste was posted, false if blocked (S3 fix: caller checks this).
    @discardableResult
    private static func simulatePaste() -> Bool {
        guard isAccessibilityTrusted(prompt: false) else {
            NSLog("[VoiceBar] simulatePaste: Accessibility not granted")
            return false
        }
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            NSLog("[VoiceBar] simulatePaste: failed to create CGEventSource")
            return false
        }
        let vKey: CGKeyCode = 0x09 // V
        let vDown = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true)
        let vUp = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false)
        guard let vDown, let vUp else {
            NSLog("[VoiceBar] simulatePaste: failed to create CGEvent")
            return false
        }
        vDown.flags = .maskCommand
        vUp.flags = .maskCommand
        vDown.post(tap: .cghidEventTap)
        vUp.post(tap: .cghidEventTap)
        return true
    }

    static func isAccessibilityTrusted(prompt: Bool) -> Bool {
        if prompt {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
            return AXIsProcessTrustedWithOptions(options)
        }
        return AXIsProcessTrusted()
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
