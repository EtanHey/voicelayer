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
        // 2.3 U2: the chevron is the mock's small button (12 of 17 pt glyph), so it reads as secondary to the mic.
        let pointSize: CGFloat = switch systemName {
        case "stop.fill": 8
        case "chevron.down": 9
        default: 12
        }
        return VoiceBarNotchControlOptics(pointSize: pointSize, offsetX: 0, offsetY: 0)
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

extension VoiceBarNotchWingContentEntry {
    static func transition(growth: CGFloat) -> AnyTransition {
        let wait = delay(forGrowth: growth)
        return .asymmetric(
            insertion: wait > 0 ? .opacity.animation(.easeOut(duration: duration).delay(wait)) : .identity,
            removal: .identity
        )
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
// R0856-09/10: every icon-only control in the notch and its dropdowns registers its tooltip this way; SwiftUI
// `.help` does not show in the non-activating notch panel (NotchIconButtonTooltipTests).
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
    /// 2.3 U2: the chevron beside the mic opens the microphone list under the left wing.
    public var onOpenMicrophonePicker: () -> Void
    public var onOpenNotchMenu: () -> Void
    public var onCancelNotchMenu: () -> Void
    /// 2.3 U2: the gear while setup needs attention opens Settings at the setup spot.
    public var onOpenSetupSettings: () -> Void
    /// SPEC open question 1 (recommendation built): a notch History row click opens that recording in the History
    /// window. Nil falls back to opening the window at its newest row.
    public var onOpenHistoryRecording: ((String) -> Void)?
    private let presentationModel: VoiceBarNotchPresentationModel?
    private let morphSelection: VoiceBarNotchMorphSelection?
    private let includesPanelOutsets: Bool
    /// 2.3 U2: History's open state for the notch surface handoff (History and the microphone list never show
    /// together); shared by the app and the UIE2E host.
    private let historyBridge: VoiceBarNotchHistoryBridge?
    /// Visual shots only: render one History row as hovered without a pointer.
    private var historyForcedHoverIndex: Int?
    @State private var errorDismissTask: Task<Void, Never>?
    @State private var isMorphTeleprompterContentPresented = false
    /// The user's intent: History should be open. The panel animates toward it (2.3 lane U4, morph B).
    @State private var isHistoryPresented = false
    /// The History panel is on screen (open, opening, closing or being pulled). The window keeps the panel's size
    /// until the close spring has settled, so a close is never cut off by AppKit shrinking the panel under it.
    @State private var isHistoryMounted = false
    /// Morph B's single progress: 0 = launcher, 1 = open panel. Shell, radii and rows all read it.
    @State private var historyProgress: CGFloat = 0
    @State private var historyMorphGeneration = 0
    @State private var historyPull = NotchHistoryPull()
    @State private var historyPressIsBare = false
    @State private var pendingHistoryReleaseVelocity: Double = 0
    /// V6: the rows the extend handle settled on (7…12; the hit region and the next open use it) and the live,
    /// animated rows the shell and list draw while the handle is dragged or settling.
    @State private var historyRows = NotchHistoryMorph.visibleRows
    @State private var historyRowsExtent = CGFloat(NotchHistoryMorph.visibleRows)
    @State private var historyRowsPull = NotchHistoryPull()
    /// The springs currently moving the panel and the rows, so a press can read what is drawn (Codex review R1).
    @State private var historyFlight: NotchHistorySpringFlight?
    @State private var historyRowsFlight: NotchHistorySpringFlight?
    @GestureState private var isHistoryPullGestureActive = false
    /// Visual shots only: show the panel frozen at this progress.
    private var historyFrozenProgress: CGFloat?
    /// Visual shots only: the scroll indicator as if mid-scroll.
    private var historyForcedScrollOffset: CGFloat?
    @State private var settledLeadingWingWidth: CGFloat = 0
    @State private var preparingHandoff = TeleprompterPreparingHandoffGate()
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
        onOpenHistoryRecording: ((String) -> Void)? = nil,
        presentationModel: VoiceBarNotchPresentationModel? = nil,
        morphSelection: VoiceBarNotchMorphSelection? = nil,
        includesPanelOutsets: Bool = false,
        onOpenMicrophonePicker: @escaping () -> Void = {},
        onOpenSetupSettings: (() -> Void)? = nil,
        historyBridge: VoiceBarNotchHistoryBridge? = nil,
        onOpenNotchMenu: @escaping () -> Void = {},
        onCancelNotchMenu: @escaping () -> Void = {}
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
        self.onOpenMicrophonePicker = onOpenMicrophonePicker
        self.onOpenSetupSettings = onOpenSetupSettings ?? onOpenSettings
        self.onOpenHistoryRecording = onOpenHistoryRecording
        self.presentationModel = presentationModel
        self.morphSelection = morphSelection
        self.includesPanelOutsets = includesPanelOutsets
        self.historyBridge = historyBridge
        self.onOpenNotchMenu = onOpenNotchMenu
        self.onCancelNotchMenu = onCancelNotchMenu
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
            historyMorph: historyMorphInput,
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
        .onChange(of: notchPresentation.geometry.leadingWingWidth, initial: true) { _, width in
            settledLeadingWingWidth = notchPresentation.visualState == .idle ? 0 : width
        }
        .onChange(of: notchPresentation.visualState) { _, visualState in
            scheduleMorphTeleprompterContent(for: visualState)
        }
        .overlay(alignment: .topLeading) { bareNotchControl }
        .transaction { if historyBridge?.presentedMenu != nil { $0.disablesAnimations = true; $0.animation = nil } }
        .coordinateSpace(name: Self.notchCanvasSpace)
        .gesture(historyPullGesture)
        .onChange(of: isHistoryPullGestureActive) { _, isActive in
            // A press the system cancelled (no `onEnded`) ends here: a drag settles at the nearer end, a press still
            // inside the slop just ends, so the next gesture never reuses a stale start (Codex review R1).
            if !isActive, historyPull.phase != .idle || historyRowsPull.phase != .idle { endHistoryPull(cancelled: true) }
        }
        .onChange(of: isHistoryPresented) { _, isOpen in
            synchronizeLauncherRetention()
            // U2×U4 review: a renewed open intent cancels a waiting notch menu even when the panel is still
            // mounted (reopened during its close spring), where no mount change reaches the handoff.
            if isOpen { historyBridge?.historyOpenRequested() }
            synchronizeHistoryDismissal(isOpen: isOpen)
            let velocity = pendingHistoryReleaseVelocity
            pendingHistoryReleaseVelocity = 0
            animateHistory(toOpen: isOpen, velocity: velocity)
        }
        .onChange(of: isHistoryMounted) { _, isMounted in
            synchronizeLauncherRetention()
            reportHistoryPanelMounted(isMounted)
        }
        .onDisappear {
            historyDismissal?.stop()
        }
        .background(HostWindowReader { window in hostWindow.window = window })
        .onChange(of: accessibilityReduceMotion) { _, isEnabled in
            presentationModel?.setReducedMotion(isEnabled)
        }
        // U5 backstop: the teleprompter body going away can never leave the handle's pointer hold behind.
        .onChange(of: isMorphTeleprompterContentPresented) { _, shown in
            if !shown { presentationModel?.setTeleprompterHandlePullActive(false) }
        }
        .onAppear {
            presentationModel?.setHovered(state.isHovering)
            synchronizeLauncherRetention()
            presentationModel?.setReducedMotion(accessibilityReduceMotion)
            isMorphTeleprompterContentPresented = notchPresentation.visualState == .teleprompter
            if let rows = presentationModel?.historyRows {
                historyRows = rows
                historyRowsExtent = CGFloat(rows)
            }
            if isHistoryPresented, !isHistoryMounted {
                isHistoryMounted = true
                historyProgress = historyFrozenProgress ?? 1
                reportHistoryPanelMounted(true)
            }
        }
        .onChange(of: state.recentTranscriptionEntries.count) { _, count in
            if count == 0 {
                isHistoryPresented = false
            }
        }
        // 2.3 U2: a notch menu asked for History to close first (VoiceBarNotchSurfaceHandoff).
        .onChange(of: historyBridge?.closeRequest ?? 0) { _, _ in
            isHistoryPresented = false
        }
    }

    /// 2.3 U2 × U4: History counts as open for the layout AND for the notch surface handoff while its panel is
    /// MOUNTED (open, opening, closing or being pulled), not merely while open is intended. A menu shown on the
    /// intent change would hang over a panel still springing closed, and SwiftUI does not animate it away while
    /// the AppKit menu tracks; a pull-down draws the panel before any intent flips.
    private func reportHistoryPanelMounted(_ isMounted: Bool) {
        presentationModel?.setHistoryPanelOpen(isMounted)
        historyBridge?.historyDidChange(isOpen: isMounted)
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
            transientNote: state.selectionFeedbackNote,
            showsEarlierTakeProcessing: VoiceBarPresentation.showsEarlierTakeProcessing(for: state)
        )
        input.isHistoryPanelOpen = isHistoryMounted
        input.historyRows = historyRows
        input.teleprompterLines = state.teleprompterVisibleLines
        input.transientNoteOffersHistory = state.selectionFeedbackNoteOffersHistory
        return VoiceBarPresentation.notchPresentation(from: input)
    }

    private var keepsLauncherMounted: Bool {
        isHistoryPresented || isHistoryMounted
    }

    // MARK: - History morph B (2.3 lane U4)

    static let notchCanvasSpace = "VoiceBarNotchCanvas"

    /// The shell input while History is on screen; nil in every other state, which then draws exactly as before.
    private var historyMorphInput: VoiceBarNotchHistoryMorphInput? {
        let presentation = notchPresentation
        guard presentation.visualState == .history else { return nil }
        return VoiceBarNotchHistoryMorphInput(
            progress: historyFrozenProgress ?? historyProgress,
            closed: VoiceBarNotchContract.geometry(
                for: .hoverLauncher,
                coreWidth: presentation.geometry.coreWidth,
                visibleCoreOcclusionInset: presentation.visibleCoreOcclusionInset
            ),
            open: presentation.geometry,
            // The live rows plus any note band, never past History's window.
            openLowerSurfaceHeight: min(
                NotchHistoryMorph.lowerSurfaceHeight(rows: historyRowsExtent) + presentation.feedbackHeight,
                NotchHistoryMorph.historyCanvasLowerSurfaceHeight
            )
        )
    }

    /// Springs History toward open or closed from wherever it is (retargeting keeps the running velocity).
    /// Closing unmounts only once the spring has fully settled, and only if nothing reopened it meanwhile.
    private func animateHistory(toOpen: Bool, velocity: Double = 0) {
        historyMorphGeneration &+= 1
        let generation = historyMorphGeneration
        if toOpen, !isHistoryMounted {
            isHistoryMounted = true
            reportHistoryPanelMounted(true)
        }
        guard !accessibilityReduceMotion else {
            // Reduced motion swaps every morph for an instant change (the mock's note).
            historyFlight = nil
            historyProgress = toOpen ? 1 : 0
            if !toOpen { isHistoryMounted = false }
            return
        }
        // SwiftUI retargets from what is drawn and keeps its velocity; the flight records the same.
        let now = NotchHistoryClock.now()
        let drawn = renderedHistoryProgress(at: now)
        let carried = (historyFlight?.velocity(at: now) ?? 0) + velocity
        historyFlight = NotchHistorySpringFlight(
            from: drawn, to: toOpen ? 1 : 0, velocity: carried, start: now,
            response: toOpen ? NotchHistoryMorph.openResponse : NotchHistoryMorph.closeResponse,
            dampingFraction: toOpen ? NotchHistoryMorph.openDampingFraction : NotchHistoryMorph.closeDampingFraction
        )
        withAnimation(
            NotchHistoryMorph.animation(opening: toOpen, from: drawn, velocity: velocity),
            completionCriteria: .removed
        ) {
            historyProgress = toOpen ? 1 : 0
        } completion: {
            guard generation == historyMorphGeneration, !toOpen, !isHistoryPresented, !historyPull.isDragging
            else { return }
            isHistoryMounted = false
        }
    }

    /// Pull History down from the notch (or push it back up by the open panel's bottom edge). A press that never
    /// moves `dragSlop` is a click and leaves the panel alone; a drag follows the pointer and settles with a spring
    /// at its release speed (formal/history-pull).
    private var historyPullGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.notchCanvasSpace))
            .updating($isHistoryPullGestureActive) { _, active, _ in active = true }
            .onChanged { value in
                let openHeight = notchPresentationOpenHistoryHeight
                let time = value.time.timeIntervalSinceReferenceDate
                if case .idle = historyPull.phase, case .idle = historyRowsPull.phase {
                    historyPressIsBare = abs(value.startLocation.x - historyPanelCentreX) <= notchPresentation.geometry.coreWidth / 2
                        && NotchHistoryPull.accepts(y: value.startLocation.y)
                    guard canPullHistory || historyPressIsBare else { return }
                    if NotchHistoryPull.accepts(y: value.startLocation.y) {
                        historyPull.press(y: value.startLocation.y, progress: historyProgress, time: time)
                    } else if isHistoryPresented, NotchHistoryPull.acceptsHandle(
                        point: value.startLocation, centreX: historyPanelCentreX,
                        panelHeight: openHeight, progress: historyFrozenProgress ?? renderedHistoryProgress(at: time)
                    ) {
                        historyRowsPull.press(y: value.startLocation.y, progress: historyRowsExtent, time: time)
                    } else {
                        return
                    }
                }
                if historyRowsPull.phase != .idle {
                    dragHistoryRows(to: value.location.y, time: time)
                    return
                }
                if max(abs(value.translation.width), abs(value.translation.height)) > NotchHistoryMorph.dragSlop {
                    historyPressIsBare = false
                }
                guard canPullHistory else { return }
                guard let progress = historyPull.move(
                    y: value.location.y, time: time, range: openHeight - VoiceBarNotchContract.topHeight,
                    seed: renderedHistoryProgress(at: time)
                ) else { return }
                historyFlight = nil // the pointer owns the value now
                historyBridge?.historyOpenRequested() // grabbing History cancels a waiting notch menu
                if !isHistoryMounted {
                    historyMorphGeneration &+= 1
                    isHistoryMounted = true
                    reportHistoryPanelMounted(true)
                }
                presentationModel?.setHistoryPullActive(true)
                var follow = Transaction()
                follow.disablesAnimations = true
                withTransaction(follow) { historyProgress = progress }
            }
            .onEnded { _ in endHistoryPull(cancelled: false) }
    }

    /// The handle's own drag (see NotchHistoryExtendHandle): the same press rules as the canvas path (the panel fully
    /// open, no open/close pull in progress), then the same row follow.
    private func dragHistoryHandle(y: CGFloat, time: TimeInterval) {
        if case .idle = historyRowsPull.phase {
            guard case .idle = historyPull.phase, isHistoryPresented,
                  (historyFrozenProgress ?? renderedHistoryProgress(at: time)) > 0.98 else { return }
            historyRowsPull.press(y: y, progress: historyRowsExtent, time: time)
        }
        dragHistoryRows(to: y, time: time)
    }

    /// V6: the extend handle follows the pointer one row per 46 pt, stretching past 7 and the last row.
    private func dragHistoryRows(to y: CGFloat, time: TimeInterval) {
        let maximum = NotchHistoryMorph.maximumRows(entryCount: state.recentTranscriptionEntries.count)
        guard let rows = historyRowsPull.move(
            y: y, time: time, range: NotchHistoryMorph.rowHeight,
            band: { NotchHistoryMorph.rowsRubberBand($0, maximum: maximum) },
            seed: renderedHistoryRows(at: time)
        ) else { return }
        historyRowsFlight = nil
        presentationModel?.setHistoryPullActive(true)
        var follow = Transaction()
        follow.disablesAnimations = true
        withTransaction(follow) { historyRowsExtent = rows }
    }

    /// A released (or cancelled) handle settles on the nearest whole row with the `pull` spring; the hit region and
    /// the session's remembered height take the settled rows at once. A press that never moved changes nothing.
    private func endHistoryRowsPull(cancelled: Bool) {
        presentationModel?.setHistoryPullActive(false)
        guard case let .settle(_, velocity) = historyRowsPull.release(progress: historyRowsExtent, cancelled: cancelled)
        else { return }
        let maximum = NotchHistoryMorph.maximumRows(entryCount: state.recentTranscriptionEntries.count)
        let rows = NotchHistoryMorph.snappedRows(historyRowsExtent, maximum: maximum)
        historyRows = rows
        presentationModel?.setHistoryRows(rows)
        guard !accessibilityReduceMotion else {
            historyRowsFlight = nil
            historyRowsExtent = CGFloat(rows)
            return
        }
        historyRowsFlight = NotchHistorySpringFlight(
            from: historyRowsExtent, to: CGFloat(rows), velocity: velocity, start: NotchHistoryClock.now(),
            response: NotchHistoryMorph.pullResponse, dampingFraction: NotchHistoryMorph.pullDampingFraction
        )
        withAnimation(NotchHistoryMorph.rowsAnimation(from: historyRowsExtent, to: rows, velocity: velocity)) {
            historyRowsExtent = CGFloat(rows)
        }
    }

    /// What the panel draws at `time`: the running spring's position, else the model value.
    private func renderedHistoryProgress(at time: TimeInterval) -> CGFloat {
        historyFlight?.value(at: time) ?? historyProgress
    }

    private func renderedHistoryRows(at time: TimeInterval) -> CGFloat {
        historyRowsFlight?.value(at: time) ?? historyRowsExtent
    }

    private var bareNotchControl: some View {
        BareNotchMenuControl(isExpanded: historyBridge?.presentedMenu == .notch,
            onMenu: onOpenNotchMenu, onHistory: { if canPullHistory { isHistoryPresented = true } },
            onClose: { isHistoryPresented = false; onCancelNotchMenu() })
            .frame(width: notchPresentation.geometry.coreWidth, height: VoiceBarNotchContract.topHeight)
            .help("Click for the menu, pull down for History.")
            .position(x: historyPanelCentreX, y: VoiceBarNotchContract.topHeight / 2)
    }

    /// The open panel's centre in the canvas: the extend handle sits there.
    private var historyPanelCentreX: CGFloat {
        let presentation = notchPresentation
        let geometry = includesPanelOutsets
            ? VoiceBarNotchMorphCanvasLayout.resolve(for: presentation).canvasGeometry : presentation.geometry
        return geometry.coreOriginX + geometry.coreWidth / 2
    }

    private func endHistoryPull(cancelled: Bool) {
        if historyRowsPull.phase != .idle {
            endHistoryRowsPull(cancelled: cancelled)
            return
        }
        let wasBare = historyPressIsBare
        historyPressIsBare = false
        presentationModel?.setHistoryPullActive(false)
        switch historyPull.release(progress: historyProgress, cancelled: cancelled) {
        case let .settle(open, velocity):
            if open == isHistoryPresented {
                animateHistory(toOpen: open, velocity: velocity)
            } else {
                pendingHistoryReleaseVelocity = velocity
                isHistoryPresented = open
            }
        case .click:
            if wasBare && !cancelled { onOpenNotchMenu() }
        case .none:
            break
        }
    }

    /// History opens only from the launcher or itself, and never while there's nothing to show.
    private var canPullHistory: Bool {
        let state = notchPresentation.visualState
        return (state == .hoverLauncher || state == .history) && !self.state.recentTranscriptionEntries.isEmpty
    }

    private var notchPresentationOpenHistoryHeight: CGFloat {
        VoiceBarNotchContract.topHeight + NotchHistoryMorph.lowerSurfaceHeight(rows: CGFloat(historyRows))
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

    /// R0856-05: how far the leading wing grows in this change. `settledLeadingWingWidth` still holds the previous
    /// width while the body that inserts the new controls is evaluated; a collapsed notch counts as no growth.
    private var leadingWingGrowth: CGFloat {
        guard settledLeadingWingWidth > 0 else { return 0 }
        return notchPresentation.geometry.leadingWingWidth - settledLeadingWingWidth
    }

    @ViewBuilder
    private var notchLeadingContent: some View {
        switch notchPresentation.visualState {
        case .idle:
            EmptyView()
        case .hoverLauncher, .history:
            // 2.3 U2: the mic, then the chevron for the microphone list, which opens beside it on the left.
            HStack(spacing: VoiceBarNotchContract.material.compactControlSpacing) {
                notchButton(
                    icon: "mic.fill",
                    accessibilityLabel: "Start voice recording",
                    tooltip: "Start dictation (F5)"
                ) {
                    commandRouter.handlePrimaryTap()
                }
                microphonePickerButton
            }
        case .recording:
            HStack(spacing: VoiceBarNotchContract.material.compactControlSpacing) {
                if VoiceBarPresentation.showsEarlierTakeProcessing(for: state) {
                    // 2.3 N1 (Etan, queued-recording clip F1): an earlier take is still transcribing. Its spinner
                    // sits left of Stop, beside the recording controls and never instead of them. It is not a
                    // control, so it registers no tooltip; VoiceOver reads it.
                    ProcessingSpinner()
                        .frame(
                            width: VoiceBarNotchContract.material.compactControlSize,
                            height: VoiceBarNotchContract.material.compactControlSize
                        )
                        .accessibilityElement()
                        .accessibilityLabel("Earlier recording still transcribing")
                        .accessibilityAddTraits(.updatesFrequently)
                        .transition(VoiceBarNotchWingContentEntry.transition(growth: leadingWingGrowth))
                }
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
                    // It arrives with the wing growing by one slot.
                    .transition(VoiceBarNotchWingContentEntry.transition(growth: leadingWingGrowth))
                }
            }
            // R0856-05: the recording controls arrive with a wider wing; they show once its glass covers them.
            .transition(VoiceBarNotchWingContentEntry.transition(growth: leadingWingGrowth))
        case .compactStatus, .teleprompter:
            if notchPresentation.visualState == .compactStatus, state.mode == .transcribing {
                // 2.3 U2: the spinner sits where Stop was, in a control slot so it lines up with it. It is not a
                // control, so it registers no tooltip (R0856-09: tooltips sit on controls); VoiceOver reads it.
                ProcessingSpinner()
                    .frame(
                        width: VoiceBarNotchContract.material.compactControlSize,
                        height: VoiceBarNotchContract.material.compactControlSize
                    )
                    .accessibilityElement()
                    .accessibilityLabel("Transcribing")
                    .accessibilityAddTraits(.updatesFrequently)
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
        // 2.3 U2: the reading wing is the fixed two-slot wing. Without the mock's speed control (no playback-rate
        // logic exists yet) Pause takes the core-side slot, which is where its hit rect is counted from.
        .frame(maxWidth: .infinity, alignment: .trailing)
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
            // 2.3 N1 (Etan, QA round 1; real M4): the live time 8 pt clear of the physical notch, then 2.2.61's
            // 46 × 24 pt level meter, centred in the visible wing by an equal empty region outside it (review D3). The
            // time shows only once capture has opened (review D1); the capturing microphone is its tooltip and VoiceOver
            // value, never wing text.
            HStack(spacing: VoiceBarRecordingWingLabel.meterGap) {
                VoiceBarRecordingTimeRegion(
                    elapsedMilliseconds: { state.recordingElapsedMilliseconds() },
                    isCaptureOpen: state.isRecordingCaptureOpen,
                    microphoneName: state.recordingMicrophoneName,
                    color: notchPrimaryLabelColor
                )
                notchWaveform
                Color.clear.frame(width: VoiceBarRecordingWingLabel.outerRegionWidth, height: 1)
            }
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
            // 2.3 U2: no "Transcribing" label and no third control; History and Settings stay usable.
            HStack(spacing: VoiceBarNotchContract.material.compactControlSpacing) {
                historyButton
                settingsButton
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
            // Removing overflowing copy must not recenter the queue badge away
            // from its existing core-side slot.
            .frame(maxWidth: state.queueDepth > 0 && notchPresentation.feedback?.replacesWingText == true
                ? .infinity : nil, alignment: .leading)
        case .disconnected:
            statusLabel
        case .recording:
            EmptyView()
        }
    }

    /// 2.3 U2 (3-wings mock): reading aloud shows the time and Stop in the fixed right wing. A dismissed-but-playing
    /// read swaps the time for Show teleprompter, so the wing never carries a third control. 2.3 U5: the wing Stop is
    /// the live one with the teleprompter open too; the teleprompter's lower row no longer has a Stop.
    private var notchSpeakingTrailingContent: some View {
        let isCompact = notchPresentation.visualState == .compactStatus
        return HStack(spacing: VoiceBarNotchContract.material.compactControlSpacing) {
            if isCompact, state.isTeleprompterDismissed, !state.isPlaybackPaused {
                notchTeleprompterButton(
                    icon: "eye",
                    accessibilityLabel: "Show teleprompter"
                ) {
                    state.showTeleprompter()
                }
                .frame(width: VoiceBarReadingTimeLabel.width)
            } else {
                VoiceBarReadingTimeLabel(
                    elapsedMilliseconds: { state.playbackElapsedMilliseconds() },
                    // The palette's secondary ink (the mock's ink-2), which holds its contrast on the light glass.
                    color: notchPalette.secondary.color
                )
            }
            notchTeleprompterButton(
                icon: "stop.fill",
                isDestructive: true,
                accessibilityLabel: "Stop speaking"
            ) {
                commandRouter.handleStop()
            }
            .background(playbackStopHostProbe)
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
        .help("Input level")
        .accessibilityLabel("Input level")
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
        VoiceBarNotchTransientNoteBand(text: note, width: VoiceBarNotchContract.noteColumnWidth(
            for: notchPresentation.geometry, ownBodyHeight: notchPresentation.ownBodyHeight))
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
        if notchPresentation.visualState == .history {
            VStack(spacing: 0) {
                historyPanelContent()
                    .padding(.horizontal, NotchHistoryMorph.listHorizontalInset)
                    .padding(.top, NotchHistoryMorph.listTopInset)
                NotchHistoryExtendHandle(
                    palette: notchPalette,
                    rows: historyRows,
                    maximumRows: NotchHistoryMorph.maximumRows(entryCount: state.recentTranscriptionEntries.count),
                    onAdjust: adjustHistoryRows,
                    onDrag: dragHistoryHandle,
                    onDragEnd: { cancelled in
                        if historyRowsPull.phase != .idle { endHistoryRowsPull(cancelled: cancelled) }
                    }
                )
            }
                .frame(maxHeight: .infinity, alignment: .top)
                .modifier(NotchHistoryRowsMorph(progress: historyFrozenProgress ?? historyProgress))
        } else if isMorphTeleprompterContentPresented {
            VStack(spacing: 7) {
                notchTeleprompterTimeline
                    .frame(maxWidth: .infinity, maxHeight: state.showsTeleprompterScrubber ? nil : .infinity)
                    .frame(height: state.showsTeleprompterScrubber ? showsTeleprompterA
                        ? TeleprompterA.bodyHeight(lines: state.teleprompterVisibleLines) + TeleprompterA.handleBandHeight
                        : Theme.teleprompterViewportHeight : nil)
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
    /// instead of the reading flow's top-leading corner, then hands off to the text on the first chunk.
    @ViewBuilder
    private func notchTeleprompterBody(text: String) -> some View {
        ZStack {
            if preparingHandoff.showsStatus(isPreparing: state.isPreparingSpeech) {
                Text(text)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(notchPalette.secondary.color)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    .transition(TeleprompterPreparingHandoff.transition)
            } else if preparingHandoff.showsText(isPreparing: state.isPreparingSpeech), showsTeleprompterA {
                TeleprompterAView(
                    text: text,
                    wordBoundaries: state.teleprompterWordBoundaries,
                    displayBlocks: state.teleprompterDisplayBlocks,
                    hasCompleteDisplay: state.teleprompterHasCompleteDisplay,
                    speechWords: state.speechWords,
                    isPaused: state.isPlaybackPaused,
                    footerState: TeleprompterA.footerState(isPaused: state.isPlaybackPaused,
                                                           isPausedForDictation: state.isF5SpeechPausedDuringCapture),
                    queuedCount: state.queuedSpeakCount,
                    visibleLines: state.teleprompterVisibleLines,
                    onVisibleLinesChange: { lines in
                        // The hit region takes the lines before the pull lets go of the pointer (formal/teleprompter-a-handle).
                        state.teleprompterVisibleLines = lines
                        presentationModel?.setTeleprompterLines(lines)
                    },
                    onHandleDrag: { presentationModel?.setTeleprompterHandlePullActive($0) },
                    columnWidth: min(TeleprompterA.columnWidth, VoiceBarNotchContract.material.teleprompterTextWidth(
                        coreWidth: notchPresentation.geometry.coreWidth)),
                    playbackElapsedMilliseconds: state.playbackElapsedMilliseconds,
                    onSpeechSeek: { state.seekSpeechWord(utteranceID: $0, wordIndex: $1) },
                    onSeek: state.seek
                )
                .transition(TeleprompterPreparingHandoff.transition)
            } else if preparingHandoff.showsText(isPreparing: state.isPreparingSpeech) {
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
                .transition(TeleprompterPreparingHandoff.transition)
            }
        }
        // R2-04: the status and the text hand off in sequence (see `TeleprompterPreparingHandoff`), never crossfade.
        .animation(.easeOut(duration: TeleprompterPreparingHandoff.exitDuration), value: state.isPreparingSpeech)
        .animation(.easeOut(duration: TeleprompterPreparingHandoff.enterDuration), value: preparingHandoff.holdsIncoming)
        .onChange(of: state.isPreparingSpeech, initial: true) { old, isPreparing in
            preparingHandoff.preparingChanged(to: isPreparing, initial: old == isPreparing)
        }
    }

    /// U5: live reading uses Teleprompter A; an idle-retained readback keeps its scrolling view.
    private var showsTeleprompterA: Bool { state.mode == .speaking && !state.isTeleprompterReadback }

    private var notchTeleprompterControls: some View {
        HStack(spacing: 10) {
            if state.queuedSpeakCount > 0, !showsTeleprompterA {
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
            // Keep Replay and Eye fixed when the terminal X appears after speaking.
            if state.isTeleprompterReadback {
                notchTeleprompterDismissButton
            } else {
                notchTeleprompterDismissButton
                    .hidden()
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }

    private var notchTeleprompterDismissButton: some View {
        notchTeleprompterButton(
            icon: "xmark", accessibilityLabel: "Dismiss teleprompter",
            registersTooltip: state.isTeleprompterReadback
        ) {
            state.dismissRetainedTeleprompter()
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
        // History's rows ride morph B's progress (`NotchHistoryRowsMorph`), not a fade of their own.
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
        compactStatusLabel(notchPresentation.wingLabel(for: statusText),
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

    /// 2.3 U2: a setup problem badges the gear (an orange dot) instead of adding a third icon; the badged gear
    /// opens Settings at the setup spot.
    private var settingsButton: some View {
        let missing = state.setupMissingPermissions
        let needsAttention = !missing.isEmpty
        return notchButton(
            icon: "gearshape",
            accessibilityLabel: VoiceBarSetupAttention.accessibilityLabel(missing: missing),
            tooltip: VoiceBarSetupAttention.tooltip(missing: missing)
        ) {
            if state.setupNeedsAttention {
                onOpenSetupSettings()
            } else {
                onOpenSettings()
            }
        }
        .overlay(alignment: .topTrailing) {
            if needsAttention {
                VoiceBarSetupAttentionDot()
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }

    private var microphonePickerButton: some View {
        notchButton(
            icon: "chevron.down",
            accessibilityLabel: "Choose microphone",
            tooltip: "Choose microphone"
        ) {
            onOpenMicrophonePicker()
        }
    }

    /// Tests only: mount with the notch History panel already open.
    func presentingHistoryForTesting() -> BarView {
        var copy = self
        copy._isHistoryPresented = State(initialValue: true)
        copy._isHistoryMounted = State(initialValue: true)
        copy._historyProgress = State(initialValue: 1)
        return copy
    }

    /// Visual shots only: the History morph frozen mid-flight at `progress` (0 = launcher, 1 = open).
    func freezingHistoryMorph(at progress: CGFloat) -> BarView {
        var copy = presentingHistoryForTesting()
        copy.historyFrozenProgress = progress
        return copy
    }

    /// Visual shots only: the panel extended to `rows` (V6), as if the handle had settled there.
    func extendingHistory(rows: Int) -> BarView {
        var copy = self
        copy._historyRows = State(initialValue: rows)
        copy._historyRowsExtent = State(initialValue: CGFloat(rows))
        return copy
    }

    /// VoiceOver's adjust on the extend handle: one row at a time, instantly.
    private func adjustHistoryRows(by delta: Int) {
        let maximum = NotchHistoryMorph.maximumRows(entryCount: state.recentTranscriptionEntries.count)
        let rows = NotchHistoryMorph.snappedRows(CGFloat(historyRows + delta), maximum: maximum)
        guard rows != historyRows else { return }
        historyRows = rows
        presentationModel?.setHistoryRows(rows)
        historyRowsFlight = nil
        historyRowsExtent = CGFloat(rows) // an assistive step, like a keyboard action, never animates
    }

    /// Visual shots only: the scroll indicator shown as if mid-scroll at this offset.
    func forcingHistoryScrollIndicator(offset: CGFloat) -> BarView {
        var copy = self
        copy.historyForcedScrollOffset = offset
        return copy
    }

    /// Visual shots only.
    func forcingHistoryHover(_ index: Int?) -> BarView {
        var copy = self
        copy.historyForcedHoverIndex = index
        return copy
    }

    /// Visual shots only: mount with the History panel open, so its button renders selected.
    func presentingHistoryForShots() -> BarView {
        presentingHistoryForTesting()
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
            onOpen: { entry in
                isHistoryPresented = false
                if let path = entry.recordingPath, let onOpenHistoryRecording {
                    onOpenHistoryRecording(path)
                } else {
                    onOpenHistory()
                }
            },
            listHeight: min(
                NotchHistoryMorph.listHeight(rows: historyRowsExtent),
                NotchHistoryMorph.historyCanvasLowerSurfaceHeight - notchPresentation.feedbackHeight
                    - NotchHistoryMorph.listTopInset - NotchHistoryMorph.handleBandHeight
            ),
            forcedHoverIndex: historyForcedHoverIndex,
            forcedScrollOffset: historyForcedScrollOffset
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
