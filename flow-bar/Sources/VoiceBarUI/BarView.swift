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
    @Environment(\.visualRenderTime) private var renderTime
    public static let defaultDiameter: CGFloat = 14

    private let size: CGFloat
    private let showsTrack: Bool

    public init() {
        self.init(diameter: Self.defaultDiameter, showsTrack: false)
    }

    init(diameter: CGFloat, showsTrack: Bool) {
        size = diameter
        self.showsTrack = showsTrack
    }

    public var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: renderTime != nil)) { timeline in
            ProcessingSpinnerFrame(
                angle: (renderTime ?? timeline.date.timeIntervalSinceReferenceDate) * 360,
                diameter: size,
                showsTrack: showsTrack
            )
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// One frame of `ProcessingSpinner` at a fixed angle, so a test can render any point of the turn.
struct ProcessingSpinnerFrame: View {
    let angle: Double
    let diameter: CGFloat
    var showsTrack = false

    var body: some View {
        ZStack {
            if showsTrack {
                Circle()
                    .stroke(Theme.speakingColor.opacity(0.28), lineWidth: 2.2)
            }
            Circle()
                .trim(from: 0.08, to: 0.74)
                .stroke(
                    Theme.speakingColor.opacity(0.98),
                    style: StrokeStyle(lineWidth: 2.2, lineCap: .round)
                )
                .rotationEffect(.degrees(angle))
        }
        .frame(width: diameter, height: diameter)
    }
}

public struct VoiceBarNotchControlOptics: Equatable {
    public let pointSize: CGFloat
    public let offsetX: CGFloat
    public let offsetY: CGFloat

    /// Sized for the plate, which fills the 20 pt layout slot (C1: the 26 pt plate and 15 pt glyphs
    /// made Stop and X touch). Scaled from P05's 10/15 on 26 by 20/26.
    public static func resolve(for systemName: String) -> Self {
        VoiceBarNotchControlOptics(pointSize: systemName == "stop.fill" ? 8 : 12, offsetX: 0, offsetY: 0)
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
    let selectionStyle: VoiceBarNotchSelectionStyle
    let isDestructive: Bool
    let accessibilityLabel: String
    let accessibilityHint: String
    let tooltip: String?
    let action: () -> Void
    let previewHovered: Bool
    let previewPressed: Bool
    @State private var isHovered = false

    /// The drawn plate fills the layout slot; the invisible hit circle overhangs it by `hitOverhang` per side.
    static let plateDiameter = VoiceBarNotchContract.material.compactControlSize
    static let hitDiameter: CGFloat = 26
    static var hitOverhang: CGFloat {
        (hitDiameter - plateDiameter) / 2
    }

    init(
        icon: String,
        optics: VoiceBarNotchControlOptics,
        foreground: Color,
        halo: Color,
        isSelected: Bool,
        selectionStyle: VoiceBarNotchSelectionStyle = .navigation,
        isDestructive: Bool,
        accessibilityLabel: String,
        accessibilityHint: String,
        tooltip: String? = nil,
        previewHovered: Bool = false,
        previewPressed: Bool = false,
        action: @escaping () -> Void
    ) {
        self.icon = icon
        self.optics = optics
        self.foreground = foreground
        self.halo = halo
        self.isSelected = isSelected
        self.selectionStyle = selectionStyle
        self.isDestructive = isDestructive
        self.accessibilityLabel = accessibilityLabel
        self.accessibilityHint = accessibilityHint
        self.tooltip = tooltip ?? accessibilityLabel
        self.previewHovered = previewHovered
        self.previewPressed = previewPressed
        self.action = action
    }

    var body: some View {
        Button {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            action()
        } label: {
            // The plate is drawn at the layout slot, so neighbours keep the slot spacing between them;
            // only the invisible hit circle stays 26 pt (it overhangs the slot by the -3 padding).
            glyph
                .offset(x: optics.offsetX, y: optics.offsetY)
                .frame(width: Self.plateDiameter, height: Self.plateDiameter)
                .background {
                    Circle().fill(plateColor)
                }
                // C3: a selected plate and its glyph colour ease in and out instead of snapping.
                .animation(.easeOut(duration: 0.2), value: isSelected)
                .frame(width: Self.hitDiameter, height: Self.hitDiameter)
                .contentShape(Circle())
        }
        .buttonStyle(VoiceBarPillPressStyle(previewPressed: previewPressed))
        .onHover { isHovered = $0 }
        .padding(-Self.hitOverhang)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(accessibilityHint)
        .background(PillControlTooltip(text: tooltip))
    }

    private var plateColor: Color {
        switch VoiceBarNotchControlPlate.resolve(
            isDestructive: isDestructive,
            isSelected: isSelected,
            selectionStyle: selectionStyle,
            isHovered: isHovered || previewHovered || previewPressed
        ) {
        case .recordingSolid: Theme.recordingColor
        case .recordingSelected: Theme.recordingColor.opacity(0.30)
        // UX pass #3: a neutral plate in the glyph's own colour, a step above hover so "open" reads as open.
        case .neutralSelected: foreground.opacity(0.18)
        case .hover: foreground.opacity(0.12)
        case .none: .clear
        }
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

// Native registration stays attached to the control inside the nested glass host.
// Avoid resetting AppKit's hover delay on unrelated playback/hover redraws.
struct PillControlTooltip: NSViewRepresentable {
    let text: String?

    func makeNSView(context: Context) -> TooltipView {
        let view = TooltipView()
        view.toolTip = text
        return view
    }

    func updateNSView(_ view: TooltipView, context: Context) {
        if view.toolTip != text { view.toolTip = text }
    }

    final class TooltipView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

// Test instrumentation attaches to the production compact Stop, never to a shell stand-in.
struct PlaybackStopHostProbeKey: EnvironmentKey {
    static let defaultValue: AnyView = AnyView(EmptyView())
}

extension EnvironmentValues {
    var playbackStopHostProbe: AnyView {
        get { self[PlaybackStopHostProbeKey.self] }
        set { self[PlaybackStopHostProbeKey.self] = newValue }
    }
}

// MARK: - Bar View

public struct BarView: View {
    @Environment(\.playbackStopHostProbe) private var playbackStopHostProbe

    public var state: VoiceState
    public var commandRouter: BarCommandRouting
    public var onOpenSettings: () -> Void
    public var onOpenHistory: () -> Void
    private let presentationModel: VoiceBarNotchPresentationModel?
    private let morphSelection: VoiceBarNotchMorphSelection?
    private let includesPanelOutsets: Bool
    /// Visual shots only: render one History row as hovered without a pointer.
    private var historyForcedHoverIndex: Int?
    @State private var errorDismissTask: Task<Void, Never>?
    @State private var isMorphTeleprompterContentPresented = false
    @State private var isMorphHistoryContentPresented = false
    @State private var isHistoryPresented = false
    @State private var historyDismissal: NotchHistoryDismissal?
    @State private var hostWindow = HostWindowBox()
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
        onOpenHistory: @escaping () -> Void,
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
        .onChange(of: isHistoryPresented) { _, isOpen in
            synchronizeLauncherRetention()
            presentationModel?.setHistoryPanelOpen(isOpen)
            synchronizeHistoryDismissal(isOpen: isOpen)
        }
        .onDisappear {
            historyDismissal?.stop()
        }
        .background(HostWindowReader { window in hostWindow.window = window })
        .onChange(of: accessibilityReduceMotion) { _, isEnabled in
            presentationModel?.setReducedMotion(isEnabled)
        }
        .onAppear {
            presentationModel?.setHovered(state.isHovering)
            synchronizeLauncherRetention()
            presentationModel?.setReducedMotion(accessibilityReduceMotion)
            isMorphTeleprompterContentPresented = notchPresentation.visualState == .teleprompter
            isMorphHistoryContentPresented = notchPresentation.visualState == .history
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

        var input = VoiceBarNotchOperationalInput(
            mode: state.mode,
            showsRecordingHold: recordingHoldControl != nil,
            hasTeleprompterText: state.teleprompterText != nil,
            isTeleprompterDismissed: state.isTeleprompterDismissed,
            isTeleprompterReadback: state.isTeleprompterReadback,
            isPlaybackPaused: state.isPlaybackPaused,
            readQueueLeadingSlotCount: VoiceBarPresentation.readQueueControl(for: state)?.leadingSlotCount ?? 1,
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
            visibleCoreOcclusionInset: 0,
            transientNote: state.selectionFeedbackNote
        )
        input.isHistoryPanelOpen = isHistoryPresented
        return VoiceBarPresentation.notchPresentation(from: input)
    }

    private var keepsLauncherMounted: Bool {
        isHistoryPresented
    }

    /// Click-away and Esc close the History panel, as the transient popover did (#166 review).
    private func synchronizeHistoryDismissal(isOpen: Bool) {
        guard isOpen else {
            historyDismissal?.stop()
            return
        }
        if historyDismissal == nil {
            historyDismissal = NotchHistoryDismissal { isHistoryPresented = false }
        }
        historyDismissal?.panelWindow = hostWindow.window
        historyDismissal?.start()
    }

    private func synchronizeLauncherRetention() {
        presentationModel?.setKeyboardFocused(keepsLauncherMounted)
    }

    @ViewBuilder
    private var notchLeadingContent: some View {
        switch notchPresentation.visualState {
        case .idle:
            EmptyView()
        case .hoverLauncher, .history:
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
                        selectionStyle: .recordingState,
                        accessibilityLabel: recordingHoldControl.accessibilityLabel,
                        accessibilityHint: recordingHoldControl.accessibilityHint
                    ) {
                        state.setRecordingHold(!state.isRecordingHoldEngaged)
                    }
                }
            }
        case .compactStatus, .teleprompter:
            if notchPresentation.visualState == .compactStatus, state.mode == .transcribing {
                ProcessingSpinner()
            } else if let playbackPauseControl {
                playbackLeadingControls(playbackPauseControl)
            } else if notchPresentation.visualState == .compactStatus,
                      state.mode == .idle, VoiceBarPresentation.readQueueControl(for: state) != nil {
                playbackLeadingControls(nil)
            } else if notchPresentation.visualState == .compactStatus {
                statusIcon
            }
        }
    }

    private var playbackPauseControl: VoiceBarPlaybackPauseControl? {
        VoiceBarPresentation.playbackPauseControl(
            mode: state.mode,
            isPaused: state.isPlaybackPaused,
            isReadback: state.isTeleprompterReadback
        )
    }

    /// QUEUE1: pause/play, then Next and the "+N" count toward the core; one control slot each so the hit rects match.
    private func playbackLeadingControls(_ pause: VoiceBarPlaybackPauseControl?) -> some View {
        HStack(spacing: VoiceBarNotchContract.material.compactControlSpacing) {
            if let pause { playbackPauseButton(pause) }
            if let readQueueControl = VoiceBarPresentation.readQueueControl(for: state) {
                notchButton(
                    icon: readQueueControl.iconName,
                    accessibilityLabel: readQueueControl.accessibilityLabel,
                    accessibilityHint: readQueueControl.accessibilityHint
                ) {
                    state.skipToNextRead()
                }
                if let countLabel = readQueueControl.countLabel {
                    countBadge(countLabel, slotWidth: VoiceBarNotchContract.material.compactControlSize)
                        .accessibilityLabel("\(state.readQueueCount) queued")
                }
            }
        }
        .animation(.easeOut(duration: 0.2), value: state.readQueueCount)
    }

    /// P16: Pause collapses the teleprompter and Play expands it again; the shell's own morph animates both.
    private func playbackPauseButton(_ control: VoiceBarPlaybackPauseControl) -> some View {
        notchButton(
            icon: control.iconName,
            accessibilityLabel: control.accessibilityLabel,
            accessibilityHint: control.accessibilityHint
        ) {
            state.togglePlaybackPause()
        }
        .contentTransition(.symbolEffect(.replace))
    }

    @ViewBuilder
    private var notchTrailingContent: some View {
        switch notchPresentation.visualState {
        case .idle:
            EmptyView()
        case .hoverLauncher, .history:
            HStack(spacing: VoiceBarNotchContract.material.compactControlSpacing) {
                historyButton
                settingsButton
            }
        case .recording:
            notchWaveform
        case .compactStatus, .teleprompter:
            if state.mode == .speaking {
                notchSpeakingTrailingContent
            } else if notchPresentation.visualState == .compactStatus {
                notchCompactStatusContent
            } else if state.isTeleprompterReadback {
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
            notchSpeakingTrailingContent
        case .error:
            HStack(spacing: 3) {
                statusLabel
                    .help(SettingsCopyPayload.nonempty(state.errorMessage) ?? "No error details are available.")
                notchButton(icon: "xmark", accessibilityLabel: "Dismiss error") {
                    state.dismissError()
                }
            }
        case .idle:
            HStack(spacing: 4) {
                if state.queueDepth > 0 {
                    queueBadge
                        .fixedSize()
                }
                statusLabel
            }
        case .disconnected:
            statusLabel
        case .recording:
            EmptyView()
        }
    }

    private var notchSpeakingTrailingContent: some View {
        let isCompact = notchPresentation.visualState == .compactStatus
        return HStack(spacing: isCompact ? VoiceBarNotchContract.material.compactControlSpacing : 0) {
            notchWaveform
            if isCompact, state.isTeleprompterDismissed, !state.isPlaybackPaused {
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
                accessibilityLabel: "Stop speaking",
                registersTooltip: isCompact
            ) {
                commandRouter.handleStop()
            }
            .background(playbackStopHostProbe)
            // Keep the compact Stop mounted while the lower teleprompter Stop is visible.
            .opacity(isCompact ? 1 : 0)
            .frame(width: isCompact ? nil : 0)
            .allowsHitTesting(isCompact)
            .accessibilityHidden(!isCompact)
        }
    }

    private var notchWaveform: some View {
        VoiceBarNotchWaveform(
            mode: state.mode,
            isListening: !state.speechDetected,
            isCaptureLive: state.captureLive,
            recordingLevel: { state.recordingWaveformLevel },
            playbackLevel: { state.playbackAudioLevel() },
            isPlaybackEnded: state.isTeleprompterReadback || state.isPlaybackPaused
        )
        .help("Audio level")
    }

    /// NOTCH1: a transient note gets its own band at the top of the lower body (the presentation grew the
    /// shell to hold it); the History panel or teleprompter, when open, keeps the space below.
    private var notchLowerContent: some View {
        VStack(spacing: 0) {
            if let feedback = notchPresentation.feedback {
                VoiceBarNotchFeedbackBand(feedback: feedback, onOpenHistory: onOpenHistory)
                    .foregroundStyle(notchPrimaryLabelColor)
                    .notchAdaptiveGlyphEdge(notchGlyphContrastHaloColor)
            } else if notchPresentation.transientNoteRect != nil, let note = state.selectionFeedbackNote {
                transientNoteBand(note)
            }
            notchLowerPanelContent
                .frame(maxHeight: .infinity)
        }
        .animation(
            .easeOut(duration: VoiceBarNotchContract.motion.contentExitDuration),
            value: state.selectionFeedbackNote
        )
    }

    private func transientNoteBand(_ note: String) -> some View {
        VoiceBarNotchTransientNoteBand(text: note, width: notchPresentation.geometry.bodyWidth)
            .foregroundStyle(notchPrimaryLabelColor)
            .notchAdaptiveGlyphEdge(notchGlyphContrastHaloColor)
            .allowsHitTesting(false)
            // NOTCH2: in after the shell has started opening, out before it starts closing (the shell waits
            // `contentExitDuration` for this fade, see `VoiceBarNotchShellTransition`).
            .transition(.asymmetric(
                insertion: .opacity.animation(
                    .easeOut(duration: 0.18).delay(VoiceBarNotchContract.motion.panelDelay * 2)
                ),
                removal: .opacity.animation(.easeOut(duration: VoiceBarNotchContract.motion.contentExitDuration))
            ))
    }

    @ViewBuilder
    private var notchLowerPanelContent: some View {
        if isMorphHistoryContentPresented {
            historyPanelContent()
                .padding(
                    .horizontal,
                    VoiceBarNotchContract.material.teleprompterBodyHorizontalInset
                )
                .padding(.top, 12)
                .padding(.bottom, 12)
                .transition(.opacity)
        } else if isMorphTeleprompterContentPresented {
            VStack(spacing: 7) {
                notchTeleprompterTimeline
                    .frame(maxWidth: .infinity, maxHeight: state.showsTeleprompterScrubber ? nil : .infinity)
                    .frame(height: state.showsTeleprompterScrubber ? Theme.teleprompterViewportHeight : nil)
                if state.showsTeleprompterScrubber {
                    TeleprompterPlaybackScrubBar(state: state)
                }
                if state.showsTeleprompterScrubber { Spacer(minLength: 0) }
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
                notchTeleprompterBody(text: text)
                    .opacity(
                        TeleprompterVisibilityPolicy.timelineOpacity(
                            isDismissed: state.isTeleprompterDismissed
                        )
                    )
                    .allowsHitTesting(!state.isTeleprompterDismissed)
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

    /// NOTCH2: "Preparing speech…" is a status, not text being read, so it sits on the body's optical centre
    /// instead of the reading flow's top-leading corner, then crossfades into the text on the first chunk.
    @ViewBuilder
    private func notchTeleprompterBody(text: String) -> some View {
        ZStack {
            if state.isPreparingSpeech {
                Text(text)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(notchPalette.secondary.color)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    .transition(.opacity)
            } else {
                TeleprompterView(
                    text: text,
                    wordBoundaries: state.teleprompterWordBoundaries,
                    displayBlocks: state.teleprompterDisplayBlocks,
                    hasCompleteDisplay: state.teleprompterHasCompleteDisplay,
                    isReadback: state.isTeleprompterReadback,
                    playbackEpoch: state.playbackEpoch,
                    playbackElapsedMilliseconds: state.playbackElapsedMilliseconds,
                    onSeek: state.seek,
                    onSeekUnavailable: state.reportWordTimingUnavailable,
                    estimatedPlaybackStartMilliseconds: state.playbackChunkStartMilliseconds,
                    wrapWidth: VoiceBarNotchContract.material.teleprompterTextWidth(
                        coreWidth: notchPresentation.geometry.coreWidth
                    ),
                    contentInset: VoiceBarNotchContract.material.teleprompterTextInnerInset
                )
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.2), value: state.isPreparingSpeech)
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
        // The History panel's rows fade in after the shell has dropped, exactly like the teleprompter's.
        withAnimation(
            .easeOut(duration: VoiceBarNotchContract.motion.contentExitDuration)
                .delay(visualState == .history ? VoiceBarNotchContract.motion.panelDelay : 0)
        ) {
            isMorphHistoryContentPresented = visualState == .history
        }
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
        countBadge("\(state.queueDepth)")
    }

    /// The idle queue badge's capsule; QUEUE1's "+N" fits it into one control slot beside Next.
    private func countBadge(_ label: String, slotWidth: CGFloat? = nil) -> some View {
        Text(label)
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .monospacedDigit()
            .lineLimit(1)
            .fixedSize()
            .foregroundStyle(notchPrimaryLabelColor)
            .padding(.horizontal, slotWidth == nil ? 6 : 3)
            .padding(.vertical, 2)
            .background(Theme.speakingColor.opacity(0.22))
            .clipShape(Capsule())
            // "+10" may overhang its slot into the core gap; the frame keeps Next and pause on their hit rects.
            .frame(width: slotWidth, height: slotWidth)
            .contentTransition(.numericText())
    }

    // MARK: - Status icon

    @ViewBuilder
    private var statusIcon: some View {
        if state.mode == .idle || state.mode == .error {
            notchButton(
                icon: iconName,
                accessibilityLabel: state.mode == .error
                    ? "New recording"
                    : "Start voice recording",
                tooltip: state.mode == .error
                    ? SettingsCopyPayload.nonempty(state.errorMessage) ?? "No error details are available."
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
        compactStatusLabel(notchPresentation.feedback?.wingText ?? statusText,
                           confirmationText: state.confirmationText)
    }

    private func compactStatusLabel(_ text: String, confirmationText: String? = nil) -> some View {
        CompactStatusLabel(text: text, mode: state.mode, confirmationText: confirmationText)
            .foregroundStyle(notchPrimaryLabelColor)
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
        notchButton(
            icon: "clock.arrow.circlepath",
            isSelected: isHistoryPresented,
            accessibilityLabel: isHistoryPresented ? "Close history" : "History"
        ) {
            isHistoryPresented.toggle()
        }
    }

    private var settingsButton: some View {
        notchButton(icon: "gearshape", accessibilityLabel: "Settings") {
            onOpenSettings()
        }
    }

    /// Visual shots only.
    func forcingHistoryHover(_ index: Int?) -> BarView {
        var copy = self
        copy.historyForcedHoverIndex = index
        return copy
    }

    /// Visual shots only: mount with the History panel open, so its button renders selected.
    func presentingHistoryForShots() -> BarView {
        var copy = self
        copy._isHistoryPresented = State(initialValue: true)
        return copy
    }

    /// Spec §4: the History panel inside the notch's lower surface.
    private func historyPanelContent() -> some View {
        NotchHistoryPanel(
            entries: state.recentTranscriptionEntries,
            activeRetranscriptionPath: state.activeHistoryRetranscriptionPath,
            palette: notchPalette,
            onCopy: { state.copyTranscript($0.text) },
            onPaste: { entry in
                isHistoryPresented = false
                state.repasteTranscript(entry.text, source: "bar_history")
            },
            onRetranscribe: { commandRouter.handleRetranscribeHistoryEntry(recordingPath: $0) },
            onOpenHistory: {
                isHistoryPresented = false
                onOpenHistory()
            },
            forcedHoverIndex: historyForcedHoverIndex
        )
    }

    private func notchButton(
        icon: String,
        isSelected: Bool = false,
        selectionStyle: VoiceBarNotchSelectionStyle = .navigation,
        isDestructive: Bool = false,
        accessibilityLabel: String? = nil,
        accessibilityHint: String? = nil,
        tooltip: String? = nil,
        action: @escaping () -> Void
    ) -> some View {
        let optics = VoiceBarNotchControlOptics.resolve(for: icon)
        let foregroundRole = VoiceBarNotchGlyphForegroundRole.resolve(
            isDestructive: isDestructive,
            isSelected: isSelected,
            selectionStyle: selectionStyle
        )
        return VoiceBarPillControlButton(
            icon: icon,
            optics: optics,
            foreground: foregroundRole == .stateAccent ? Theme.recordingColor : notchPrimaryLabelColor,
            halo: notchGlyphContrastHaloColor,
            isSelected: isSelected,
            selectionStyle: selectionStyle,
            isDestructive: isDestructive && icon == "stop.fill",
            accessibilityLabel: accessibilityLabel ?? icon,
            accessibilityHint: accessibilityHint ?? "",
            tooltip: tooltip,
            action: action
        )
    }

    private func notchTeleprompterButton(
        icon: String,
        isDestructive: Bool = false,
        accessibilityLabel: String,
        tooltip: String? = nil,
        registersTooltip: Bool = true,
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
        .background(PillControlTooltip(text: registersTooltip ? (tooltip ?? accessibilityLabel) : nil))
    }
}

/// Shared renderer lets offscreen tests measure the same line limit as the pill.
struct CompactStatusLabel: View {
    let text: String
    let mode: VoiceMode
    let confirmationText: String?

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .medium))
            .lineLimit(mode == .idle && TwoLineStatusFeedback.contains(confirmationText) ? 2 : 1)
            .truncationMode(.tail)
    }
}
