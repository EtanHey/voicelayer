// VoiceState.swift — Observable state model for Voice Bar.
//
// Single source of truth for all UI state. Maps socket protocol events
// (from VoiceLayer MCP server) to SwiftUI-friendly properties.
//
// AIDEV-NOTE: VoiceMode values must match socket-protocol.ts VoiceLayerState
// type: "idle" | "speaking" | "recording" | "transcribing"

import AppKit
import Foundation
import Observation

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
    var mode: VoiceMode = .disconnected
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

    /// Whether the pill is collapsed (idle for too long).
    var isCollapsed: Bool = false

    /// Whether the mouse is hovering over the pill.
    var isHovering: Bool = false

    /// Timer for idle collapse.
    private var collapseTimer: Task<Void, Never>?

    /// Whether the current recording was initiated from the Voice Bar (vs MCP).
    /// When true, transcription result is auto-pasted at the cursor.
    private var barInitiatedRecording = false

    /// The app that was frontmost when bar-initiated recording started.
    private var frontmostAppOnRecordStart: NSRunningApplication?

    /// Transport-layer hook injected by AppDelegate.
    /// BarView calls stop()/toggle()/replay() which forward through this closure.
    var sendCommand: (([String: Any]) -> Void)?

    // MARK: - Commands

    func stop() {
        sendCommand?(["cmd": "stop"])
    }

    func cancel() {
        barInitiatedRecording = false
        frontmostAppOnRecordStart = nil
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
        // Set mode optimistically to prevent rapid-tap duplicates
        mode = .recording
        confirmationText = nil
        frontmostAppOnRecordStart = NSWorkspace.shared.frontmostApplication
        barInitiatedRecording = true
        sendCommand?([
            "cmd": "record",
            "silence_mode": "standard",
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
                mode = .idle
                statusText = ""
                speechDetected = false
                recordingMode = nil
                silenceMode = nil
                audioLevel = nil
                // Reset bar-initiated flag if recording was cancelled/timed out
                if barInitiatedRecording {
                    barInitiatedRecording = false
                    frontmostAppOnRecordStart = nil
                }
                startCollapseTimer()
            case "speaking":
                mode = .speaking
                statusText = event["text"] as? String ?? ""
                expandFromCollapse()
            case "recording":
                mode = .recording
                recordingMode = event["mode"] as? String
                silenceMode = event["silence_mode"] as? String
                speechDetected = false
                expandFromCollapse()
            case "transcribing":
                mode = .transcribing
                statusText = ""
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
                // Auto-paste when recording was bar-initiated
                if barInitiatedRecording {
                    barInitiatedRecording = false
                    pasteTranscription(text)
                }
            }

        case "audio_level":
            if let rms = event["rms"] as? Double {
                audioLevel = rms
            }

        case "error":
            mode = .error
            errorMessage = event["message"] as? String ?? "Unknown error"
            expandFromCollapse() // Ensure error is visible even when collapsed
            // Reset bar-initiated flag on error (e.g., mic disabled)
            barInitiatedRecording = false
            frontmostAppOnRecordStart = nil

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
                isCollapsed = true
            }
        }
    }

    private func expandFromCollapse() {
        collapseTimer?.cancel()
        isCollapsed = false
    }

    /// Called when hover state changes.
    func setHovering(_ hovering: Bool) {
        isHovering = hovering
        if hovering, isCollapsed {
            isCollapsed = false
        }
        if !hovering, mode == .idle {
            startCollapseTimer()
        }
    }

    // MARK: - Paste transcription at cursor

    /// Refocuses the captured app and pastes text via Cmd+V.
    /// Transcription stays on clipboard (useful for re-pasting, matches Wispr Flow behavior).
    private func pasteTranscription(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        // Refocus the app that was frontmost when recording started
        if let app = frontmostAppOnRecordStart {
            app.activate()
        }
        frontmostAppOnRecordStart = nil

        // Small delay for app to regain focus, then simulate Cmd+V
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            Self.simulatePaste()

            // Show brief confirmation
            self?.confirmationText = "Pasted!"
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                self?.confirmationText = nil
            }
        }
    }

    /// Simulate Cmd+V keypress via CGEvent.
    private static func simulatePaste() {
        guard let source = CGEventSource(stateID: .hidSystemState) else { return }
        // Virtual key 0x09 = V
        let vDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true)
        let vUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
        vDown?.flags = .maskCommand
        vUp?.flags = .maskCommand
        vDown?.post(tap: .cghidEventTap)
        vUp?.post(tap: .cghidEventTap)
    }
}
