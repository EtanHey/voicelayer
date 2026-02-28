// BarView.swift — Main pill UI for Voice Bar.
//
// Solid dark pill with dynamic width — shrink-wraps content per state.
// No vibrancy blur (eliminates dark edge artifacts on light backgrounds).
//
// Phase 5 polish: recording pulse, speaking waveform, error auto-dismiss,
// state border glow, right-click context menu.

import AppKit
import SwiftUI

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
        pillContent
    }

    // MARK: - Pill content (collapsed or expanded)

    private var pillContent: some View {
        Group {
            if state.isCollapsed {
                collapsedPill
                    .transition(.scale.combined(with: .opacity))
            } else {
                expandedPill
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(.smooth(duration: 0.3), value: state.isCollapsed)
        .onHover { hovering in
            state.setHovering(hovering)
        }
    }

    // MARK: - Collapsed pill (just dot)

    private var collapsedPill: some View {
        Circle()
            .fill(state.isConnected ? Color.green : Color.red)
            .frame(width: 10, height: 10)
            .padding(8)
            .background(Theme.pillBackground)
            .clipShape(Capsule())
            .onTapGesture {
                state.setHovering(true) // expand on tap
            }
    }

    // MARK: - Expanded pill (full content)

    private var expandedPill: some View {
        HStack(spacing: 8) {
            leadingIndicator
            stateContent
            actionButtons
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(minWidth: Theme.pillMinWidth)
        .background(Theme.pillBackground)
        .clipShape(Capsule())
        .overlay {
            // State-dependent border glow
            Capsule()
                .strokeBorder(borderColor, lineWidth: borderWidth)
        }
        .overlay {
            // Subtle inner edge for depth
            Capsule()
                .strokeBorder(Theme.pillInnerEdge, lineWidth: 0.5)
        }
        // No drop shadow — clean edges like Wispr Flow
        .opacity(state.mode == .disconnected ? 0.7 : 1.0)
        .fixedSize()
        .background(
            GeometryReader { geo in
                Color.clear
                    .onAppear { state.onPillSizeChange?(geo.size) }
                    .onChange(of: geo.size.width) { _, _ in state.onPillSizeChange?(geo.size) }
                    .onChange(of: geo.size.height) { _, _ in state.onPillSizeChange?(geo.size) }
            }
        )
        .animation(.smooth(duration: 0.3), value: state.mode)
        .animation(Theme.connectionTransition, value: state.isConnected)
        .onChange(of: state.mode) { _, newMode in
            handleModeChange(newMode)
        }
        .onTapGesture {
            if state.mode == .idle {
                NSHapticFeedbackManager.defaultPerformer.perform(
                    .alignment, performanceTime: .now
                )
                state.record()
            }
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
                if !Task.isCancelled, state.mode == .error {
                    state.mode = .idle
                    state.errorMessage = nil
                }
            }
        }
    }

    // MARK: - Border glow

    private var borderColor: Color {
        switch state.mode {
        case .recording: Theme.recordingColor.opacity(0.5)
        case .speaking: Theme.speakingColor.opacity(0.3)
        case .error: Theme.errorColor.opacity(0.5)
        default: .clear
        }
    }

    private var borderWidth: CGFloat {
        switch state.mode {
        case .recording, .error: 1.5
        case .speaking: 1.0
        default: 0
        }
    }

    // MARK: - Leading indicator

    @ViewBuilder
    private var leadingIndicator: some View {
        if state.mode == .recording {
            PulsingDot()
        } else {
            Circle()
                .fill(state.isConnected ? Color.green : Color.red)
                .frame(width: 6, height: 6)
        }
    }

    // MARK: - State content (icon + label OR waveform)

    @ViewBuilder
    private var stateContent: some View {
        switch state.mode {
        case .recording:
            // Active waveform during recording — driven by real audio level when available
            WaveformView(
                mode: state.speechDetected ? .speechDetected : .listening,
                audioLevel: state.audioLevel
            )
        case .speaking:
            // Shimmer waveform + teleprompter during speaking
            WaveformView(mode: .idle, audioLevel: state.audioLevel)
            if !state.statusText.isEmpty {
                TeleprompterView(
                    text: state.statusText,
                    wordBoundaries: state.wordBoundaries
                )
            } else {
                statusLabel
            }
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
        case .idle: "mic.fill"
        case .speaking: "speaker.wave.2.fill"
        case .recording: "waveform"
        case .transcribing: "text.bubble"
        case .error: "exclamationmark.triangle.fill"
        case .disconnected: "wifi.slash"
        }
    }

    // MARK: - Status text

    private var statusLabel: some View {
        Text(statusText)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.white.opacity(0.9))
            .lineLimit(1)
            .truncationMode(.tail)
            .contentTransition(.interpolate)
            .mask {
                // Leading fade when text is trimmed — words ghost out to the left
                if textIsTrimmed {
                    HStack(spacing: 0) {
                        LinearGradient(
                            colors: [.clear, .white],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                        .frame(width: 20)
                        Color.white
                    }
                } else {
                    Color.white
                }
            }
    }

    /// Max words shown in the pill for speaking/transcript text.
    private static let maxDisplayWords = 3

    private var statusText: String {
        switch state.mode {
        case .idle:
            if let confirmation = state.confirmationText {
                return confirmation
            }
            if !state.transcript.isEmpty {
                return Self.lastWords(state.transcript)
            }
            return "Ready"
        case .speaking:
            return "Speaking..."
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

    /// Whether the displayed text was trimmed (needs leading fade).
    private var textIsTrimmed: Bool {
        switch state.mode {
        case .idle:
            !state.transcript.isEmpty
                && state.transcript.split(separator: " ").count > Self.maxDisplayWords
        default:
            false
        }
    }

    /// Return the last N words of a string (no ellipsis — leading fade handles it).
    private static func lastWords(_ text: String) -> String {
        let words = text.split(separator: " ")
        if words.count <= maxDisplayWords { return text }
        return words.suffix(maxDisplayWords).joined(separator: " ")
    }

    // MARK: - Action buttons

    private var actionButtons: some View {
        HStack(spacing: 2) {
            if state.mode == .recording {
                pillButton(icon: "xmark") { state.cancel() }
                pillButton(icon: "stop.fill") { state.stop() }
            }
            if state.mode == .speaking {
                pillButton(icon: "stop.fill") { state.stop() }
            }
            if state.mode == .idle {
                pillButton(icon: "arrow.counterclockwise") { state.replay() }
            }
        }
    }

    private func pillButton(icon: String, action: @escaping () -> Void) -> some View {
        Button {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            action()
        } label: {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.8))
                .frame(width: 26, height: 26)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .transition(.scale.combined(with: .opacity))
    }
}
