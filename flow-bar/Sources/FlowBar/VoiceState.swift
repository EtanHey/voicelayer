/// VoiceState.swift — Observable state model for Voice Bar.
///
/// Single source of truth for all UI state. Maps socket protocol events
/// (from VoiceLayer MCP server) to SwiftUI-friendly properties.
///
/// AIDEV-NOTE: VoiceMode values must match socket-protocol.ts VoiceLayerState
/// type: "idle" | "speaking" | "recording" | "transcribing"

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
    var silenceMode: String?   // "quick" | "standard" | "thoughtful"

    // Transport-layer hook injected by AppDelegate.
    // BarView calls stop()/toggle()/replay() which forward through this closure.
    var sendCommand: (([String: Any]) -> Void)?

    // MARK: - Commands

    func stop() {
        sendCommand?(["cmd": "stop"])
    }

    func cancel() {
        sendCommand?(["cmd": "cancel"])
    }

    func toggle(scope: String = "all", enabled: Bool) {
        sendCommand?(["cmd": "toggle", "scope": scope, "enabled": enabled])
    }

    func replay() {
        sendCommand?(["cmd": "replay"])
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
            case "speaking":
                mode = .speaking
                statusText = event["text"] as? String ?? ""
            case "recording":
                mode = .recording
                recordingMode = event["mode"] as? String
                silenceMode = event["silence_mode"] as? String
                speechDetected = false
            case "transcribing":
                mode = .transcribing
                statusText = ""
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
            }

        case "error":
            mode = .error
            errorMessage = event["message"] as? String ?? "Unknown error"

        default:
            break
        }
    }
}
