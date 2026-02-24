/// BarView.swift — Main pill UI for Voice Bar.
///
/// Shows state icon, status label, waveform (when recording/speaking),
/// and action buttons. Uses NSVisualEffectView for reliable vibrancy
/// in transparent NSPanel.
///
/// Phase 5 polish: recording pulse, speaking waveform, error auto-dismiss,
/// state border glow, right-click context menu.

import SwiftUI
import AppKit

// MARK: - NSVisualEffectView wrapper

/// Wraps NSVisualEffectView for reliable behind-window vibrancy.
/// Setting state = .active keeps blur even when panel is not key window.
struct VisualEffectBlur: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    var blendingMode: NSVisualEffectView.BlendingMode
    var state: NSVisualEffectView.State = .active

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material     = material
        v.blendingMode = blendingMode
        v.state        = state
        v.isEmphasized = true
        return v
    }

    func updateNSView(_ v: NSVisualEffectView, context: Context) {
        v.material     = material
        v.blendingMode = blendingMode
        v.state        = state
    }
}

// MARK: - Pulsing recording dot

struct PulsingDot: View {
    @State private var isPulsing = false

    var body: some View {
        Circle()
            .fill(Theme.recordingColor)
            .frame(width: 8, height: 8)
            .scaleEffect(isPulsing ? 1.3 : 1.0)
            .opacity(isPulsing ? 0.7 : 1.0)
            .animation(
                .easeInOut(duration: 0.75).repeatForever(autoreverses: true),
                value: isPulsing
            )
            .onAppear { isPulsing = true }
    }
}

// MARK: - Bar View

struct BarView: View {
    var state: VoiceState
    @State private var errorDismissTask: Task<Void, Never>?

    var body: some View {
        HStack(spacing: 8) {
            leadingIndicator
            stateContent
                .frame(maxWidth: .infinity, alignment: .center)
            actionButtons
        }
        .padding(.horizontal, 14)
        .frame(width: Theme.pillWidth, height: Theme.pillHeight)
        .background {
            VisualEffectBlur(material: .hudWindow, blendingMode: .behindWindow)
        }
        .clipShape(Capsule())
        .overlay {
            // State-dependent border glow
            Capsule()
                .strokeBorder(borderColor, lineWidth: borderWidth)
        }
        .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
        .opacity(state.mode == .disconnected ? 0.6 : 1.0)
        .animation(Theme.stateTransition, value: state.mode)
        .animation(Theme.connectionTransition, value: state.isConnected)
        .onChange(of: state.mode) { _, newMode in
            handleModeChange(newMode)
        }
        .contextMenu {
            Button("Replay Last") { state.replay() }
            Divider()
            Button("Stop") { state.stop() }
        }
    }

    // MARK: - Error auto-dismiss

    private func handleModeChange(_ newMode: VoiceMode) {
        errorDismissTask?.cancel()
        if newMode == .error {
            errorDismissTask = Task { @MainActor in
                try? await Task.sleep(for: .seconds(3))
                if !Task.isCancelled && state.mode == .error {
                    state.mode = .idle
                    state.errorMessage = nil
                }
            }
        }
    }

    // MARK: - Border glow

    private var borderColor: Color {
        switch state.mode {
        case .recording:     return Theme.recordingColor.opacity(0.5)
        case .speaking:      return Theme.speakingColor.opacity(0.3)
        case .error:         return Theme.errorColor.opacity(0.5)
        default:             return .clear
        }
    }

    private var borderWidth: CGFloat {
        switch state.mode {
        case .recording, .error:  return 1.5
        case .speaking:           return 1.0
        default:                  return 0
        }
    }

    // MARK: - Leading indicator

    @ViewBuilder
    private var leadingIndicator: some View {
        if state.mode == .recording {
            PulsingDot()
        } else {
            Circle()
                .fill(state.isConnected ? Color.green : Color.red.opacity(0.7))
                .frame(width: 6, height: 6)
        }
    }

    // MARK: - State content (icon + label OR waveform)

    @ViewBuilder
    private var stateContent: some View {
        switch state.mode {
        case .recording:
            // Active waveform during recording
            WaveformView(
                mode: state.speechDetected ? .speechDetected : .listening,
                audioLevel: nil
            )
        case .speaking:
            // Shimmer waveform during speaking
            WaveformView(mode: .idle, audioLevel: nil)
            statusLabel
        default:
            statusIcon
            statusLabel
        }
    }

    // MARK: - Status icon

    private var statusIcon: some View {
        Image(systemName: iconName)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(Theme.stateColor(for: state.mode))
            .frame(width: 18)
            .contentTransition(.interpolate)
    }

    private var iconName: String {
        switch state.mode {
        case .idle:          return "mic.fill"
        case .speaking:      return "speaker.wave.2.fill"
        case .recording:     return "waveform"
        case .transcribing:  return "text.bubble"
        case .error:         return "exclamationmark.triangle.fill"
        case .disconnected:  return "wifi.slash"
        }
    }

    // MARK: - Status text

    private var statusLabel: some View {
        Text(statusText)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.primary)
            .lineLimit(1)
            .truncationMode(.tail)
            .contentTransition(.interpolate)
    }

    private var statusText: String {
        switch state.mode {
        case .idle:
            if !state.transcript.isEmpty {
                return state.transcript  // Show last transcription briefly
            }
            return "Ready"
        case .speaking:
            return state.statusText.isEmpty ? "Speaking..." : state.statusText
        case .recording:
            return "Listening..."
        case .transcribing:
            return "Thinking..."
        case .error:
            return state.errorMessage ?? "Error"
        case .disconnected:
            return "Disconnected"
        }
    }

    // MARK: - Action buttons

    @ViewBuilder
    private var actionButtons: some View {
        HStack(spacing: 2) {
            if state.mode == .recording || state.mode == .speaking {
                pillButton(icon: "stop.fill") { state.stop() }
            }
            if state.mode == .idle {
                pillButton(icon: "arrow.counterclockwise") { state.replay() }
            }
        }
    }

    private func pillButton(icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.primary.opacity(0.8))
                .frame(width: 26, height: 26)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .transition(.scale.combined(with: .opacity))
    }
}
