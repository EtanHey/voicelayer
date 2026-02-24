/// BarView.swift — Main pill UI for Flow Bar.
///
/// Shows state icon, status label, waveform (when recording), and action buttons.
/// Uses NSVisualEffectView for reliable vibrancy in transparent NSPanel.

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

// MARK: - Bar View

struct BarView: View {
    var state: VoiceState

    var body: some View {
        HStack(spacing: 6) {
            connectionDot
            stateContent
            Spacer(minLength: 4)
            actionButtons
        }
        .padding(.horizontal, 12)
        .frame(width: Theme.pillWidth, height: Theme.pillHeight)
        .background {
            VisualEffectBlur(material: .hudWindow, blendingMode: .behindWindow)
        }
        .clipShape(Capsule())
        .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
        .animation(Theme.stateTransition, value: state.mode)
        .animation(Theme.connectionTransition, value: state.isConnected)
    }

    // MARK: - Connection indicator

    private var connectionDot: some View {
        Circle()
            .fill(state.isConnected ? Color.green : Color.red.opacity(0.7))
            .frame(width: 6, height: 6)
    }

    // MARK: - State content (icon + label OR waveform)

    @ViewBuilder
    private var stateContent: some View {
        if state.mode == .recording {
            // Show waveform when recording
            WaveformView(
                mode: state.speechDetected ? .speechDetected : .listening,
                audioLevel: nil
            )
        } else {
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
        case .idle:          return "Ready"
        case .speaking:      return state.statusText.isEmpty ? "Speaking..." : state.statusText
        case .recording:     return "Listening..."
        case .transcribing:  return "Thinking..."
        case .error:         return state.errorMessage ?? "Error"
        case .disconnected:  return "Disconnected"
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
