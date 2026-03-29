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

// MARK: - Observable state

@Observable
final class VoiceState {
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

    /// Word boundary timestamps from TTS engine (ms offsets from audio start).
    var wordBoundaries: [(offsetMs: Int, durationMs: Int, text: String)] = []

    /// Whether the last completed action was TTS playback (replay is valid).
    /// Set true when speaking state arrives, false when recording starts.
    var canReplay: Bool = false

    /// Total queued + currently playing TTS items.
    var queueDepth: Int = 0

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
        audioLevel = nil
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
                audioLevel = nil
                wordBoundaries = []
                onModeChange?(.idle)
                startCollapseTimer()
            case "speaking":
                mode = .speaking
                statusText = event["text"] as? String ?? ""
                canReplay = true
                onModeChange?(.speaking)
                expandFromCollapse()
            case "recording":
                mode = .recording
                recordingMode = event["mode"] as? String
                silenceMode = event["silence_mode"] as? String
                speechDetected = false
                canReplay = false // User recording — replay not applicable
                onModeChange?(.recording)
                expandFromCollapse()
            case "transcribing":
                mode = .transcribing
                statusText = ""
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
                if barInitiatedRecording {
                    barInitiatedRecording = false
                    barInitiatedTimeout?.cancel()
                    pasteTranscription(text)
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
            // JSONSerialization may decode numbers as Int or Double
            if let depth = (event["depth"] as? Int) ?? (event["depth"] as? Double).map({ Int($0) }) {
                queueDepth = max(0, depth)
            }

        case "audio_level":
            if let rms = event["rms"] as? Double {
                audioLevel = rms
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

    // MARK: - Paste transcription at cursor

    /// Refocuses the captured app and pastes text via Cmd+V.
    private func pasteTranscription(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        // S4 fix: revalidate frontmost app at paste time — user may have switched apps
        let currentFront = NSWorkspace.shared.frontmostApplication
        let isSelf = currentFront?.bundleIdentifier == Bundle.main.bundleIdentifier
        let targetApp = (!isSelf ? currentFront : nil) ?? frontmostAppOnRecordStart

        if let targetApp {
            targetApp.activate()
        }
        frontmostAppOnRecordStart = nil

        // 250ms delay for Electron apps (VS Code, Claude) to regain focus
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            // S3 fix: only show "Pasted!" if paste actually succeeds
            let pasted = Self.simulatePaste()
            self?.confirmationText = pasted ? "Pasted!" : "Paste failed — check Accessibility"
            DispatchQueue.main.asyncAfter(deadline: .now() + (pasted ? 1.5 : 3.0)) {
                self?.confirmationText = nil
            }
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
