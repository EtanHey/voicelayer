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
    @State private var isHistoryPresented = false

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
        .animation(Theme.pillTransition, value: state.isCollapsed)
        .onHover { hovering in
            state.setHovering(hovering)
        }
    }

    // MARK: - Collapsed pill (just dot)

    private var collapsedPill: some View {
        Button {
            state.setHovering(true) // expand on tap
        } label: {
            ZStack(alignment: .topTrailing) {
                Circle()
                    .fill(Color.green) // VoiceBar is always alive — dot is always green
                    .frame(width: 10, height: 10)
                    .padding(8)
                    .background(Theme.pillBackground)
                    .clipShape(Capsule())

                if state.queueDepth > 1 {
                    queueBadge
                        .offset(x: 4, y: -2)
                }
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Expanded pill (full content)

    private var expandedPill: some View {
        HStack(spacing: 8) {
            leadingIndicator
            stateContent
            if state.queueDepth > 1 {
                queueBadge
            }
            actionButtons
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(
            minWidth: state.mode == .speaking ? Theme.pillMinWidth : Theme.pillCompactWidth,
            alignment: .leading
        )
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
        .opacity(1.0)
        .fixedSize()
        .background(
            GeometryReader { geo in
                Color.clear
                    .onAppear { state.onPillSizeChange?(geo.size) }
                    .onChange(of: geo.size.width) { _, _ in state.onPillSizeChange?(geo.size) }
                    .onChange(of: geo.size.height) { _, _ in state.onPillSizeChange?(geo.size) }
            }
        )
        .animation(Theme.pillTransition, value: state.mode)
        .animation(Theme.connectionTransition, value: state.isConnected)
        .animation(Theme.pillTransition, value: state.queueDepth)
        .animation(Theme.pillTransition, value: state.hotkeyPhase)
        .onChange(of: state.mode) { _, newMode in
            handleModeChange(newMode)
        }
        .onChange(of: state.recentTranscriptions.count) { _, count in
            if count == 0 {
                isHistoryPresented = false
            }
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
        if newMode != .idle {
            isHistoryPresented = false
        }
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
                .fill(Color.green) // VoiceBar is always alive
                .frame(width: 6, height: 6)
        }
    }

    private var queueBadge: some View {
        Text("\(state.queueDepth)")
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Theme.speakingColor.opacity(0.22))
            .clipShape(Capsule())
            .contentTransition(.numericText())
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
            if state.queueItems.count > 1 {
                queueVisualization
            } else {
                // Shimmer waveform + teleprompter during speaking
                WaveformView(mode: .idle, audioLevel: state.audioLevel)
                if !state.statusText.isEmpty {
                    TeleprompterView(
                        text: state.statusText,
                        wordBoundaries: state.wordBoundaries
                    )
                    .frame(
                        width: Theme.teleprompterViewportWidth,
                        height: Theme.teleprompterViewportHeight
                    )
                } else {
                    statusLabel
                }
            }
        default:
            statusIcon
            statusLabel
        }
    }

    private var queueVisualization: some View {
        let preview = VoiceBarPresentation.queuePreview(from: state.queueItems)

        return VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Text("Queue")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.62))
                if preview.overflowCount > 0 {
                    Text("+\(preview.overflowCount) more")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.5))
                }
            }

            Text(preview.currentText)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.96))
                .lineLimit(1)
                .truncationMode(.tail)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.white.opacity(0.12))
                    Capsule()
                        .fill(Theme.speakingColor.opacity(0.95))
                        .frame(width: max(10, geo.size.width * preview.progress))
                }
                .animation(Theme.queueProgressTransition, value: preview.progress)
            }
            .frame(height: 4)

            if let nextText = preview.nextText {
                HStack(spacing: 6) {
                    Text("Up next")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.55))
                    Text(nextText)
                        .font(.system(size: 11, weight: .regular))
                        .foregroundStyle(.white.opacity(0.74))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
        }
        .frame(width: Theme.pillQueueWidth, alignment: .leading)
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
        case .idle, .disconnected: "mic.fill"
        case .speaking: "speaker.wave.2.fill"
        case .recording: "waveform"
        case .transcribing: "text.bubble"
        case .error: "exclamationmark.triangle.fill"
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
            .frame(maxWidth: Theme.pillStatusMaxWidth, alignment: .leading)
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
        VoiceBarPresentation.liveStatusText(
            mode: state.mode,
            transcript: state.transcript,
            confirmationText: state.confirmationText,
            hotkeyPhase: state.hotkeyPhase,
            hotkeyEnabled: state.hotkeyEnabled,
            errorMessage: state.errorMessage
        )
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
        VoiceBarPresentation.lastWords(text)
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
            if state.mode == .idle, !state.recentTranscriptions.isEmpty {
                historyButton
            }
            if state.mode == .idle, state.canReplay {
                pillButton(icon: "arrow.counterclockwise") { state.replay() }
            }
        }
    }

    private var historyButton: some View {
        pillButton(icon: "clock.arrow.circlepath") {
            isHistoryPresented.toggle()
        }
        .popover(isPresented: $isHistoryPresented, arrowEdge: .bottom) {
            historyPopover
        }
    }

    private var historyPopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Recent Transcriptions")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(state.recentTranscriptions.enumerated()), id: \.offset) { index, item in
                        VStack(alignment: .leading, spacing: 4) {
                            if index == 0 {
                                Text("Latest")
                                    .font(.system(size: 10, weight: .bold, design: .rounded))
                                    .foregroundStyle(.secondary)
                            }
                            Text(item)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.primary)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 8)

                        if index < state.recentTranscriptions.count - 1 {
                            Divider()
                        }
                    }
                }
            }
            .frame(width: 320, height: 220)
        }
        .padding(14)
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
                .background(Color.white.opacity(0.06))
                .clipShape(Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .transition(.scale.combined(with: .opacity))
    }
}
