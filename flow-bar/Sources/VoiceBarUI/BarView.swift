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
        VoiceBarNotchControlOptics(pointSize: systemName == "stop.fill" ? 10 : 15, offsetX: 0, offsetY: 0)
    }

    /// The pre-P05 compact optics. P05's 26 pt system (`resolve`) is for the pill controls only;
    /// the agent-speech surface (teleprompter controls, the speaking wing's eye and Stop, and the
    /// non-button status glyph) keeps these, or eye and Stop crowd the waveform (#137 review).
    public static func legacyCompact(for systemName: String) -> Self {
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

private extension View {
    func notchAdaptiveGlyphEdge(_ color: Color) -> some View {
        shadow(color: color, radius: 0, x: -0.75, y: 0)
            .shadow(color: color, radius: 0, x: 0.75, y: 0)
            .shadow(color: color, radius: 0, x: 0, y: -0.75)
            .shadow(color: color, radius: 0, x: 0, y: 0.75)
    }
}

private struct VoiceBarPillPressStyle: ButtonStyle {
    var previewPressed = false

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed || previewPressed
        return configuration.label
            .scaleEffect(pressed ? 0.88 : 1)
            .opacity(pressed ? 0.78 : 1)
            .animation(.easeOut(duration: 0.12), value: pressed)
    }
}

struct VoiceBarPillControlButton: View {
    let icon: String
    let optics: VoiceBarNotchControlOptics
    let foreground: Color
    let halo: Color
    let isSelected: Bool
    let isDestructive: Bool
    let accessibilityLabel: String
    let accessibilityHint: String
    let action: () -> Void
    let previewHovered: Bool
    let previewPressed: Bool
    @State private var isHovered = false

    init(
        icon: String,
        optics: VoiceBarNotchControlOptics,
        foreground: Color,
        halo: Color,
        isSelected: Bool,
        isDestructive: Bool,
        accessibilityLabel: String,
        accessibilityHint: String,
        previewHovered: Bool = false,
        previewPressed: Bool = false,
        action: @escaping () -> Void
    ) {
        self.icon = icon
        self.optics = optics
        self.foreground = foreground
        self.halo = halo
        self.isSelected = isSelected
        self.isDestructive = isDestructive
        self.accessibilityLabel = accessibilityLabel
        self.accessibilityHint = accessibilityHint
        self.previewHovered = previewHovered
        self.previewPressed = previewPressed
        self.action = action
    }

    var body: some View {
        Button {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            action()
        } label: {
            glyph
                .offset(x: optics.offsetX, y: optics.offsetY)
                .frame(width: 26, height: 26)
                .background {
                    Circle()
                        .fill(isDestructive ? Theme.recordingColor
                            : isSelected ? Theme.recordingColor.opacity(0.30)
                            : isHovered || previewHovered || previewPressed ? foreground.opacity(0.12) : .clear)
                }
                .contentShape(Circle())
        }
        .buttonStyle(VoiceBarPillPressStyle(previewPressed: previewPressed))
        .onHover { isHovered = $0 }
        .padding(-3)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(accessibilityHint)
        .help(accessibilityLabel)
    }

    @ViewBuilder private var glyph: some View {
        let image = Image(systemName: icon)
            .font(.system(size: optics.pointSize, weight: .medium))
            .foregroundStyle(isDestructive ? Color.white : foreground)
        if isDestructive {
            image
        } else {
            image.notchAdaptiveGlyphEdge(halo)
        }
    }
}

// MARK: - Bar View

public struct BarView: View {
    public var state: VoiceState
    public var commandRouter: BarCommandRouting
    public var onOpenSettings: () -> Void
    public var onOpenHistory: () -> Void
    private let presentationModel: VoiceBarNotchPresentationModel?
    private let morphSelection: VoiceBarNotchMorphSelection?
    private let includesPanelOutsets: Bool
    @State private var errorDismissTask: Task<Void, Never>?
    @State private var isMorphTeleprompterContentPresented = false
    @State private var isHistoryPresented = false
    @State private var copyFeedback = NotchHistoryCopyFeedback()
    @State private var notchAppearance = VoiceBarNotchAppearance.dark
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion

    public var body: some View {
        if includesPanelOutsets {
            let canvas = VoiceBarNotchMorphCanvasLayout.resolve(for: notchPresentation)
            appearanceAwareNotchContent
                .frame(
                    width: canvas.canvasGeometry.totalWidth,
                    height: canvas.canvasGeometry.totalHeight,
                    alignment: .topLeading
                )
                .padding(.horizontal, 12)
                .padding(.bottom, 17)
        } else {
            appearanceAwareNotchContent
        }
    }

    public init(
        state: VoiceState,
        commandRouter: BarCommandRouting,
        onOpenSettings: @escaping () -> Void,
        onOpenHistory: @escaping () -> Void = {},
        presentationModel: VoiceBarNotchPresentationModel? = nil,
        morphSelection: VoiceBarNotchMorphSelection? = nil,
        includesPanelOutsets: Bool = false
    ) {
        _notchAppearance = State(
            initialValue: VoiceBarNotchAppearance(
                effectiveAppearance: NSApplication.shared.effectiveAppearance
            )
        )
        self.state = state
        self.commandRouter = commandRouter
        self.onOpenSettings = onOpenSettings
        self.onOpenHistory = onOpenHistory
        self.presentationModel = presentationModel
        self.morphSelection = morphSelection
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
        let canvas = VoiceBarNotchMorphCanvasLayout.resolve(for: notchPresentation)
        return VoiceBarNotchView(
            presentation: notchPresentation,
            appearance: notchAppearance,
            morphVariant: morphSelection?.variant ?? .p1Matched,
            canvasGeometry: includesPanelOutsets ? canvas.canvasGeometry : nil,
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
        .onChange(of: notchPresentation.visualState) { _, visualState in
            scheduleMorphTeleprompterContent(for: visualState)
        }
        .onChange(of: isHistoryPresented) { _, _ in
            synchronizeLauncherRetention()
        }
        .onChange(of: accessibilityReduceMotion) { _, isEnabled in
            presentationModel?.setReducedMotion(isEnabled)
        }
        .onAppear {
            presentationModel?.setHovered(state.isHovering)
            synchronizeLauncherRetention()
            presentationModel?.setReducedMotion(accessibilityReduceMotion)
            isMorphTeleprompterContentPresented = notchPresentation.visualState == .teleprompter
        }
        .onChange(of: state.recentTranscriptionEntries.count) { _, count in
            if count == 0 {
                isHistoryPresented = false
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
        isHistoryPresented
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
            HStack(spacing: VoiceBarNotchContract.material.compactControlSpacing) {
                notchButton(
                    icon: "stop.fill",
                    isDestructive: true,
                    accessibilityLabel: "Stop recording",
                    accessibilityHint: "Stop the VoiceBar recording"
                ) {
                    commandRouter.handleStop()
                }
                notchButton(icon: "xmark", accessibilityLabel: "Cancel recording") {
                    commandRouter.handleCancel()
                }
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
            }
        case .compactStatus:
            if state.mode == .transcribing {
                ProcessingSpinner()
            } else {
                statusIcon
            }
        case .teleprompter:
            EmptyView()
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
                settingsButton
            }
        case .recording:
            notchWaveform
        case .compactStatus:
            notchCompactStatusContent
        case .teleprompter:
            if state.mode == .speaking {
                notchWaveform
            }
        }
    }

    @ViewBuilder
    private var notchCompactStatusContent: some View {
        switch state.mode {
        case .transcribing:
            HStack(spacing: VoiceBarNotchContract.material.compactControlSpacing) {
                notchWaveform
                notchButton(icon: "xmark", accessibilityLabel: "Cancel transcription") {
                    commandRouter.handleCancel()
                }
            }
        case .speaking:
            HStack(spacing: VoiceBarNotchContract.material.compactControlSpacing) {
                notchWaveform
                if state.isTeleprompterDismissed {
                    notchTeleprompterButton(
                        icon: "eye",
                        accessibilityLabel: "Show teleprompter"
                    ) {
                        state.showTeleprompter()
                    }
                }
                notchTeleprompterButton(
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

    private var notchWaveform: some View {
        VoiceBarNotchWaveform(
            mode: state.mode,
            isListening: !state.speechDetected,
            isCaptureLive: state.captureLive,
            recordingLevel: { state.recordingWaveformLevel },
            playbackLevel: { state.playbackAudioLevel() }
        )
    }

    @ViewBuilder
    private var notchLowerContent: some View {
        if isMorphTeleprompterContentPresented {
            VStack(spacing: 12) {
                notchTeleprompterTimeline
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                notchTeleprompterControls
            }
            .padding(
                .horizontal,
                VoiceBarNotchContract.material.teleprompterBodyHorizontalInset
            )
            .padding(.top, 16)
            .padding(.bottom, 14)
            .transition(.opacity)
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
                    playbackEpoch: state.playbackEpoch,
                    playbackElapsedMilliseconds: state.playbackElapsedMilliseconds,
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
            if state.queuedSpeakCount > 0 {
                Text("+\(state.queuedSpeakCount) queued")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(notchPalette.secondary.color)
                    .accessibilityLabel("\(state.queuedSpeakCount) queued speeches")
            }
            if state.canReplay {
                notchTeleprompterButton(
                    icon: "arrow.counterclockwise",
                    accessibilityLabel: "Replay"
                ) {
                    commandRouter.handleReplay()
                }
            }
            notchTeleprompterButton(
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
                notchTeleprompterButton(
                    icon: "stop.fill",
                    isDestructive: true,
                    accessibilityLabel: "Stop speaking"
                ) {
                    commandRouter.handleStop()
                }
            }
            if state.isTeleprompterReadback {
                notchTeleprompterButton(icon: "xmark", accessibilityLabel: "Dismiss teleprompter") {
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
        }
    }

    private func scheduleMorphTeleprompterContent(
        for visualState: VoiceBarNotchVisualState
    ) {
        guard visualState == .teleprompter else {
            withAnimation(
                .easeOut(duration: VoiceBarNotchContract.motion.contentExitDuration)
            ) {
                isMorphTeleprompterContentPresented = false
            }
            return
        }

        withAnimation(
            .easeOut(duration: VoiceBarNotchContract.motion.contentExitDuration)
                .delay(VoiceBarNotchContract.motion.panelDelay)
        ) {
            isMorphTeleprompterContentPresented = true
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

    // MARK: - Status icon

    @ViewBuilder
    private var statusIcon: some View {
        if state.mode == .idle || state.mode == .error {
            notchButton(
                icon: iconName,
                accessibilityLabel: state.mode == .error
                    ? "Retry voice recording"
                    : "Start voice recording"
            ) {
                commandRouter.handlePrimaryTap()
            }
        } else {
            statusIconImage
        }
    }

    private var statusIconImage: some View {
        let optics = VoiceBarNotchControlOptics.legacyCompact(for: iconName)
        return Image(systemName: iconName)
            .font(.system(size: optics.pointSize, weight: .semibold))
            .foregroundStyle(
                state.mode == .idle ? notchPrimaryLabelColor : Theme.stateColor(for: state.mode)
            )
            .notchAdaptiveGlyphEdge(notchGlyphContrastHaloColor)
            .offset(x: optics.offsetX, y: optics.offsetY)
            .frame(
                width: VoiceBarNotchContract.material.compactControlSize,
                height: VoiceBarNotchContract.material.compactControlSize
            )
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
            .layoutPriority(1)
            .transaction { transaction in
                transaction.animation = nil
            }
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

    private var notchGlyphContrastHaloColor: Color {
        VoiceBarNotchGlyphContrastTreatment.resolve(for: notchAppearance).color
    }

    private var historyButton: some View {
        notchButton(icon: "clock.arrow.circlepath", accessibilityLabel: "History") {
            isHistoryPresented.toggle()
        }
        .popover(isPresented: $isHistoryPresented, arrowEdge: .bottom) {
            historyPopover
        }
    }

    private var settingsButton: some View {
        notchButton(icon: "gearshape", accessibilityLabel: "Settings") {
            onOpenSettings()
        }
    }

    var historyPopover: some View {
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
                                if let header = NotchHistoryPresentation.rowHeader(for: item) {
                                    Text(header)
                                        .font(.system(size: 10, weight: .bold, design: .rounded))
                                        .foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                                HStack(spacing: 6) {
                                    // Copy stays open and says so (R4 UI pass #13: the pressed state was
                                    // the only feedback).
                                    historyActionButton(
                                        title: NotchHistoryPresentation
                                            .copyTitle(isCopied: copyFeedback.isCopied(row: index)),
                                        isDisabled: isRetranscribing
                                    ) {
                                        if state.copyTranscript(item.text) {
                                            showCopied(index)
                                        }
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

            Divider()
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(NotchHistoryPresentation.pasteHint)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                Button(NotchHistoryPresentation.openHistoryTitle) {
                    isHistoryPresented = false
                    onOpenHistory()
                }
                .buttonStyle(.link)
                .font(.system(size: 11, weight: .semibold))
            }
        }
        .padding(14)
    }

    private func showCopied(_ index: Int) {
        let generation = copyFeedback.copied(row: index)
        Task { @MainActor in
            try? await Task.sleep(for: NotchHistoryPresentation.copiedFeedbackDuration)
            copyFeedback.expire(generation)
        }
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
        let foregroundRole = VoiceBarNotchGlyphForegroundRole.resolve(
            isDestructive: isDestructive,
            isSelected: isSelected
        )
        return VoiceBarPillControlButton(
            icon: icon,
            optics: optics,
            foreground: foregroundRole == .stateAccent ? Theme.recordingColor : notchPrimaryLabelColor,
            halo: notchGlyphContrastHaloColor,
            isSelected: isSelected,
            isDestructive: isDestructive && icon == "stop.fill",
            accessibilityLabel: accessibilityLabel ?? icon,
            accessibilityHint: accessibilityHint ?? "",
            action: action
        )
    }

    private func notchTeleprompterButton(
        icon: String,
        isDestructive: Bool = false,
        accessibilityLabel: String,
        action: @escaping () -> Void
    ) -> some View {
        let pointSize = VoiceBarNotchControlOptics.legacyCompact(for: icon).pointSize
        let hasStopContainer = isDestructive && icon == "stop.fill"
        return Button {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            action()
        } label: {
            Image(systemName: icon)
                .font(.system(size: pointSize, weight: .semibold))
                .foregroundStyle(hasStopContainer ? Color.white : notchPrimaryLabelColor)
                .notchAdaptiveGlyphEdge(notchGlyphContrastHaloColor)
                .frame(
                    width: VoiceBarNotchContract.material.compactControlSize,
                    height: VoiceBarNotchContract.material.compactControlSize
                )
                .background {
                    if hasStopContainer {
                        Circle().fill(Theme.recordingColor)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
        .help(accessibilityLabel)
    }
}
