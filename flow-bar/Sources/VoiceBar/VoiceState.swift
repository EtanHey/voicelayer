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

// MARK: - Observable state

@Observable
final class VoiceState {
    private static let maxRecentTranscriptions = 8

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

    /// Total queued + currently playing TTS items.
    var queueDepth: Int = 0
    var queueItems: [QueueItemState] = []

    /// Global hotkey availability and live gesture hint state.
    var hotkeyEnabled: Bool = false
    var hotkeyPhase: HotkeyPhase = .idle

    /// Whether the pill is collapsed (idle for too long).
    var isCollapsed: Bool = false

    /// Whether the mouse is hovering over the pill.
    var isHovering: Bool = false

    /// Timer for idle collapse.
    private var collapseTimer: Task<Void, Never>?

    /// Safety timeout for barInitiatedRecording — prevents stuck state.
    private var barInitiatedTimeout: Task<Void, Never>?

    /// Whether the current recording was initiated from the Voice Bar (vs MCP).
    /// When true, transcription result is auto-pasted at the cursor.
    /// ONLY cleared by: transcription handler (after paste) or cancel().
    /// Never cleared by idle/error — those are ambiguous with multiple MCP clients.
    private var barInitiatedRecording = false

    /// The app that was frontmost when bar-initiated recording started.
    private var frontmostAppOnRecordStart: NSRunningApplication?

    /// The most recent app we pasted into. Reused for Cmd+Shift+V re-paste.
    private var lastPasteTargetApp: NSRunningApplication?

    /// Test seam for paste side effects. When set, bypasses system paste.
    var pasteHandler: ((String) -> Bool)?

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

    /// Test seam for the final Cmd+V event posting.
    var simulatedPasteHandler: () -> Bool = {
        VoiceState.simulatePaste()
    }

    /// Transport-layer hook injected by AppDelegate.
    /// BarView calls stop()/toggle()/replay() which forward through this closure.
    var sendCommand: (([String: Any]) -> Void)?

    /// Callback when the pill's rendered size changes — used to resize the NSPanel.
    var onPillSizeChange: ((CGSize) -> Void)?

    /// Callback when socket connection state changes — used to suspend/resume polling.
    var onConnectionChange: ((Bool) -> Void)?

    /// Callback when voice mode changes — used to lock/unlock pill dragging.
    var onModeChange: ((VoiceMode) -> Void)?

    // MARK: - Commands

    func stop() {
        sendCommand?(["cmd": "stop"])
    }

    func cancel() {
        barInitiatedRecording = false
        barInitiatedTimeout?.cancel()
        frontmostAppOnRecordStart = nil
        // Optimistic — immediately go idle so user sees instant response.
        // MCP will also send idle after processing the cancel.
        mode = .idle
        speechDetected = false
        resetAudioLevels()
        statusText = ""
        onModeChange?(.idle)
        startCollapseTimer()
        sendCommand?(["cmd": "cancel"])
    }

    func toggle(scope: String = "all", enabled: Bool) {
        sendCommand?(["cmd": "toggle", "scope": scope, "enabled": enabled])
    }

    func replay() {
        sendCommand?(["cmd": "replay"])
    }

    func snooze() {
        switch mode {
        case .recording, .transcribing:
            sendCommand?(["cmd": "cancel"])
        case .speaking:
            sendCommand?(["cmd": "stop"])
        default:
            break
        }
        barInitiatedRecording = false
        barInitiatedTimeout?.cancel()
        frontmostAppOnRecordStart = nil
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
        guard !transcript.isEmpty else { return }
        pasteTranscript(transcript, for: resolvedPasteTarget(forRepaste: true), plan: .repaste)
    }

    /// Start recording from the Voice Bar. Captures the frontmost app for paste-on-stop.
    func record() {
        guard mode == .idle else { return }
        mode = .recording // Optimistic — prevents rapid-tap duplicates
        onModeChange?(.recording)
        confirmationText = nil
        let front = NSWorkspace.shared.frontmostApplication
        if front?.bundleIdentifier != Bundle.main.bundleIdentifier {
            frontmostAppOnRecordStart = front
        }
        barInitiatedRecording = true

        // Safety timeout: if no transcription arrives within 2.5 minutes, clear the flag
        barInitiatedTimeout?.cancel()
        barInitiatedTimeout = Task { @MainActor in
            try? await Task.sleep(for: .seconds(150))
            if !Task.isCancelled, barInitiatedRecording {
                barInitiatedRecording = false
                frontmostAppOnRecordStart = nil
            }
        }

        sendCommand?([
            "cmd": "record",
            "silence_mode": "thoughtful",
            "timeout_seconds": 120,
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
                hotkeyPhase = .idle
                onModeChange?(.transcribing)
                expandFromCollapse()
            default:
                break
            }

        case "speech":
            if let detected = event["detected"] as? Bool {
                speechDetected = detected
            }

        case "transcription":
            if let text = event["text"] as? String {
                transcript = text
                rememberRecentTranscription(text)
                if barInitiatedRecording {
                    barInitiatedRecording = false
                    barInitiatedTimeout?.cancel()
                    pasteTranscript(text, for: resolvedPasteTarget(forRepaste: false), plan: .autoPaste)
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

        case "error":
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

    // MARK: - Paste transcription at cursor

    private func resolvedPasteTarget(forRepaste repaste: Bool) -> NSRunningApplication? {
        let currentFront = NSWorkspace.shared.frontmostApplication
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
        let pasted: Bool

        if let pasteHandler {
            pasted = pasteHandler(text)
        } else {
            guard let targetApp else {
                pasted = false
                frontmostAppOnRecordStart = nil
                finishPasteConfirmation(pasted: pasted)
                return
            }

            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)

            let pasteDelay = plan == .autoPaste ? pasteConfirmationDelay : plan.pasteDelay
            pasteScheduler(plan.activationDelay) { [weak self] in
                guard let self else { return }
                targetAppActivator(targetApp)
                lastPasteTargetApp = targetApp

                pasteScheduler(pasteDelay) { [weak self] in
                    guard let self else { return }
                    let pasted = simulatedPasteHandler()
                    finishPasteConfirmation(pasted: pasted)
                }
            }
            frontmostAppOnRecordStart = nil
            return
        }

        if let targetApp {
            lastPasteTargetApp = targetApp
        }
        frontmostAppOnRecordStart = nil
        finishPasteConfirmation(pasted: pasted)
    }

    private func finishPasteConfirmation(pasted: Bool) {
        confirmationText = pasted ? "Pasted!" : "Paste failed — check Accessibility"
        DispatchQueue.main.asyncAfter(deadline: .now() + (pasted ? 1.5 : 3.0)) { [weak self] in
            self?.confirmationText = nil
        }
    }

    /// Simulate Cmd+V via CGEvent. Requires Accessibility permission.
    /// Returns true if paste was posted, false if blocked (S3 fix: caller checks this).
    @discardableResult
    private static func simulatePaste() -> Bool {
        guard AXIsProcessTrusted() else {
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
}
