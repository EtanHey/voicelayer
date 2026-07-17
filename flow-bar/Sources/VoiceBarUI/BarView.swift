// BarView.swift — Main pill UI for Voice Bar.
//
// Solid dark pill with dynamic width — shrink-wraps content per state.
// No vibrancy blur (eliminates dark edge artifacts on light backgrounds).
//
// Phase 5 polish: recording pulse, truthful waveform,
// state border glow, right-click context menu.

import AppKit
import SwiftUI

public enum VoiceBarContentTransitionPolicy {
    public static func insertionUsesCrossFade(from source: VoiceMode, to destination: VoiceMode) -> Bool {
        !(source == .speaking && destination == .idle)
    }

    public static func removalUsesCrossFade(forContentMode mode: VoiceMode) -> Bool {
        mode != .speaking
    }

    public static func transition(for contentMode: VoiceMode, insertedFrom source: VoiceMode) -> AnyTransition {
        let crossFade = AnyTransition.opacity.animation(.easeInOut(duration: 0.2))
        let insertion = insertionUsesCrossFade(from: source, to: contentMode) ? crossFade : .identity
        // SwiftUI stores this transition with the inserted content view, so its
        // later removal policy must be based on that view's own mode.
        let removal = removalUsesCrossFade(forContentMode: contentMode) ? crossFade : .identity
        return .asymmetric(insertion: insertion, removal: removal)
    }
}

// MARK: - Pulsing recording dot

public struct PulsingDot: View {
    @State private var isPulsing = false

    public var body: some View {
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

public struct PulsingStatusLabel: View {
    public let text: String
    @State private var isPulsing = false

    public var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.white.opacity(0.9))
            .lineLimit(1)
            .truncationMode(.tail)
            .opacity(isPulsing ? 0.55 : 1.0)
            .animation(
                .easeInOut(duration: 0.75).repeatForever(autoreverses: true),
                value: isPulsing
            )
            .onAppear { isPulsing = true }
    }
}

public struct ProcessingSpinner: View {
    private let size: CGFloat = 14

    public var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            let angle = timeline.date.timeIntervalSinceReferenceDate * 360

            Circle()
                .trim(from: 0.08, to: 0.74)
                .stroke(
                    Theme.speakingColor.opacity(0.98),
                    style: StrokeStyle(lineWidth: 2.2, lineCap: .round)
                )
                .rotationEffect(.degrees(angle))
                .frame(width: size, height: size)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

// MARK: - Bar View

public struct BarView: View {
    public var state: VoiceState
    public var commandRouter: BarCommandRouting
    @State private var errorDismissTask: Task<Void, Never>?
    @State private var isHistoryPresented = false
    @State private var isVocabularyPresented = false

    public var body: some View {
        pillContent
    }

    public init(state: VoiceState, commandRouter: BarCommandRouting) {
        self.state = state
        self.commandRouter = commandRouter
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
                    .frame(width: 8, height: 8)
                    .padding(7)
                    .background(Theme.pillBackground)
                    .clipShape(Capsule())

                if state.queueDepth > 1 {
                    queueBadge
                        .offset(x: 4, y: -2)
                }
            }
        }
        .buttonStyle(.plain)
        .contentShape(Capsule())
    }

    // MARK: - Expanded pill (full content)

    private var expandedPill: some View {
        HStack(spacing: 8) {
            leadingIndicator
            stateContent
            if state.queueDepth > 1 {
                queueBadge
            }
            if !transcriptPreviewIsVisible {
                actionButtons
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, pillVerticalPadding)
        .frame(
            minWidth: state.mode == .speaking ? Theme.pillMinWidth : Theme.pillCompactWidth,
            alignment: pillContentAlignment
        )
        .frame(width: pillFixedWidth, height: pillFixedHeight, alignment: pillContentAlignment)
        .background(Theme.pillBackground)
        .clipShape(Capsule())
        .overlay {
            Capsule()
                .fill(stateWashColor)
                .allowsHitTesting(false)
                .animation(Theme.modeTransition, value: state.mode)
        }
        .overlay {
            // State-dependent border glow
            Capsule()
                .strokeBorder(borderColor, lineWidth: borderWidth)
                .allowsHitTesting(false)
                .animation(Theme.modeTransition, value: state.mode)
        }
        .overlay {
            // Subtle inner edge for depth
            Capsule()
                .strokeBorder(Theme.pillInnerEdge, lineWidth: 0.5)
                .allowsHitTesting(false)
        }
        // No drop shadow — clean edges like Wispr Flow
        .opacity(1.0)
        .fixedSize(horizontal: false, vertical: true)
        .animation(Theme.pillTransition, value: state.mode)
        .animation(Theme.connectionTransition, value: state.isConnected)
        .animation(Theme.pillTransition, value: state.queueDepth)
        .animation(Theme.modeTransition, value: state.hotkeyPhase)
        .onChange(of: state.mode) { _, newMode in
            handleModeChange(newMode)
        }
        .onChange(of: state.recentTranscriptionEntries.count) { _, count in
            if count == 0 {
                isHistoryPresented = false
            }
        }
        .onChange(of: state.transcriptionVocabularyTerms.count) { _, count in
            if count == 0 {
                isVocabularyPresented = false
            }
        }
        .contentShape(Capsule())
    }

    // MARK: - Error state

    private func handleModeChange(_ newMode: VoiceMode) {
        errorDismissTask?.cancel()
        if newMode != .idle,
           !(newMode == .transcribing && state.isHistoryRetranscriptionPending) {
            isHistoryPresented = false
            isVocabularyPresented = false
        }
    }

    // MARK: - Border glow

    private var borderColor: Color {
        switch state.mode {
        case .recording: Theme.recordingColor.opacity(0.50)
        case .transcribing: Theme.speakingColor.opacity(0.48)
        case .speaking: Theme.speakingColor.opacity(0.3)
        case .error: Theme.errorColor.opacity(0.5)
        case .disconnected: Theme.errorColor.opacity(0.35)
        default: .clear
        }
    }

    private var borderWidth: CGFloat {
        switch state.mode {
        case .recording, .error, .disconnected: 1.5
        case .speaking, .transcribing: 1.0
        default: 0
        }
    }

    private var stateWashColor: Color {
        switch state.mode {
        case .recording:
            Theme.recordingColor.opacity(0.12)
        case .transcribing:
            Theme.speakingColor.opacity(0.10)
        default:
            .clear
        }
    }

    // MARK: - Leading indicator

    @ViewBuilder
    private var leadingIndicator: some View {
        if state.mode == .recording {
            PulsingDot()
        } else if state.mode == .transcribing {
            ProcessingSpinner()
        } else if state.mode == .error {
            EmptyView()
        } else {
            Circle()
                .fill(state.mode == .disconnected ? Theme.errorColor : Color.green)
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

    private var stateContent: some View {
        Group {
            switch state.mode {
            case .recording:
                let recordingContent = VoiceBarPresentation.recordingContent(
                    hotkeyPhase: state.hotkeyPhase
                )
                HStack(spacing: 8) {
                    if recordingContent.showsWaveform {
                        WaveformView(
                            audioLevel: state.recordingWaveformLevel,
                            color: Theme.recordingColor
                        )
                    }
                    if !recordingContent.statusText.isEmpty {
                        if recordingContent.usesPulsingLabelOpacity {
                            PulsingStatusLabel(text: recordingContent.statusText)
                        } else {
                            Text(recordingContent.statusText)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.white.opacity(0.9))
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(
                    recordingContent.statusText.isEmpty ? "Recording" : recordingContent.statusText
                )
            case .speaking:
                if state.queueItems.count > 1 {
                    queueVisualization
                } else {
                    // TimelineView only drives refresh cadence. VoiceState owns
                    // the monotonic uptime domain used to index the envelope.
                    WaveformView(color: Theme.speakingColor) {
                        state.playbackAudioLevel()
                    }
                    if TeleprompterVisibilityPolicy.keepsTimelineMounted(
                        hasText: !state.statusText.isEmpty
                    ) {
                        ZStack(alignment: .leading) {
                            TeleprompterView(
                                text: state.statusText,
                                wordBoundaries: state.wordBoundaries
                            )
                            .opacity(
                                TeleprompterVisibilityPolicy.timelineOpacity(
                                    isDismissed: state.isTeleprompterDismissed
                                )
                            )
                            .accessibilityHidden(state.isTeleprompterDismissed)

                            Text("Teleprompter hidden")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.white.opacity(0.72))
                                .opacity(
                                    TeleprompterVisibilityPolicy.hiddenLabelOpacity(
                                        isDismissed: state.isTeleprompterDismissed
                                    )
                                )
                                .accessibilityHidden(!state.isTeleprompterDismissed)
                        }
                        .frame(
                            width: Theme.teleprompterViewportWidth,
                            height: Theme.teleprompterViewportHeight
                        )
                    } else {
                        statusLabel
                    }
                }
            case .transcribing:
                HStack(spacing: 8) {
                    if !statusText.isEmpty {
                        Text(statusText)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.white.opacity(0.9))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(statusText.isEmpty ? "Transcribing" : statusText)
            case .error:
                Button {
                    NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
                    commandRouter.handlePrimaryTap()
                } label: {
                    HStack(spacing: 8) {
                        statusIconImage
                        statusLabel
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Retry voice recording")
            default:
                statusIcon
                statusLabel
            }
        }
        // Force a clean view identity swap on mode change — prevents glitchy
        // partial animations when SwiftUI tries to morph between different
        // view hierarchies (e.g., PulsingDot → TeleprompterView).
        .id(state.mode)
        .transition(
            VoiceBarContentTransitionPolicy.transition(
                for: state.mode,
                insertedFrom: state.previousMode
            )
        )
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

    @ViewBuilder
    private var statusIcon: some View {
        if state.mode == .idle || state.mode == .error {
            Button {
                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
                commandRouter.handlePrimaryTap()
            } label: {
                statusIconImage
                    .frame(width: 26, height: 26)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(state.mode == .error ? "Retry voice recording" : "Start voice recording")
        } else {
            statusIconImage
        }
    }

    private var statusIconImage: some View {
        Image(systemName: iconName)
            .font(.system(size: transcriptPreviewIsVisible ? 16 : 14, weight: .semibold))
            .foregroundStyle(Theme.stateColor(for: state.mode))
            .frame(width: transcriptPreviewIsVisible ? 22 : 18)
            .fixedSize()
            .layoutPriority(2)
            .contentTransition(.interpolate)
    }

    private var iconName: String {
        switch state.mode {
        case .idle: "mic.fill"
        case .disconnected: "bolt.horizontal.circle.fill"
        case .speaking: "speaker.wave.2.fill"
        case .recording: "waveform"
        case .transcribing: "waveform"
        case .error: "exclamationmark.triangle.fill"
        }
    }

    // MARK: - Status text

    private var statusLabel: some View {
        Group {
            if transcriptPreviewIsVisible {
                Text(statusText)
                    .frame(width: transcriptPreviewWidth, alignment: .center)
            } else {
                Text(statusText)
            }
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(.white.opacity(0.9))
        .multilineTextAlignment(transcriptPreviewIsVisible ? .center : .leading)
        .lineLimit(statusLineLimit)
        .truncationMode(.tail)
        .contentTransition(.opacity)
        .fixedSize(horizontal: false, vertical: true)
        .layoutPriority(1)
    }

    private var statusText: String {
        if let transcriptPreviewText {
            return transcriptPreviewText
        }

        return VoiceBarPresentation.liveStatusText(
            mode: state.mode,
            transcript: state.transcript,
            confirmationText: state.confirmationText,
            hotkeyPhase: state.hotkeyPhase,
            hotkeyEnabled: state.hotkeyEnabled,
            errorMessage: state.errorMessage,
            transcribingStatusText: state.transcribingStatusText,
            commandModeState: state.commandModeState,
            activeClipMarker: state.activeClipMarker
        )
    }

    /// Whether the displayed text was trimmed (needs leading fade).
    private var textIsTrimmed: Bool {
        transcriptPreviewIsVisible
    }

    private var compactPillUsesFixedHeight: Bool {
        state.mode != .speaking && !transcriptPreviewIsVisible && state.queueDepth <= 1
    }

    private var pillFixedHeight: CGFloat? {
        if let transcriptPreviewLayout {
            return transcriptPreviewLayout.height
        }
        if compactPillUsesFixedHeight {
            return Theme.pillCompactHeight
        }
        return nil
    }

    private var pillFixedWidth: CGFloat? {
        if state.keepsPasteFlowEnvelope {
            return Theme.panelWidth - (Theme.panelPadding * 2)
        }

        if let transcriptPreviewText {
            return Theme.transcriptPreviewPillWidth(for: transcriptPreviewText)
        }

        return Theme.pillContentWidth(
            for: state.mode,
            statusText: statusText,
            idleAccessoryButtonCount: idleAccessoryButtonCount,
            queueItemCount: state.queueItems.count
        )
    }

    private var pillContentAlignment: Alignment {
        state.mode == .error ? .center : .leading
    }

    private var pillVerticalPadding: CGFloat {
        transcriptPreviewLayout?.isMultiline == true ? 8 : 0
    }

    private var statusLineLimit: Int {
        transcriptPreviewLayout?.lineLimit ?? 1
    }

    private var transcriptPreviewWidth: CGFloat {
        Theme.transcriptPreviewWidth(for: statusText)
    }

    private var transcriptPreviewIsVisible: Bool {
        transcriptPreviewText != nil
    }

    private var transcriptPreviewLayout: VoiceBarTranscriptPreviewLayout? {
        transcriptPreviewText.map(VoiceBarPresentation.transcriptPreviewLayout(for:))
    }

    private var transcriptPreviewText: String? {
        VoiceBarPresentation.transcriptPreviewText(
            mode: state.mode,
            confirmationText: state.confirmationText,
            commandModeState: state.commandModeState,
            activeClipMarker: state.activeClipMarker
        )
    }

    private var idleAccessoryButtonCount: Int {
        VoiceBarPresentation.idleAccessoryButtonCount(
            recentTranscriptions: state.recentTranscriptions,
            transcriptionVocabularyTerms: state.transcriptionVocabularyTerms,
            transcriptionVocabularyAliases: state.transcriptionVocabularyAliases,
            canReplay: state.canReplay
        )
    }

    // MARK: - Action buttons

    private var actionButtons: some View {
        HStack(spacing: 2) {
            if state.mode == .recording {
                pillButton(icon: "xmark") { commandRouter.handleCancel() }
                pillButton(icon: "stop.fill") { commandRouter.handleStop() }
            }
            if state.mode == .transcribing {
                pillButton(icon: "xmark") { commandRouter.handleCancel() }
            }
            if state.mode == .speaking {
                pillButton(icon: state.isTeleprompterDismissed ? "eye" : "eye.slash") {
                    if state.isTeleprompterDismissed {
                        state.showTeleprompter()
                    } else {
                        state.dismissTeleprompter()
                    }
                }
                pillButton(icon: "stop.fill") { commandRouter.handleStop() }
            }
            if state.mode == .error {
                pillButton(icon: "xmark") { state.dismissError() }
            }
            if state.mode == .idle, !state.recentTranscriptionEntries.isEmpty {
                historyButton
            }
            if state.mode == .idle,
               !state.transcriptionVocabularyTerms.isEmpty || !state.transcriptionVocabularyAliases.isEmpty {
                vocabularyButton
            }
            if state.mode == .idle, state.canReplay {
                pillButton(icon: "arrow.counterclockwise") { commandRouter.handleReplay() }
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
                    ForEach(Array(state.recentTranscriptionEntries.enumerated()), id: \.offset) { index, item in
                        let activeRetranscriptionPath = state.activeHistoryRetranscriptionPath
                        let isRetranscribing = item.recordingPath != nil &&
                            item.recordingPath == activeRetranscriptionPath

                        VStack(alignment: .leading, spacing: 4) {
                            HStack(alignment: .top, spacing: 8) {
                                if index == 0 {
                                    Text("Latest")
                                        .font(.system(size: 10, weight: .bold, design: .rounded))
                                        .foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                                HStack(spacing: 6) {
                                    historyActionButton(title: "Copy", isDisabled: isRetranscribing) {
                                        state.copyTranscript(item.text)
                                        isHistoryPresented = false
                                    }
                                    historyActionButton(title: "Paste", isDisabled: isRetranscribing) {
                                        state.repasteTranscript(item.text, source: "bar_history")
                                        isHistoryPresented = false
                                    }
                                    if let recordingPath = item.recordingPath {
                                        historyActionButton(title: "Re-transcribe", isDisabled: isRetranscribing) {
                                            commandRouter.handleRetranscribeHistoryEntry(recordingPath: recordingPath)
                                        }
                                    }
                                }
                            }
                            Text(item.text)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.primary)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)

                            if isRetranscribing {
                                HStack(spacing: 6) {
                                    ProcessingSpinner()
                                    Text("Re-transcribing...")
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 8)
                        .opacity(isRetranscribing ? 0.62 : 1)
                        .disabled(isRetranscribing)

                        if index < state.recentTranscriptionEntries.count - 1 {
                            Divider()
                        }
                    }
                }
            }
            .frame(width: 320, height: 220)
        }
        .padding(14)
    }

    private var vocabularyButton: some View {
        pillButton(icon: "text.book.closed") {
            isVocabularyPresented.toggle()
        }
        .popover(isPresented: $isVocabularyPresented, arrowEdge: .bottom) {
            vocabularyPopover
        }
    }

    private var vocabularyPopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Transcription Vocabulary")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)

            Text("Built-ins plus Wispr-derived hints used by local STT cleanup.")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if !state.transcriptionVocabularyTerms.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Preserved Terms (\(state.transcriptionVocabularyTerms.count))")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)

                            ForEach(Array(state.transcriptionVocabularyTerms.enumerated()),
                                    id: \.offset) { index, item in
                                VStack(alignment: .leading, spacing: 4) {
                                    if index == 0 {
                                        Text("Highest priority")
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
                                .padding(.vertical, 6)

                                if index < state.transcriptionVocabularyTerms.count - 1 {
                                    Divider()
                                }
                            }
                        }
                    }

                    if !state.transcriptionVocabularyAliases.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Learned Corrections (\(state.transcriptionVocabularyAliases.count))")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)

                            ForEach(Array(state.transcriptionVocabularyAliases.enumerated()),
                                    id: \.offset) { index, alias in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(alias.to)
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(.primary)
                                    Text(alias.from)
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundStyle(.secondary)
                                        .textSelection(.enabled)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 6)

                                if index < state.transcriptionVocabularyAliases.count - 1 {
                                    Divider()
                                }
                            }
                        }
                    }
                }
            }
            .frame(width: 320, height: 260)
        }
        .padding(14)
    }

    private func historyActionButton(
        title: String,
        isDisabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.primary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.primary.opacity(0.08))
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
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
