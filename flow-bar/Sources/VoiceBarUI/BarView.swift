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
    @Environment(\.voiceBarNotchAppearance) private var notchAppearance

    public var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(
                VoiceBarNotchContrastPalette
                    .resolve(for: notchAppearance)
                    .primary.color
            )
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

public struct VoiceBarNotchControlOptics: Equatable {
    public let pointSize: CGFloat
    public let offsetX: CGFloat
    public let offsetY: CGFloat

    public static func resolve(for systemName: String) -> Self {
        switch systemName {
        case "eye", "eye.slash":
            VoiceBarNotchControlOptics(pointSize: 8.5, offsetX: 0, offsetY: 0)
        case "arrow.counterclockwise":
            VoiceBarNotchControlOptics(pointSize: 9.5, offsetX: 0, offsetY: 0)
        case "stop.fill":
            VoiceBarNotchControlOptics(pointSize: 8, offsetX: 0, offsetY: 0)
        default:
            VoiceBarNotchControlOptics(pointSize: 10, offsetX: 0, offsetY: 0)
        }
    }
}

// MARK: - Bar View

public struct BarView: View {
    public var state: VoiceState
    public var commandRouter: BarCommandRouting
    private let presentationModel: VoiceBarNotchPresentationModel?
    private let includesPanelOutsets: Bool
    @State private var errorDismissTask: Task<Void, Never>?
    @State private var isHistoryPresented = false
    @State private var isVocabularyPresented = false
    @State private var notchAppearance = VoiceBarNotchAppearance.dark
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion

    public var body: some View {
        if includesPanelOutsets {
            appearanceAwareNotchContent
                .padding(.horizontal, 12)
                .padding(.bottom, 17)
        } else {
            appearanceAwareNotchContent
        }
    }

    public init(
        state: VoiceState,
        commandRouter: BarCommandRouting,
        presentationModel: VoiceBarNotchPresentationModel? = nil,
        includesPanelOutsets: Bool = false
    ) {
        _notchAppearance = State(
            initialValue: VoiceBarNotchAppearance(
                effectiveAppearance: NSApplication.shared.effectiveAppearance
            )
        )
        self.state = state
        self.commandRouter = commandRouter
        self.presentationModel = presentationModel
        self.includesPanelOutsets = includesPanelOutsets
    }

    // MARK: - Native notch shell

    private var appearanceAwareNotchContent: some View {
        notchContent
            .environment(\.voiceBarNotchAppearance, notchAppearance)
            .background {
                VoiceBarNotchAppearanceReader(appearance: $notchAppearance)
                    .frame(width: 0, height: 0)
                    .allowsHitTesting(false)
            }
    }

    private var notchContent: some View {
        VoiceBarNotchView(
            presentation: notchPresentation,
            onHoverChanged: { hovering in
                guard !includesPanelOutsets else { return }
                state.setHovering(hovering)
                presentationModel?.setHovered(hovering)
            },
            leadingContent: {
                notchLeadingContent
            },
            trailingContent: {
                notchTrailingContent
            },
            lowerContent: {
                notchLowerContent
            }
        )
        .onChange(of: state.mode) { _, newMode in
            handleModeChange(newMode)
        }
        .onChange(of: isHistoryPresented) { _, _ in
            synchronizeLauncherRetention()
        }
        .onChange(of: isVocabularyPresented) { _, _ in
            synchronizeLauncherRetention()
        }
        .onChange(of: accessibilityReduceMotion) { _, isEnabled in
            presentationModel?.setReducedMotion(isEnabled)
        }
        .onAppear {
            presentationModel?.setHovered(state.isHovering)
            synchronizeLauncherRetention()
            presentationModel?.setReducedMotion(accessibilityReduceMotion)
        }
        .onChange(of: state.recentTranscriptionEntries.count) { _, count in
            if count == 0 {
                isHistoryPresented = false
            }
        }
        .onChange(of: state.transcriptionVocabularyTerms.count) { _, count in
            if count == 0, state.transcriptionVocabularyAliases.isEmpty {
                isVocabularyPresented = false
            }
        }
        .onChange(of: state.transcriptionVocabularyAliases.count) { _, count in
            if count == 0, state.transcriptionVocabularyTerms.isEmpty {
                isVocabularyPresented = false
            }
        }
    }

    private var notchPresentation: VoiceBarNotchPresentation {
        if let presentationModel {
            return presentationModel.presentation
        }

        return VoiceBarPresentation.notchPresentation(
            from: VoiceBarNotchOperationalInput(
                mode: state.mode,
                showsRecordingHold: recordingHoldControl != nil,
                hasTeleprompterText: state.teleprompterText != nil,
                isTeleprompterDismissed: state.isTeleprompterDismissed,
                isTeleprompterReadback: state.isTeleprompterReadback,
                confirmationText: state.confirmationText,
                commandModeState: state.commandModeState,
                activeClipMarker: state.activeClipMarker,
                queueDepth: state.queueDepth,
                keepsPasteFlowEnvelope: state.keepsPasteFlowEnvelope,
                hotkeyPhase: state.hotkeyPhase,
                statusText: statusText,
                isHovered: state.isHovering,
                isKeyboardFocused: keepsLauncherMounted,
                isCollapsed: state.isCollapsed,
                visibleCoreOcclusionInset: 0
            )
        )
    }

    private var keepsLauncherMounted: Bool {
        isHistoryPresented || isVocabularyPresented
    }

    private func synchronizeLauncherRetention() {
        presentationModel?.setKeyboardFocused(keepsLauncherMounted)
    }

    @ViewBuilder
    private var notchLeadingContent: some View {
        switch notchPresentation.visualState {
        case .idle:
            EmptyView()
        case .hoverLauncher:
            notchButton(
                icon: "mic.fill",
                accessibilityLabel: "Start voice recording"
            ) {
                commandRouter.handlePrimaryTap()
            }
        case .recording:
            HStack(spacing: VoiceBarNotchContract.material.recordingIndicatorSpacing) {
                PulsingDot()
                Image(systemName: "mic.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(notchPrimaryLabelColor)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Recording")
        case .compactStatus:
            if state.mode == .transcribing {
                ProcessingSpinner()
            } else {
                statusIcon
            }
        case .teleprompter:
            Image(systemName: "book.closed")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(notchPrimaryLabelColor)
                .accessibilityLabel("Teleprompter")
        }
    }

    @ViewBuilder
    private var notchTrailingContent: some View {
        switch notchPresentation.visualState {
        case .idle:
            EmptyView()
        case .hoverLauncher:
            HStack(spacing: VoiceBarNotchContract.material.compactControlSpacing) {
                historyButton
                vocabularyButton
            }
        case .recording:
            HStack(spacing: VoiceBarNotchContract.material.compactControlSpacing) {
                notchStableWaveform
                if let recordingHoldControl {
                    notchButton(
                        icon: recordingHoldControl.iconName,
                        isSelected: recordingHoldControl.isSelected,
                        accessibilityLabel: recordingHoldControl.accessibilityLabel,
                        accessibilityHint: recordingHoldControl.accessibilityHint
                    ) {
                        state.setRecordingHold(!state.isRecordingHoldEngaged)
                    }
                }
                notchButton(icon: "xmark", accessibilityLabel: "Cancel recording") {
                    commandRouter.handleCancel()
                }
                notchButton(
                    icon: "stop.fill",
                    isDestructive: true,
                    accessibilityLabel: "Stop recording"
                ) {
                    commandRouter.handleStop()
                }
            }
        case .compactStatus:
            notchCompactStatusContent
        case .teleprompter:
            if state.mode == .speaking {
                notchStableWaveform
            }
        }
    }

    @ViewBuilder
    private var notchCompactStatusContent: some View {
        switch state.mode {
        case .transcribing:
            HStack(spacing: VoiceBarNotchContract.material.compactControlSpacing) {
                notchStableWaveform
                notchButton(icon: "xmark", accessibilityLabel: "Cancel transcription") {
                    commandRouter.handleCancel()
                }
            }
        case .speaking:
            HStack(spacing: 4) {
                if state.isTeleprompterDismissed {
                    notchButton(
                        icon: "eye",
                        accessibilityLabel: "Show teleprompter"
                    ) {
                        state.showTeleprompter()
                    }
                }
                notchStableWaveform
                notchButton(
                    icon: "stop.fill",
                    isDestructive: true,
                    accessibilityLabel: "Stop speaking"
                ) {
                    commandRouter.handleStop()
                }
            }
        case .error:
            HStack(spacing: 3) {
                statusLabel
                notchButton(icon: "xmark", accessibilityLabel: "Dismiss error") {
                    state.dismissError()
                }
            }
        case .idle:
            HStack(spacing: 4) {
                if state.queueDepth > 0 {
                    queueBadge
                }
                statusLabel
            }
        case .disconnected:
            statusLabel
        case .recording:
            EmptyView()
        }
    }

    @ViewBuilder
    private var notchStableWaveform: some View {
        switch state.mode {
        case .recording:
            WaveformView(
                color: Theme.recordingColor,
                isListening: !state.speechDetected,
                currentLevel: { state.recordingWaveformLevel }
            )
        case .transcribing:
            WaveformView(processingColor: Theme.stateColor(for: .transcribing))
        case .speaking:
            WaveformView(color: Theme.speakingColor, currentLevel: {
                state.playbackAudioLevel()
            })
        case .idle, .disconnected, .error:
            EmptyView()
        }
    }

    @ViewBuilder
    private var notchLowerContent: some View {
        if notchPresentation.visualState == .teleprompter {
            VStack(spacing: 12) {
                Group {
                    if state.queueItems.count > 1 {
                        queueVisualization
                    } else {
                        notchTeleprompterTimeline
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                notchTeleprompterControls
            }
            .padding(
                .horizontal,
                VoiceBarNotchContract.material.teleprompterBodyHorizontalInset
            )
            .padding(.top, 16)
            .padding(.bottom, 14)
        }
    }

    @ViewBuilder
    private var notchTeleprompterTimeline: some View {
        if let text = state.teleprompterText,
           TeleprompterVisibilityPolicy.keepsTimelineMounted(hasText: !text.isEmpty) {
            ZStack {
                TeleprompterView(
                    text: text,
                    wordBoundaries: state.teleprompterWordBoundaries,
                    isReadback: state.isTeleprompterReadback,
                    wrapWidth: VoiceBarNotchContract.material.teleprompterTextWidth(
                        coreWidth: notchPresentation.geometry.coreWidth
                    ),
                    contentInset: VoiceBarNotchContract.material.teleprompterTextInnerInset
                )
                .opacity(
                    TeleprompterVisibilityPolicy.timelineOpacity(
                        isDismissed: state.isTeleprompterDismissed
                    )
                )
                .accessibilityHidden(state.isTeleprompterDismissed)

                Text("Teleprompter hidden")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(notchPalette.tertiary.color)
                    .opacity(
                        TeleprompterVisibilityPolicy.hiddenLabelOpacity(
                            isDismissed: state.isTeleprompterDismissed
                        )
                    )
                    .accessibilityHidden(!state.isTeleprompterDismissed)
            }
        }
    }

    private var notchTeleprompterControls: some View {
        HStack(spacing: 10) {
            if state.canReplay {
                notchButton(
                    icon: "arrow.counterclockwise",
                    accessibilityLabel: "Replay"
                ) {
                    commandRouter.handleReplay()
                }
            }
            notchButton(
                icon: state.isTeleprompterDismissed ? "eye" : "eye.slash",
                accessibilityLabel: state.isTeleprompterDismissed
                    ? "Show teleprompter"
                    : "Hide teleprompter"
            ) {
                if state.isTeleprompterDismissed {
                    state.showTeleprompter()
                } else {
                    state.dismissTeleprompter()
                }
            }
            if state.mode == .speaking {
                notchButton(
                    icon: "stop.fill",
                    isDestructive: true,
                    accessibilityLabel: "Stop speaking"
                ) {
                    commandRouter.handleStop()
                }
            }
            if state.isTeleprompterReadback {
                notchButton(icon: "xmark", accessibilityLabel: "Dismiss teleprompter") {
                    state.dismissRetainedTeleprompter()
                }
            }
        }
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

    private var queueBadge: some View {
        Text("\(state.queueDepth)")
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .foregroundStyle(notchPrimaryLabelColor)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Theme.speakingColor.opacity(0.22))
            .clipShape(Capsule())
            .contentTransition(.numericText())
    }

    private var queueVisualization: some View {
        let preview = VoiceBarPresentation.queuePreview(from: state.queueItems)

        return VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Text("Queue")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(notchPalette.secondary.color)
                if preview.overflowCount > 0 {
                    Text("+\(preview.overflowCount) more")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(notchPalette.tertiary.color)
                }
            }

            Text(preview.currentText)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(notchPalette.primary.color)
                .lineLimit(1)
                .truncationMode(.tail)

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(notchPalette.subtleTrack.color)
                    Capsule()
                        .fill(Theme.speakingColor.opacity(0.95))
                        .frame(width: max(10, geometry.size.width * preview.progress))
                }
                .animation(Theme.queueProgressTransition, value: preview.progress)
            }
            .frame(height: 4)

            if let nextText = preview.nextText {
                HStack(spacing: 6) {
                    Text("Up next")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(notchPalette.tertiary.color)
                    Text(nextText)
                        .font(.system(size: 11))
                        .foregroundStyle(notchPalette.secondary.color)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(Theme.stateColor(for: state.mode))
            .frame(width: 18)
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
        Text(statusText)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(notchPrimaryLabelColor)
            .lineLimit(1)
            .truncationMode(.tail)
            .contentTransition(.opacity)
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

    private var transcriptPreviewText: String? {
        VoiceBarPresentation.transcriptPreviewText(
            mode: state.mode,
            confirmationText: state.confirmationText,
            commandModeState: state.commandModeState,
            activeClipMarker: state.activeClipMarker
        )
    }

    private var recordingHoldControl: VoiceBarRecordingHoldControl? {
        VoiceBarPresentation.recordingHoldControl(
            mode: state.mode,
            recordingMode: state.recordingMode,
            isEngaged: state.isRecordingHoldEngaged
        )
    }

    private var notchPalette: VoiceBarNotchContrastPalette {
        VoiceBarNotchContrastPalette.resolve(for: notchAppearance)
    }

    /// Resolve the foreground from the same settled appearance signal as the
    /// compact glass. NSColor.labelColor can retain the hosting panel's prior
    /// appearance for one frame, camouflaging controls after a live toggle.
    private var notchPrimaryLabelColor: Color {
        notchPalette.primary.color
    }

    private var historyButton: some View {
        notchButton(icon: "clock.arrow.circlepath", accessibilityLabel: "History") {
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
        notchButton(icon: "text.book.closed", accessibilityLabel: "Dictionary") {
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

    private func notchButton(
        icon: String,
        isSelected: Bool = false,
        isDestructive: Bool = false,
        accessibilityLabel: String? = nil,
        accessibilityHint: String? = nil,
        action: @escaping () -> Void
    ) -> some View {
        let optics = VoiceBarNotchControlOptics.resolve(for: icon)
        let hasStopContainer = isDestructive && icon == "stop.fill"
        let foregroundRole = VoiceBarNotchGlyphForegroundRole.resolve(
            isDestructive: isDestructive,
            isSelected: isSelected
        )
        return Button {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            action()
        } label: {
            Image(systemName: icon)
                .font(.system(size: optics.pointSize, weight: .semibold))
                .foregroundStyle(
                    hasStopContainer
                        ? Color.white
                        : foregroundRole == .stateAccent
                        ? Theme.recordingColor
                        : notchPrimaryLabelColor
                )
                .offset(x: optics.offsetX, y: optics.offsetY)
                .frame(
                    width: VoiceBarNotchContract.material.compactControlSize,
                    height: VoiceBarNotchContract.material.compactControlSize
                )
                .background {
                    if hasStopContainer {
                        Circle()
                            .fill(Theme.recordingColor)
                    } else if isSelected {
                        Circle()
                            .fill(Theme.recordingColor.opacity(0.30))
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel ?? icon)
        .accessibilityHint(accessibilityHint ?? "")
        .help(accessibilityLabel ?? icon)
    }
}
