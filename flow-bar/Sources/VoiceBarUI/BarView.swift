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

extension View {
    /// The notch's glyph treatment: a 0.75 pt contrast edge drawn as four hard shadows. It also renders the glyph
    /// through its own shadow layer, the path every band glyph takes; Etan's 0510 S4 shows those painting while the
    /// drawer's plain glyphs vanished in the same unfocused frame (N3), so every notch glyph takes it. HYPOTHESIS:
    /// the unfocused vanishing was never reproduced and its root cause is unknown; confirm on the real app.
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
    /// 2.4 Lane A: the ONE notch surface (formal/notch-surface). Which drawer is open lives there, never in a flag
    /// here. The app and the UIE2E host inject theirs; a BarView without one owns a private model.
    private let injectedSurface: NotchSurfaceModel?
    @State private var ownSurface = NotchSurfaceModel()
    /// The Settings drawer's data and actions. Without it the gear keeps opening the Settings window (2.3).
    private let settingsDrawer: NotchSettingsDrawerContext?
    @State private var modalObserver: NotchModalObserver?
    @State private var errorDismissTask: Task<Void, Never>?
    @State private var isMorphTeleprompterContentPresented = false
    /// The History panel is on screen (open, opening, closing or being pulled). The window keeps the panel's size
    /// until the close spring has settled, so a close is never cut off by AppKit shrinking the panel under it.
    @State private var isHistoryMounted = false
    /// Morph B's single progress: 0 = launcher, 1 = open panel. Shell, radii and rows all read it.
    @State private var historyProgress: CGFloat = 0
    @State private var historyMorphGeneration = 0
    @State private var historyPull = NotchHistoryPull()
    @State private var historyPressIsBare = false
    @State private var pendingHistoryReleaseVelocity: Double = 0
    @State private var pendingHistoryRowsVelocity: Double = 0
    /// Shots only: the rows the extend handle settled on, instead of the surface's detent.
    private var forcedHistoryRows: Int?
    /// The live, animated rows the shell and list draw while the handle is dragged or settling (6 or 8 at rest).
    @State private var historyRowsExtent = CGFloat(NotchHistoryMorph.visibleRows)
    /// A drag on the open drawer's body (2.4: drag UP closes, drag further DOWN opens Settings) owns the pull.
    @State private var isDrawerBodyDragActive = false
    @State private var isDismissedDrawerGesture = false
    @State private var drawerPullDismissalGeneration = 0
    @State private var drawerBodyDragEndedAt: TimeInterval = -1
    /// The pull has gone far enough past open that releasing it opens Settings.
    @State private var isSettingsPullArmed = false
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
    @State private var historyDismissal: NotchDrawerDismissal?
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
        onCancelNotchMenu: @escaping () -> Void = {},
        surface: NotchSurfaceModel? = nil,
        settingsDrawer: NotchSettingsDrawerContext? = nil,
        hostWindow: HostWindowBox? = nil
    ) {
        _notchAppearance = State(
            initialValue: VoiceBarNotchAppearance(
                effectiveAppearance: NSApplication.shared.effectiveAppearance
            )
        )
        if let hostWindow { _hostWindow = State(initialValue: hostWindow) }
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
        self.injectedSurface = surface
        self.settingsDrawer = settingsDrawer
    }

    // MARK: - The notch surface (2.4 Lane A)

    private var surface: NotchSurfaceModel { injectedSurface ?? ownSurface }

    /// A drawer is open (the intent). The shell morph animates toward it; `isHistoryMounted` covers the spring.
    private var isHistoryPresented: Bool { surface.isDrawerOpen }

    private var isSettingsDrawerOpen: Bool { surface.drawer?.isSettings == true }

    /// The rows the open drawer rests at: History's detent, or the expanded height for Settings (so the window
    /// never resizes between the two). A closed drawer keeps its detent's rows for the close spring.
    private var historyRows: Int {
        if let forcedHistoryRows { return forcedHistoryRows }
        let entries = state.recentTranscriptionEntries.count
        switch surface.drawer {
        case .settings: return NotchSettingsDrawerPresentation.rows
        case let .history(detent): return detent.rows(entryCount: entries)
        case nil: return pullOpensSettings ? NotchSettingsDrawerPresentation.rows
            : surface.historyDetent.rows(entryCount: entries)
        }
    }

    /// What the notch is doing, reported to the machine. Only agent speech closes a drawer and refuses a new one:
    /// the teleprompter, or an agent's Ask capturing (0510 R3: "as long as there's no teleprompter of speech or
    /// asking"). A dictation keeps the drawer under its wings.
    private func synchronizeSurfaceActivity() {
        let visual = notchPresentation.visualState
        surface.send(.recordingChanged(visual == .recording || state.mode == .recording))
        surface.send(.teleprompterChanged(visual == .teleprompter || state.isAskCapture))
    }

    private func toggleHistoryDrawer() {
        if surface.drawer?.isHistory == true {
            surface.send(.dismiss(.toggle))
        } else {
            // The button works wherever it shows (the launcher, a transcribing take); the machine still refuses
            // while recording, reading aloud or under a modal sheet.
            surface.send(.openHistory)
        }
    }

    private func toggleSettingsDrawer() {
        if isSettingsDrawerOpen {
            surface.send(.dismiss(.toggle))
        } else {
            surface.settingsRequest = nil
            surface.send(.openSettings(.general))
        }
    }

    /// A row's own click after a body drag is not a click (the drag already closed or moved the drawer).
    private var drawerBodyDragJustHappened: Bool {
        isDrawerBodyDragActive || NotchHistoryClock.now() - drawerBodyDragEndedAt < 0.35
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

    private var notchContentShell: some View {
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
        // A re-shown shell starts with resolved geometry; ordinary hover retains its spring state.
        .id(presentationModel?.presentationGeneration ?? 0)
        .onChange(of: state.mode) { _, newMode in
            handleModeChange(newMode)
        }
        .onChange(of: notchPresentation.geometry.leadingWingWidth, initial: true) { _, width in
            settledLeadingWingWidth = notchPresentation.visualState == .idle ? 0 : width
        }
        .onChange(of: notchPresentation.visualState) { _, visualState in
            scheduleMorphTeleprompterContent(for: visualState)
            synchronizeSurfaceActivity()
        }
        .overlay(alignment: .topLeading) { bareNotchControl }
        .transaction { if historyBridge?.presentedMenu != nil { $0.disablesAnimations = true; $0.animation = nil } }
        .coordinateSpace(name: Self.notchCanvasSpace)
        .gesture(historyPullGesture)
    }

    private var notchContent: some View {
        notchContentShell
        .onChange(of: isHistoryPullGestureActive) { _, isActive in
            // A press the system cancelled (no `onEnded`) ends here: a drag settles at the nearer end, a press still
            // inside the slop just ends, so the next gesture never reuses a stale start (Codex review R1).
            if !isActive, !isDrawerBodyDragActive, historyPull.phase != .idle || historyRowsPull.phase != .idle {
                endHistoryPull(cancelled: true)
            }
        }
        .onChange(of: historyRows) { _, rows in
            presentationModel?.setHistoryRows(rows)
            settleHistoryRowsExtent(to: rows)
        }
        .onChange(of: isHistoryPresented) { _, isOpen in
            synchronizeLauncherRetention()
            // U2×U4 review: a renewed open intent cancels a waiting notch menu even when the panel is still
            // mounted (reopened during its close spring), where no mount change reaches the handoff.
            if isOpen { historyBridge?.historyOpenRequested() }
            synchronizeHistoryDismissal(isOpen: isOpen)
            if !isOpen {
                isDismissedDrawerGesture = historyPull.phase != .idle || historyRowsPull.phase != .idle
                historyPull = NotchHistoryPull()
                historyRowsPull = NotchHistoryPull()
                isDrawerBodyDragActive = false
                isSettingsPullArmed = false
                presentationModel?.setHistoryPullActive(false)
            }
            let velocity = pendingHistoryReleaseVelocity
            pendingHistoryReleaseVelocity = 0
            if state.isHidden { resetHiddenDrawer() }
            else { animateHistory(toOpen: isOpen, velocity: velocity) }
        }
        .onChange(of: isHistoryMounted) { _, isMounted in
            synchronizeLauncherRetention()
            reportHistoryPanelMounted(isMounted)
        }
        .onDisappear {
            historyDismissal?.stop()
            modalObserver?.stop()
        }
        .background(HostWindowReader { window in hostWindow.rebind(window) })
        .onChange(of: surface.hideGeneration) { _, _ in resetHiddenDrawer() }
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
            presentationModel?.setHistoryRows(historyRows)
            historyRowsExtent = CGFloat(historyRows)
            synchronizeSurfaceActivity()
            startModalObserver()
            if isHistoryPresented {
                synchronizeHistoryDismissal(isOpen: true)
            }
            if isHistoryPresented, !isHistoryMounted {
                isHistoryMounted = true
                historyProgress = historyFrozenProgress ?? 1
                reportHistoryPanelMounted(true)
            }
        }
        .onChange(of: state.recentTranscriptionEntries.count) { _, count in
            if count == 0, surface.drawer?.isHistory == true {
                surface.send(.dismiss(.emptied))
            }
        }
        // 2.3 U2: a notch menu asked for the drawer to close first (VoiceBarNotchSurfaceHandoff).
        .onChange(of: historyBridge?.closeRequest ?? 0) { _, _ in
            surface.send(.dismiss(.menu))
        }
        .onChange(of: state.mode) { _, _ in synchronizeSurfaceActivity() }
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
            showsRecordingPause: recordingPauseControl != nil,
            hasTeleprompterText: state.teleprompterText != nil,
            isTeleprompterDismissed: state.isTeleprompterDismissed,
            isTeleprompterReadback: state.isTeleprompterReadback,
            isPlaybackPaused: state.isPlaybackPaused,
            readQueueLeadingSlotCount: VoiceBarPresentation.playbackLeadingSlotCount(for: state),
            confirmationText: state.confirmationText,
            commandModeState: state.commandModeState,
            activeClipMarker: state.activeClipMarker,
            queueDepth: state.queueDepth,
            keepsPasteFlowEnvelope: state.keepsPasteFlowEnvelope,
            hotkeyPhase: state.presentedHotkeyPhase,
            statusText: statusText,
            isHovered: state.isHovering,
            isKeyboardFocused: keepsLauncherMounted,
            isCollapsed: state.isCollapsed,
            visibleCoreOcclusionInset: 0,
            transientNote: state.selectionFeedbackNote,
            showsEarlierTakeProcessing: VoiceBarPresentation.showsEarlierTakeProcessing(for: state)
        )
        input.isHistoryPanelOpen = isHistoryMounted
        input.showsIdleMicrophoneControl = VoiceBarPresentation.showsIdleMicrophoneControl(for: state)
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
            // The band the drawer closes back into: the launcher's, or the activity's own (0510 R3).
            closed: VoiceBarNotchGeometry(
                coreWidth: presentation.geometry.coreWidth, topHeight: presentation.geometry.topHeight,
                leadingWingWidth: presentation.geometry.leadingWingWidth,
                trailingWingWidth: presentation.geometry.trailingWingWidth,
                bodyLeadingExtent: presentation.geometry.leadingWingWidth,
                bodyTrailingExtent: presentation.geometry.trailingWingWidth,
                lowerSurfaceHeight: 0
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
        let drawn = max(0, renderedHistoryProgress(at: now))
        let carried = (historyFlight?.velocity(at: now) ?? 0) + velocity
        if !toOpen {
            let speed = NotchHistoryMorph.closingVelocity(from: drawn, velocity: carried)
            // End the previous animation before starting a close, so SwiftUI cannot merge its opening velocity.
            historyFlight = nil
            var stop = Transaction(); stop.disablesAnimations = true
            withTransaction(stop) { historyProgress = drawn }
            DispatchQueue.main.async {
                guard generation == historyMorphGeneration, !isHistoryPresented else { return }
                let start = NotchHistoryClock.now()
                historyFlight = NotchHistorySpringFlight(from: drawn, to: 0, velocity: speed, start: start,
                    response: NotchHistoryMorph.closeResponse, dampingFraction: NotchHistoryMorph.closeDampingFraction)
                withAnimation(NotchHistoryMorph.animation(opening: false, from: drawn, velocity: speed),
                              completionCriteria: .removed) {
                    historyProgress = 0
                } completion: {
                    guard generation == historyMorphGeneration, !isHistoryPresented else { return }
                    isHistoryMounted = false
                }
            }
            return
        }
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
                guard !isDismissedDrawerGesture else { return }
                let openHeight = notchPresentationOpenHistoryHeight
                let time = NotchHistoryClock.now()
                if isDrawerBodyDragActive { return }
                if case .idle = historyPull.phase, case .idle = historyRowsPull.phase {
                    historyPressIsBare = abs(value.startLocation.x - historyPanelCentreX) <= notchPresentation.geometry.coreWidth / 2
                        && NotchHistoryPull.accepts(y: value.startLocation.y)
                    guard canPullDrawer || isSettingsDrawerOpen || historyPressIsBare else { return }
                    if NotchHistoryPull.accepts(y: value.startLocation.y) {
                        drawerPullDismissalGeneration = surface.dismissalGeneration
                        historyPull.press(y: value.startLocation.y, progress: historyProgress, time: time)
                    } else if isHistoryPresented, NotchHistoryPull.acceptsHandle(
                        point: value.startLocation, centreX: historyPanelCentreX,
                        panelHeight: openHeight, progress: historyFrozenProgress ?? renderedHistoryProgress(at: time)
                    ) {
                        drawerPullDismissalGeneration = surface.dismissalGeneration
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
                guard canPullDrawer || isSettingsDrawerOpen else { return }
                followHistoryPull(y: value.location.y, time: time, openHeight: openHeight)
            }
            .onEnded { _ in
                defer { isDismissedDrawerGesture = false }
                guard !isDismissedDrawerGesture, !isDrawerBodyDragActive else { return }
                endHistoryPull(cancelled: false)
            }
    }

    /// The open drawer's body follows a vertical drag too (2.4, Etan: "drag UP closes it, mirroring drag-down to
    /// open"; dragging further down opens Settings). It is a simultaneous gesture, so rows and buttons keep their
    /// clicks; a row's click right after a drag is ignored (`drawerBodyDragJustHappened`).
    private var drawerBodyDragGesture: some Gesture {
        DragGesture(minimumDistance: NotchHistoryMorph.dragSlop, coordinateSpace: .named(Self.notchCanvasSpace))
            .onChanged { value in
                guard !isDismissedDrawerGesture else { return }
                let time = NotchHistoryClock.now()
                if !isDrawerBodyDragActive {
                    guard case .idle = historyPull.phase, case .idle = historyRowsPull.phase, isHistoryPresented,
                          (historyFrozenProgress ?? renderedHistoryProgress(at: NotchHistoryClock.now())) > 0.98
                    else { return }
                    isDrawerBodyDragActive = true
                    drawerPullDismissalGeneration = surface.dismissalGeneration
                    historyPull.press(y: value.startLocation.y, progress: historyProgress, time: time)
                }
                followHistoryPull(y: value.location.y, time: time, openHeight: notchPresentationOpenHistoryHeight)
            }
            .onEnded { _ in
                defer { isDismissedDrawerGesture = false }
                guard !isDismissedDrawerGesture, isDrawerBodyDragActive else { return }
                endHistoryPull(cancelled: false)
                isDrawerBodyDragActive = false
                drawerBodyDragEndedAt = NotchHistoryClock.now()
            }
    }

    /// A close wins over a release in the same event turn, before `.onChange` can cancel the local pull.
    private func admitsCurrentDrawerGesture() -> Bool {
        guard drawerPullDismissalGeneration == surface.dismissalGeneration else {
            historyPull = NotchHistoryPull(); historyRowsPull = NotchHistoryPull()
            isDrawerBodyDragActive = false; isSettingsPullArmed = false
            presentationModel?.setHistoryPullActive(false)
            return false
        }
        return true
    }

    /// One pull follow for the band and the body: the panel tracks the pointer, and past open it arms Settings.
    private func followHistoryPull(y: CGFloat, time: TimeInterval, openHeight: CGFloat) {
        guard admitsCurrentDrawerGesture() else { return }
        guard let progress = historyPull.move(
            y: y, time: time, range: openHeight - VoiceBarNotchContract.topHeight,
            seed: renderedHistoryProgress(at: time)
        ) else { return }
        let armed = settingsDrawer != nil && !isSettingsDrawerOpen
            && historyPull.rawProgress >= NotchHistoryMorph.settingsPullThreshold
        if armed != isSettingsPullArmed {
            // C6 L2 (N17): the grip and "Release for Settings" cross in one beat, never a one-frame swap.
            withAnimation(NotchDrawerMotion.easeOut(armed ? NotchDrawerMotion.hintInDuration
                                                          : NotchDrawerMotion.hintOutDuration)) {
                isSettingsPullArmed = armed
            }
        }
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

    /// The handle's own drag (see NotchHistoryExtendHandle): the same press rules as the canvas path (the panel fully
    /// open, no open/close pull in progress), then the same row follow.
    private func dragHistoryHandle(y: CGFloat, time: TimeInterval) {
        if case .idle = historyRowsPull.phase {
            guard case .idle = historyPull.phase, isHistoryPresented,
                  (historyFrozenProgress ?? renderedHistoryProgress(at: time)) > 0.98 else { return }
            drawerPullDismissalGeneration = surface.dismissalGeneration
            historyRowsPull.press(y: y, progress: historyRowsExtent, time: time)
        }
        dragHistoryRows(to: y, time: time)
    }

    /// V6: the extend handle follows the pointer one row per 46 pt, stretching past the last row. Pushed above the
    /// collapsed rows it closes the panel with the pointer instead (0510 N4, `NotchHistoryMorph.handleDrag`).
    private func dragHistoryRows(to y: CGFloat, time: TimeInterval) {
        guard admitsCurrentDrawerGesture() else { return }
        let maximum = NotchHistoryMorph.maximumRows(entryCount: state.recentTranscriptionEntries.count)
        guard historyRowsPull.move(
            y: y, time: time, range: NotchHistoryMorph.rowHeight,
            band: { NotchHistoryMorph.rowsRubberBand($0, maximum: maximum) },
            seed: renderedHistoryRows(at: time)
        ) != nil else { return }
        let follow = NotchHistoryMorph.handleDrag(
            rawRows: historyRowsPull.rawProgress, maximum: maximum,
            openTravel: notchPresentationOpenHistoryHeight - VoiceBarNotchContract.topHeight
        )
        historyRowsFlight = nil
        historyFlight = nil
        presentationModel?.setHistoryPullActive(true)
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            historyRowsExtent = follow.rows
            historyProgress = follow.progress
        }
    }

    /// A drag on the open drawer (its body, History's handle or Settings' grip) owns the pointer.
    private var drawerHoldsPointer: Bool {
        isDrawerBodyDragActive || historyRowsPull.phase != .idle
    }

    /// 0510 N4: Settings' grip pushes the drawer closed under the pointer, the same open/close pull as History's
    /// body: it follows, and a release past halfway (or a flick up) closes it.
    private func dragDrawerGrip(y: CGFloat, time: TimeInterval) {
        guard !isDismissedDrawerGesture else { return }
        if !isDrawerBodyDragActive {
            guard case .idle = historyPull.phase, case .idle = historyRowsPull.phase, isHistoryPresented,
                  (historyFrozenProgress ?? renderedHistoryProgress(at: time)) > 0.98 else { return }
            isDrawerBodyDragActive = true
            drawerPullDismissalGeneration = surface.dismissalGeneration
            historyPull.press(y: y, progress: historyProgress, time: time)
        }
        followHistoryPull(y: y, time: time, openHeight: notchPresentationOpenHistoryHeight)
    }

    private func endDrawerGripDrag(cancelled: Bool) {
        defer { isDismissedDrawerGesture = false }
        guard isDrawerBodyDragActive else { return }
        endHistoryPull(cancelled: cancelled)
        isDrawerBodyDragActive = false
        drawerBodyDragEndedAt = NotchHistoryClock.now()
    }

    /// A released (or cancelled) handle settles on the nearest whole row with the `pull` spring; the hit region and
    /// the session's remembered height take the settled rows at once. A press that never moved changes nothing.
    private func endHistoryRowsPull(cancelled: Bool) {
        guard admitsCurrentDrawerGesture() else { return }
        presentationModel?.setHistoryPullActive(false)
        let rawRows = historyRowsPull.rawProgress
        guard case let .settle(_, velocity) = historyRowsPull.release(progress: historyRowsExtent, cancelled: cancelled)
        else { return }
        // 2.4 Lane A: pushing the bottom edge up past the collapsed rows closes History (the mirror of pulling it
        // down); the rows spring back to the detent for the next open. A cancelled push settles at the nearer end,
        // so one that already closed the panel more than halfway closes it.
        if NotchHistoryMorph.handleClosesHistory(rawRows: rawRows), !cancelled || historyProgress < 0.5 {
            surface.send(.dismiss(.dragUp))
            settleHistoryRowsExtent(to: historyRows, velocity: 0)
            return
        }
        // A push that closed the panel part-way and was let go short of closing springs it open again.
        if historyProgress < 1 { animateHistory(toOpen: true) }
        let detent = NotchHistoryDetent.nearest(rows: historyRowsExtent)
        let previous = historyRows
        surface.send(.setHistoryDetent(detent))
        // The same detent again (a drag that springs back) changes no rows, so settle the extent here.
        if historyRows == previous { settleHistoryRowsExtent(to: previous, velocity: velocity) }
        pendingHistoryRowsVelocity = velocity
    }

    /// The extent springs to the drawer's resting rows (a detent change, a History/Settings swap) on THE spring.
    private func settleHistoryRowsExtent(to rows: Int, velocity: Double? = nil) {
        guard historyRowsPull.phase == .idle else { return }
        let velocity = velocity ?? pendingHistoryRowsVelocity
        pendingHistoryRowsVelocity = 0
        guard abs(historyRowsExtent - CGFloat(rows)) > 0.001 else { return }
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
            onMenu: onOpenNotchMenu, onHistory: { if canPullHistory { surface.send(.openHistory) } },
            onClose: { surface.send(.dismiss(.escape)); onCancelNotchMenu() })
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
        guard !isDismissedDrawerGesture, admitsCurrentDrawerGesture() else { return }
        if historyRowsPull.phase != .idle {
            endHistoryRowsPull(cancelled: cancelled)
            return
        }
        let wasBare = historyPressIsBare
        historyPressIsBare = false
        let opensSettings = isSettingsPullArmed && !cancelled
        isSettingsPullArmed = false
        presentationModel?.setHistoryPullActive(false)
        switch historyPull.release(progress: historyProgress, cancelled: cancelled) {
        case let .settle(open, velocity):
            if open, opensSettings || pullOpensSettings && !isHistoryPresented {
                // Pulled past open: Settings, at the same spot and on the same spring (History's list crossfades
                // into the drawer, `notchLowerPanelContent`).
                surface.send(.openSettings(.general))
                animateHistory(toOpen: true, velocity: velocity)
            } else if open == isHistoryPresented {
                animateHistory(toOpen: open, velocity: velocity)
            } else {
                pendingHistoryReleaseVelocity = velocity
                if open {
                    surface.send(.openHistory)
                    // A refused open (recording began mid-pull) still has to spring the drawn panel home.
                    if !isHistoryPresented { animateHistory(toOpen: false, velocity: velocity) }
                } else {
                    surface.send(.dismiss(.dragUp))
                }
            }
        case .click:
            if wasBare && !cancelled { onOpenNotchMenu() }
        case .none:
            break
        }
    }

    /// A drawer pulls down from the launcher, from itself, and (0510 N7) while recording, transcribing or on a
    /// compact status such as Typed; never over the teleprompter, during agent speech or an Ask. With no History
    /// rows the pull is Settings' (review F3: the recording wing has no gear, so the pull is its only route), when
    /// this notch has a Settings drawer at all.
    private var canPullDrawer: Bool {
        let visual = notchPresentation.visualState
        let speaking = state.mode == .speaking || state.isAskCapture
        return [.hoverLauncher, .history, .recording, .compactStatus].contains(visual) && !speaking
            && (!state.recentTranscriptionEntries.isEmpty || settingsDrawer != nil)
    }

    /// History itself never opens empty.
    private var canPullHistory: Bool {
        canPullDrawer && !state.recentTranscriptionEntries.isEmpty
    }

    /// With no History rows, a pull from the notch draws and opens Settings instead (review F3).
    private var pullOpensSettings: Bool {
        settingsDrawer != nil && state.recentTranscriptionEntries.isEmpty
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
            let surface = surface
            historyDismissal = NotchDrawerDismissal { reason in surface.send(.dismiss(reason)) }
        }
        if let historyDismissal { hostWindow.bind(historyDismissal) }
        historyDismissal?.start()
    }

    private func resetHiddenDrawer() {
        historyMorphGeneration &+= 1
        historyDismissal?.stop()
        historyPull = NotchHistoryPull()
        historyRowsPull = NotchHistoryPull()
        historyFlight = nil
        historyRowsFlight = nil
        isDrawerBodyDragActive = false
        isSettingsPullArmed = false
        pendingHistoryReleaseVelocity = 0
        pendingHistoryRowsVelocity = 0
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            historyProgress = 0
            isHistoryMounted = false
            historyRowsExtent = CGFloat(historyRows)
        }
        reportHistoryPanelMounted(false)
    }

    /// A Settings sheet or alert closes the drawer and keeps new ones from opening over it.
    private func startModalObserver() {
        guard modalObserver == nil else { return }
        let surface = surface
        let observer = NotchModalObserver { isModal in surface.send(.modalChanged(isModal)) }
        modalObserver = observer
        observer.start()
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
        switch notchPresentation.bandState {
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
                // Recording pause sits beside Stop, in its own control slot.
                // X16 (Etan J4; M4 live bisection): no per-item insertion transition here. The daemon's `ptt` event
                // inserts this control after the wing exists, and with `VoiceBarNotchWingContentEntry.transition` on it
                // AppKit never showed its tooltip while Stop and Cancel beside it did. It enters the slot Stop leaves,
                // which the glass already covers; Stop is what moves out with the growing wing.
                if let recordingPauseControl {
                    notchButton(
                        icon: recordingPauseControl.iconName,
                        isSelected: recordingPauseControl.isSelected,
                        selectionStyle: .recordingState,
                        accessibilityLabel: recordingPauseControl.accessibilityLabel,
                        accessibilityHint: recordingPauseControl.accessibilityHint,
                        tooltip: recordingPauseControl.tooltip
                    ) {
                        state.setRecordingPaused(!state.isRecordingPaused)
                    }
                    .contentTransition(.symbolEffect(.replace))
                }
                notchButton(icon: "xmark", accessibilityLabel: "Cancel recording") {
                    commandRouter.handleCancel()
                }
                // X21 (as X16 for mute): no per-item insertion transition here. The daemon's `vad` event inserts Lock
                // after the wing exists, growing it by one slot; with `VoiceBarNotchWingContentEntry.transition` on a
                // late control AppKit does not show its tooltip (bisected live on the M4 for mute). Lock takes the slot
                // Cancel vacates, which the glass already covers; Cancel and Stop move out with the growing wing.
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
            // Keep the controls on their core-anchored hit regions as the symmetric wing grows.
            .frame(maxWidth: .infinity, alignment: .trailing)
            // R0856-05: the recording controls arrive with a wider wing; they show once its glass covers them.
            .transition(VoiceBarNotchWingContentEntry.transition(growth: leadingWingGrowth))
        case .compactStatus, .teleprompter:
            if notchPresentation.bandState == .compactStatus, state.mode == .transcribing {
                // 2.3 U2: the spinner sits where Stop was, in a control slot so it lines up with it. It is not a
                // control, so it registers no tooltip (R0856-09: tooltips sit on controls); VoiceOver reads it.
                // 0510 N9: the microphone control keeps its core-side slot, as on the launcher.
                HStack(spacing: VoiceBarNotchContract.material.compactControlSpacing) {
                    transcriptionSpinner
                    microphonePickerButton
                }
            } else if let playbackPauseControl {
                readingTransportControls(playbackPauseControl)
            } else if notchPresentation.bandState == .compactStatus,
                      state.mode == .idle, VoiceBarPresentation.readQueueControl(for: state) != nil {
                playbackLeadingControls(nil)
            } else if notchPresentation.bandState == .compactStatus {
                if VoiceBarPresentation.showsIdleMicrophoneControl(for: state) {
                    // 0510 N9 (Typed and every other idle notice): the launcher's mic and chevron, unchanged.
                    HStack(spacing: VoiceBarNotchContract.material.compactControlSpacing) {
                        statusIcon
                        microphonePickerButton
                    }
                } else {
                    statusIcon
                }
            }
        }
    }

    private var transcriptionSpinner: some View {
        ProcessingSpinner()
            .frame(width: VoiceBarNotchContract.material.compactControlSize,
                   height: VoiceBarNotchContract.material.compactControlSize)
            .accessibilityElement()
            .accessibilityLabel("Transcribing")
            .accessibilityAddTraits(.updatesFrequently)
    }

    private var playbackPauseControl: VoiceBarPlaybackPauseControl? {
        VoiceBarPresentation.playbackPauseControl(for: state)
    }

    /// QUEUE1: pause/play, then Next and the "+N" count toward the core; one control slot each so the hit rects match.
    private func playbackLeadingControls(_ pause: VoiceBarPlaybackPauseControl?) -> some View {
        HStack(spacing: VoiceBarNotchContract.material.compactControlSpacing) {
            if state.showsReadingProcessingSpinner { transcriptionSpinner }
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

    /// T1/T6 (Etan QA 2026-11-09: "the backwards and forwards button need to go next to the pause button. There's
    /// also a ton of space next to it ... They can be disabled or enabled depending on if there is something queued or
    /// not" and "the 1× can probably just go to the top next to the play pause backwards and forwards"). From the
    /// outer edge: speed, Back, Pause/Play, Forward. Back and Forward walk the CURRENT queue only and are disabled
    /// when nothing waits in that direction. One control slot each from the core, so the hit rects match; the speed
    /// chip is the outermost, wider control (`VoiceBarPresentation.readingSpeedChipWidth`).
    private func readingTransportControls(_ pause: VoiceBarPlaybackPauseControl) -> some View {
        let forward = VoiceBarPresentation.readingForwardControl(for: state)
        let material = VoiceBarNotchContract.material
        return HStack(spacing: material.compactControlSpacing) {
            readingSpeedChip
            notchButton(
                icon: "backward.end.fill",
                accessibilityLabel: "Previous read",
                accessibilityHint: "Replay the read before this one in the queue"
            ) {
                state.playPreviousRead()
            }
            .disabled(!state.previousReadAvailable)
            .opacity(state.previousReadAvailable ? 1 : VoiceBarPresentation.disabledTransportOpacity)
            playbackPauseButton(pause)
            if forward.showsProcessingSpinner {
                // Q1 (open): with nothing queued, an Ask answer still transcribing shows its spinner in Forward's slot.
                transcriptionSpinner
            } else {
                notchButton(
                    icon: "forward.end.fill",
                    accessibilityLabel: "Next read",
                    accessibilityHint: forward.accessibilityHint
                ) {
                    state.skipToNextRead()
                }
                .disabled(!forward.isEnabled)
                .opacity(forward.isEnabled ? 1 : VoiceBarPresentation.disabledTransportOpacity)
                // X1-30: the queued count, clear of Forward's glyph (`VoiceBarQueueCountBadge`).
                .queueCountBadge(forward.countLabel, accessibilityLabel: forward.countAccessibilityLabel)
            }
        }
        .fixedSize()
        .animation(.easeOut(duration: 0.2), value: state.readQueueCount)
        // The row is 6 pt wider than the wing's nominal lane: it lays out at the lane's width, so its core-side slots
        // stay on their hit rects, and draws into the outer inset (8 pt from the edge, like the fixed wings).
        .padding(.leading, VoiceBarNotchContract.fixedWingContentInset - VoiceBarNotchContract.material.compactContentInset)
    }

    /// T6: the listening speed, a real control (each click steps 0.75× · 1× · 1.25× · 1.5× · 2×).
    private var readingSpeedChip: some View {
        Button { state.cyclePlaybackSpeed() } label: {
            Text(VoiceState.speedLabel(state.playbackSpeed))
                .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(width: VoiceBarPresentation.readingSpeedChipWidth, height: 18)
                .background(Capsule().fill(notchPalette.subtleTrack.color))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .foregroundStyle(notchPalette.secondary.color)
        .frame(height: VoiceBarNotchContract.material.compactControlSize)
        .background(PillControlTooltip(text: "Playback speed"))
        .accessibilityLabel("Playback speed")
        .accessibilityValue(VoiceState.speedLabel(state.playbackSpeed))
    }

    /// P16: Pause parks the read on its word. X1-34 (Etan QA 2026-11-10): the teleprompter stays as it was, readable;
    /// only the eye hides or shows it, paused or playing.
    private func playbackPauseButton(_ control: VoiceBarPlaybackPauseControl) -> some View {
        notchButton(
            icon: control.iconName,
            accessibilityLabel: control.accessibilityLabel,
            accessibilityHint: control.accessibilityHint
        ) {
            if state.isParkedReadAwaitingFeedback {
                state.restoreParkedReadNow()
            } else {
                state.togglePlaybackPause()
            }
        }
        .contentTransition(.symbolEffect(.replace))
    }

    @ViewBuilder
    private var notchTrailingContent: some View {
        switch notchPresentation.bandState {
        case .idle:
            EmptyView()
        case .hoverLauncher, .history:
            HStack(spacing: VoiceBarNotchContract.material.compactControlSpacing) {
                historyButton
                settingsButton
            }
        case .recording:
            // QA 0449: the time/meter group is centred in equal wings, with a clear gap and no blank outer region.
            // Capture-open still owns the timer; the capturing microphone remains its tooltip and VoiceOver value.
            VoiceBarRecordingTrailingRow {
                VoiceBarRecordingTimeRegion(
                    elapsedMilliseconds: { state.recordingElapsedMilliseconds() },
                    isCaptureOpen: state.isRecordingCaptureOpen,
                    microphoneName: state.recordingMicrophoneName,
                    color: notchPrimaryLabelColor
                )
            } meter: {
                if state.isRecordingPaused {
                    notchWaveform(isPaused: true)
                        .accessibilityElement()
                        .accessibilityLabel("Recording paused")
                        // VoiceOver reads the same frozen time the wing shows.
                        .accessibilityValue(VoiceBarReadingTimeLabel.text(
                            elapsedMilliseconds: state.recordingElapsedMilliseconds()))
                } else {
                    notchWaveform
                }
            }
        case .compactStatus, .teleprompter:
            if state.mode == .speaking {
                notchSpeakingTrailingContent
            } else if notchPresentation.bandState == .compactStatus {
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

    /// T5/T7 (Etan QA 2026-11-09: "the waveform is blue but is consistent with the same waveform and time stuff that
    /// we have when recording" and "maybe just the red stop button goes to the bottom"): reading aloud lays the right
    /// wing out like recording, time then level meter (blue: the playback level). With the teleprompter open, the red
    /// Stop sits in its eye row. Collapsed (paused or hidden) there is no eye row, so Stop follows the meter; a hidden
    /// but playing read puts Show teleprompter over the meter's last slot, one pitch inside Stop.
    /// X4 (Etan, PR #860): the row is centred in the visible wing, with no blank outer region.
    /// X1-34: pause no longer collapses; a hidden read, playing or paused, keeps its eye here.
    private var notchSpeakingTrailingContent: some View {
        let isCompact = notchPresentation.bandState == .compactStatus
        let showsReveal = VoiceBarPresentation.showsWingTeleprompterReveal(
            reading: VoiceBarPresentation.readingState(for: state), bandState: notchPresentation.bandState)
        return VoiceBarReadingTrailingRow(showsStop: isCompact) {
            VoiceBarReadingTimeRegion(
                elapsedMilliseconds: { state.playbackElapsedMilliseconds() },
                color: notchPrimaryLabelColor,
                showsClock: { state.showsPlaybackClock }
            )
        } meter: {
            ZStack(alignment: .trailing) {
                notchWaveform
                    .opacity(showsReveal ? 0 : 1)
                if showsReveal {
                    notchTeleprompterButton(
                        icon: "eye",
                        accessibilityLabel: "Show teleprompter"
                    ) {
                        state.showTeleprompter()
                    }
                }
            }
            .frame(width: WaveformLayout.viewportWidth, alignment: .trailing)
        } stop: {
            readingTerminalButton
        }
        // As when recording, the row is centred clear of the PHYSICAL notch (the glass hides the wing's first points).
        .padding(.leading, max(0, notchPresentation.visibleCoreOcclusionInset))
    }

    /// The live read's terminal control. Collapsed it sits in the right wing; with the teleprompter open, in the eye
    /// row (T7). X1-32: the red Stop square while audio plays, an X ("Close read") once paused. Both end the read
    /// through the same Stop route, so the real-Stop host stays on it.
    private var readingTerminalButton: some View {
        let control = VoiceBarPresentation.readingTerminalControl(
            for: VoiceBarPresentation.readingState(for: state) ?? .playing)
        return notchTeleprompterButton(
            icon: control.iconName,
            isDestructive: control.isDestructive,
            accessibilityLabel: control.accessibilityLabel
        ) {
            commandRouter.handleStop()
        }
        .accessibilityHint(control.accessibilityHint)
        .contentTransition(.symbolEffect(.replace))
        .background(playbackStopHostProbe)
    }

    private var notchWaveform: some View {
        notchWaveform(isPaused: false)
    }

    private func notchWaveform(isPaused: Bool) -> some View {
        VoiceBarNotchWaveform(
            mode: state.mode,
            isListening: !state.speechDetected,
            isCaptureLive: state.captureLive,
            recordingLevel: { state.recordingWaveformLevel },
            playbackLevel: { state.playbackAudioLevel() },
            isPlaybackEnded: state.isTeleprompterReadback || state.isPlaybackPaused || isPaused
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
            // C6 L2 (S9): History's list and the Settings drawer crossfade at the threshold (and back), sharing this
            // frame while they cross. The tab switch inside the drawer crossfades in `NotchSettingsDrawer`.
            NotchDrawerCrossfade(
                key: settingsTabShown != nil && settingsDrawer != nil,
                animation: NotchDrawerMotion.easeOut(NotchDrawerMotion.contentInDuration),
                transition: NotchDrawerMotion.contentTransition(reduceMotion: accessibilityReduceMotion)
            ) { showsSettings in
                notchDrawerContent(showsSettings: showsSettings)
            }
        } else if isMorphTeleprompterContentPresented {
            // T2/T8 (Etan QA 2026-11-09): text, then the scrubber close to the eye row, then the height handle under
            // the eye row. No footer row; the tight gaps leave the room to the text.
            VStack(spacing: 0) {
                notchTeleprompterTimeline
                    .frame(maxWidth: .infinity, maxHeight: state.showsTeleprompterScrubber ? nil : .infinity)
                    .frame(height: state.showsTeleprompterScrubber ? teleprompterBodyHeight : nil)
                if state.showsTeleprompterScrubber {
                    TeleprompterPlaybackScrubBar(state: state)
                        .drawingTimingNotice(false)
                        .padding(.top, TeleprompterA.scrubberGap)
                }
                // Live and stopped text both fill their body; only the designed 3 pt gap remains here.
                Spacer(minLength: TeleprompterA.controlsGap)
                notchTeleprompterControls
                if showsTeleprompterA {
                    TeleprompterAHeightHandle(
                        visibleLines: state.teleprompterVisibleLines,
                        onVisibleLinesChange: { lines in
                            // The hit region takes the lines before the pull lets go of the pointer
                            // (formal/teleprompter-a-handle).
                            state.teleprompterVisibleLines = lines
                            presentationModel?.setTeleprompterLines(lines)
                        },
                        onHandleDrag: { presentationModel?.setTeleprompterHandlePullActive($0) }
                    )
                    .padding(.top, TeleprompterA.handleGap)
                } else {
                    // The row keeps one height from the bottom (the hit region's `lowerControlBottomInset`).
                    Color.clear.frame(height: TeleprompterA.handleGap + TeleprompterA.handleBandHeight)
                }
            }
            .padding(
                .horizontal,
                VoiceBarNotchContract.material.teleprompterBodyHorizontalInset
            )
            .padding(.top, TeleprompterA.bodyTopInset)
            .padding(.bottom, TeleprompterA.bodyBottomInset)
            .transition(.opacity)
        }
    }

    /// History's list or the Settings drawer (C6 L2: `NotchDrawerCrossfade` crossfades between the two).
    @ViewBuilder
    private func notchDrawerContent(showsSettings: Bool) -> some View {
        if showsSettings, let settingsDrawer {
            VStack(spacing: 0) {
                NotchSettingsDrawer(
                    selectedTab: settingsTabShown ?? .general, appearance: notchAppearance, context: settingsDrawer, request: surface.settingsRequest,
                    history: {
                        AnyView(historyPanelContent(listHeight: NotchSettingsDrawerPresentation.historyListHeight)
                            .padding(.top, NotchHistoryMorph.listTopInset))
                    },
                    onSelectTab: { surface.send(.selectSettingsTab($0)) }
                )
                .simultaneousGesture(drawerBodyDragGesture)
                // 0510 N4: the panes scroll inside themselves, so the drawer gets History's grip to push it closed.
                NotchHistoryExtendHandle(
                    palette: notchPalette, onDrag: dragDrawerGrip, onDragEnd: endDrawerGripDrag
                )
            }
            .frame(maxHeight: .infinity, alignment: .top)
            .modifier(NotchHistoryRowsMorph(progress: historyFrozenProgress ?? historyProgress,
                                            keepsPointer: drawerHoldsPointer))
        } else {
            VStack(spacing: 0) {
                historyPanelContent()
                    .padding(.horizontal, NotchHistoryMorph.listHorizontalInset)
                    .padding(.top, NotchHistoryMorph.listTopInset)
                    .simultaneousGesture(drawerBodyDragGesture)
                NotchHistoryExtendHandle(
                    palette: notchPalette,
                    rows: (historyRows, NotchHistoryMorph.maximumRows(entryCount: state.recentTranscriptionEntries.count),
                           adjustHistoryRows),
                    showsGrip: !isSettingsPullArmed,
                    onDrag: dragHistoryHandle,
                    onDragEnd: { cancelled in
                        if historyRowsPull.phase != .idle { endHistoryRowsPull(cancelled: cancelled) }
                    }
                )
                // 0510 N6: the hint takes the handle's band (the overpull stretches the shell under it), never a row.
                .overlay {
                    if isSettingsPullArmed { settingsPullHint }
                }
            }
                .frame(maxHeight: .infinity, alignment: .top)
                .modifier(NotchHistoryRowsMorph(progress: historyFrozenProgress ?? historyProgress,
                                                keepsPointer: drawerHoldsPointer))
        }
    }

    /// The Settings tab the lower panel draws: the open Settings drawer's, or General while a pull with no History
    /// rows previews Settings (review F3).
    private var settingsTabShown: SettingsTab? {
        if case let .settings(tab) = surface.drawer { return tab }
        return surface.drawer == nil && pullOpensSettings ? .general : nil
    }

    /// Shown while a pull past open is armed: releasing opens Settings. It fits the handle's 18 pt band (0510 N6).
    private var settingsPullHint: some View {
        NotchSettingsPullHint(ink: notchPalette.primary.color)
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
                    visibleLines: state.teleprompterVisibleLines,
                    // Lane B: the column is the body's whole text width (no 404 pt cap).
                    columnWidth: VoiceBarNotchContract.material.teleprompterTextWidth(
                        coreWidth: notchPresentation.geometry.coreWidth),
                    playbackElapsedMilliseconds: state.playbackElapsedMilliseconds,
                    onSpeechSeek: { state.seekSpeechWord(utteranceID: $0, wordIndex: $1) },
                    onSeek: state.seek,
                    onTextLinesChange: { state.reportTeleprompterTextLines($0) },
                    narrationOrigin: state.narrationOrigin,
                    allowsBrowsing: !state.isTeleprompterDismissed,
                    readIdentity: state.teleprompterReadIdentity
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
                    viewportHeight: teleprompterBodyHeight,
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

    /// Port main's stopped-read fill to 2.4's scrubber/control/handle stack (S4-F2/F3).
    private var teleprompterBodyHeight: CGFloat {
        showsTeleprompterA ? TeleprompterA.bodyHeight(lines: state.teleprompterVisibleLines)
            : TeleprompterA.stoppedBodyHeight(lines: state.teleprompterVisibleLines)
    }

    /// U5: live reading uses Teleprompter A; an idle-retained readback keeps its scrolling view.
    private var showsTeleprompterA: Bool { state.mode == .speaking && !state.isTeleprompterReadback }

    /// T4/T7 (Etan QA 2026-11-09: "they're not in one flex box together centered" and "maybe just the red stop button
    /// goes to the bottom"). X4 (Etan, PR #860: "stop / eye / replay not centred with the drag bar"): Replay, the eye
    /// and the terminal control (the live red Stop while reading, X on an ended readback) are one row centred in the
    /// body, on the drag bar's centre.
    private var notchTeleprompterControls: some View {
        HStack(spacing: VoiceBarPresentation.teleprompterLowerControlSpacing) {
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
            notchTeleprompterTerminal
        }
        .frame(maxWidth: .infinity)
        .overlay(alignment: .leading) {
            // T8: the scrubber's notice sits at the row's leading edge, clear of the centred group, so it adds no
            // height between the scrubber and this row. R883: paused, it is the pause reason ("Paused. Press Play to
            // seek"), drawn because the frozen slider is disabled and `.help` never shows in this panel; otherwise
            // "Word timing unavailable". Its native tooltip repeats it in full should the line ever truncate.
            if state.showsTeleprompterScrubber, let notice = TeleprompterPlaybackScrubBar(state: state).notice {
                Text(notice)
                    .font(.system(size: 10))
                    .foregroundStyle(notchPalette.tertiary.color)
                    .lineLimit(1)
                    .background(PillControlTooltip(text: notice))
                    .allowsHitTesting(false)
            }
        }
        .frame(height: TeleprompterA.controlsHeight)
    }

    @ViewBuilder
    private var notchTeleprompterTerminal: some View {
        if state.isTeleprompterReadback {
            notchTeleprompterDismissButton
        } else if state.mode == .speaking {
            readingTerminalButton
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
        // 0510 N8: a drawer stays open through recording and transcribing; agent speech takes the notch.
        if newMode == .speaking {
            surface.send(.dismiss(.voiceActivity))
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
            hotkeyPhase: state.presentedHotkeyPhase,
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

    private var recordingPauseControl: VoiceBarRecordingPauseControl? {
        VoiceBarPresentation.recordingPauseControl(
            mode: state.mode,
            recordingMode: state.recordingMode,
            isPaused: state.isRecordingPaused
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
            isSelected: surface.drawer?.isHistory == true,
            accessibilityLabel: surface.drawer?.isHistory == true ? "Close history" : "History"
        ) {
            toggleHistoryDrawer()
        }
    }

    /// 2.3 U2: a setup problem badges the gear (an orange dot) instead of adding a third icon; the badged gear
    /// opens Settings at the setup spot.
    private var settingsButton: some View {
        let missing = state.setupMissingPermissions
        let needsAttention = !missing.isEmpty
        return notchButton(
            icon: "gearshape",
            isSelected: isSettingsDrawerOpen,
            accessibilityLabel: VoiceBarSetupAttention.accessibilityLabel(missing: missing),
            tooltip: VoiceBarSetupAttention.tooltip(missing: missing)
        ) {
            if settingsDrawer != nil {
                // 2.4 Lane A: the gear opens Settings in the notch; General shows any broken setup step first.
                toggleSettingsDrawer()
            } else if state.setupNeedsAttention {
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

    /// 0510 N9 (Etan, R4: the mic control "should take you to the right settings page in the notch app", the same
    /// every time): wherever it shows, it opens Settings › General at Microphone priority in the notch, and
    /// closes it again from there. Without a Settings drawer (2.3 hosts) it keeps opening the microphone list.
    private var microphonePickerButton: some View {
        notchButton(
            icon: "chevron.down",
            isSelected: isMicrophoneSettingsOpen,
            accessibilityLabel: "Choose microphone",
            tooltip: "Choose microphone"
        ) {
            guard settingsDrawer != nil else { return onOpenMicrophonePicker() }
            if isMicrophoneSettingsOpen {
                surface.send(.dismiss(.toggle))
            } else {
                surface.settingsRequest = SettingsTabRequest(tab: .general, focus: .microphonePriority,
                    id: (surface.settingsRequest?.id ?? 0) + 1)
                surface.send(.openSettings(.general))
            }
        }
    }

    private var isMicrophoneSettingsOpen: Bool {
        surface.drawer == .settings(.general) && surface.settingsRequest?.focus == .microphonePriority
    }

    /// Tests only: mount with the notch History panel already open.
    func presentingHistoryForTesting() -> BarView {
        presenting(.history(.collapsed))
    }

    /// Tests and shots only: mount with `drawer` already open (History at a detent, or Settings at a tab).
    func presenting(_ drawer: NotchDrawer) -> BarView {
        var copy = self
        let model = injectedSurface ?? NotchSurfaceModel()
        switch drawer {
        case let .history(detent):
            model.send(.openHistory)
            model.send(.setHistoryDetent(detent))
        case let .settings(tab):
            model.send(.openSettings(tab))
        }
        if injectedSurface == nil { copy._ownSurface = State(initialValue: model) }
        copy._historyRowsExtent = State(initialValue: CGFloat(Self.rows(for: drawer, entries: state.recentTranscriptionEntries.count)))
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
        copy.forcedHistoryRows = rows
        copy._historyRowsExtent = State(initialValue: CGFloat(rows))
        return copy
    }

    static func rows(for drawer: NotchDrawer, entries: Int) -> Int {
        switch drawer {
        case .settings: NotchSettingsDrawerPresentation.rows
        case let .history(detent): detent.rows(entryCount: entries)
        }
    }

    /// VoiceOver's adjust on the extend handle: one row at a time, instantly.
    private func adjustHistoryRows(by delta: Int) {
        guard delta != 0 else { return }
        let detent: NotchHistoryDetent = delta > 0 ? .expanded : .collapsed
        guard surface.drawer?.isHistory == true, surface.historyDetent != detent else { return }
        surface.send(.setHistoryDetent(detent))
        historyRowsFlight = nil
        historyRowsExtent = CGFloat(historyRows) // an assistive step, like a keyboard action, never animates
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
    private func historyPanelContent(listHeight fixedListHeight: CGFloat? = nil) -> some View {
        NotchHistoryPanel(
            entries: state.recentTranscriptionEntries,
            activeRetranscriptionPath: state.activeHistoryRetranscriptionPath,
            palette: notchPalette,
            onCopy: { state.copyTranscript($0.text) },
            onPaste: { entry in
                guard !drawerBodyDragJustHappened else { return }
                surface.send(.dismiss(.action))
                state.repasteTranscript(entry.text, source: "bar_history")
            },
            onRetranscribe: { commandRouter.handleRetranscribeHistoryEntry(recordingPath: $0) },
            onOpen: { entry in
                guard !drawerBodyDragJustHappened else { return }
                surface.send(.dismiss(.action))
                if let path = entry.recordingPath, let onOpenHistoryRecording {
                    onOpenHistoryRecording(path)
                } else {
                    onOpenHistory()
                }
            },
            retranscriptionAvailability: { state.historyRetranscriptionAvailability },
            listHeight: fixedListHeight ?? min(
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
