import SwiftUI

public struct VoiceBarNotchViewDescriptor: Equatable {
    public let shellIdentity: String
    public let fixedCoreCount: Int
    public let reusableWingSlotCount: Int
    public let lowerSurfaceCount: Int
    public let clipsContentToVisibleSurfaces: Bool
    public let coreUsesMaterial: Bool
    public let usesSequencedSurfaceTransitions: Bool
    public let keepsHardwareCoreOutsideAnimatedSurfaces: Bool
    public let accessibilityLabel: String

    public static func resolve(
        presentation: VoiceBarNotchPresentation
    ) -> VoiceBarNotchViewDescriptor {
        VoiceBarNotchViewDescriptor(
            shellIdentity: "VoiceBarNotchShell",
            fixedCoreCount: presentation.visualState == .idle
                && presentation.virtualNotchIdleCoreHeight == nil ? 0 : 1,
            reusableWingSlotCount: 2,
            lowerSurfaceCount: presentation.geometry.lowerSurfaceHeight > 0 ? 1 : 0,
            clipsContentToVisibleSurfaces: true,
            coreUsesMaterial: VoiceBarNotchContract.material.coreUsesBackdropMaterial,
            usesSequencedSurfaceTransitions: true,
            keepsHardwareCoreOutsideAnimatedSurfaces: true,
            accessibilityLabel: presentation.accessibilityLabel
        )
    }
}

/// 2.3 lane U4: the History morph's input. While History is mounted the shell is drawn from `progress`
/// (animated by the caller with `NotchHistoryMorph.animation`) between the launcher and the open panel, instead
/// of springing between whole visual states.
public struct VoiceBarNotchHistoryMorphInput: Equatable {
    public var progress: CGFloat
    public let closed: VoiceBarNotchGeometry
    public let open: VoiceBarNotchGeometry
    public let closedBottomRadius: CGFloat
    public let closedTopRadius: CGFloat

    public init(
        progress: CGFloat,
        closed: VoiceBarNotchGeometry,
        open: VoiceBarNotchGeometry,
        closedBottomRadius: CGFloat = VoiceBarNotchContract.material.compactOuterCornerRadius(for: .hoverLauncher),
        closedTopRadius: CGFloat = 0
    ) {
        self.progress = progress
        self.closed = closed
        self.open = open
        self.closedBottomRadius = closedBottomRadius
        self.closedTopRadius = closedTopRadius
    }

    /// The open panel as the mock draws it: one shape, its top row as wide as its body.
    public var flushTop: VoiceBarNotchGeometry {
        VoiceBarNotchGeometry(
            coreWidth: open.coreWidth,
            topHeight: open.topHeight,
            leadingWingWidth: max(open.leadingWingWidth, open.bodyLeadingExtent),
            trailingWingWidth: max(open.trailingWingWidth, open.bodyTrailingExtent),
            bodyLeadingExtent: open.bodyLeadingExtent,
            bodyTrailingExtent: open.bodyTrailingExtent,
            lowerSurfaceHeight: open.lowerSurfaceHeight
        )
    }

    public func geometry(at p: CGFloat) -> VoiceBarNotchGeometry {
        NotchHistoryMorph.geometry(progress: p, closed: closed, open: flushTop)
    }
}

/// The History shell at an animated progress: geometry and radii are derived per frame, so the shape, the
/// radii and the rows (driven by the same value) can never drift apart.
public struct VoiceBarNotchHistoryMorphShape: Shape {
    public var morph: VoiceBarNotchHistoryMorphInput
    public let coreAnchorX: CGFloat?

    public init(morph: VoiceBarNotchHistoryMorphInput, coreAnchorX: CGFloat?) {
        self.morph = morph
        self.coreAnchorX = coreAnchorX
    }

    public var animatableData: CGFloat {
        get { morph.progress }
        set { morph.progress = newValue }
    }

    public func path(in rect: CGRect) -> Path {
        let p = morph.progress
        return VoiceBarNotchContinuousShape(
            geometry: morph.geometry(at: p),
            compactOuterCornerRadius: NotchHistoryMorph.bottomRadius(progress: p, closed: morph.closedBottomRadius),
            bodyShoulderCornerRadius: VoiceBarNotchContract.material.bodyShoulderCornerRadius(for: .history),
            coreAnchorX: coreAnchorX,
            topFlareRadius: NotchHistoryMorph.topRadius(progress: p, closed: morph.closedTopRadius)
        ).path(in: rect)
    }
}

public struct VoiceBarNotchView<LeadingContent: View, TrailingContent: View, LowerContent: View>: View {
    public let presentation: VoiceBarNotchPresentation
    public let appearance: VoiceBarNotchAppearance
    private let leadingContent: LeadingContent
    private let trailingContent: TrailingContent
    private let lowerContent: LowerContent
    private let onHoverChanged: (Bool) -> Void
    private let morphVariant: VoiceBarNotchMorphVariant
    private let canvasGeometry: VoiceBarNotchGeometry?
    private let historyMorph: VoiceBarNotchHistoryMorphInput?
    @State private var renderedGeometry: VoiceBarNotchGeometry
    @State private var renderedOuterCornerRadius: CGFloat
    @State private var renderedShoulderCornerRadius: CGFloat
    @State private var surfaceRevealProgress: CGFloat
    /// N1: a spring waiting for its invisible start (`morphEndpoints`) to commit. It runs from the next update's
    /// `onChange`, never from an escaping closure: writes from a closure that captured this view were dropped.
    @State private var pendingTabMorph: VoiceBarNotchPendingMorph?
    /// The visual state `renderedGeometry` was last moved to (2.3 lane U4: History hand-off).
    @State private var renderedVisualState: VoiceBarNotchVisualState?
    @Namespace private var morphNamespace
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion

    public init(
        presentation: VoiceBarNotchPresentation,
        appearance: VoiceBarNotchAppearance = .dark,
        morphVariant: VoiceBarNotchMorphVariant = .p1Matched,
        canvasGeometry: VoiceBarNotchGeometry? = nil,
        historyMorph: VoiceBarNotchHistoryMorphInput? = nil,
        onHoverChanged: @escaping (Bool) -> Void = { _ in },
        @ViewBuilder leadingContent: () -> LeadingContent,
        @ViewBuilder trailingContent: () -> TrailingContent,
        @ViewBuilder lowerContent: () -> LowerContent
    ) {
        self.presentation = presentation
        self.appearance = appearance
        self.morphVariant = morphVariant
        self.canvasGeometry = canvasGeometry
        self.historyMorph = historyMorph
        _renderedGeometry = State(initialValue: presentation.geometry)
        _renderedOuterCornerRadius = State(
            initialValue: VoiceBarNotchContract.material.compactOuterCornerRadius(for: presentation.visualState)
        )
        _renderedShoulderCornerRadius = State(
            initialValue: VoiceBarNotchContract.material.bodyShoulderCornerRadius(for: presentation.visualState)
        )
        _surfaceRevealProgress = State(
            initialValue: presentation.visualState == .idle ? 0 : 1
        )
        self.onHoverChanged = onHoverChanged
        self.leadingContent = leadingContent()
        self.trailingContent = trailingContent()
        self.lowerContent = lowerContent()
    }

    public var body: some View {
        ZStack(alignment: .topLeading) {
            VoiceBarGlassContainer(variant: morphVariant) {
                // Keep the zero-path idle source mounted so the first visible
                // frame can interpolate from the hardware core on both sides.
                // Opacity zero plus an empty idle mask still paints no glass.
                morphingNotchSurface
                    .opacity(presentation.visualState == .idle ? 0 : 1)
                    .allowsHitTesting(presentation.visualState != .idle)
                    .transition(.identity)
            }

            virtualIdleCore
            fixedHardwareCore
        }
        .frame(
            width: resolvedCanvasGeometry.totalWidth,
            height: resolvedCanvasGeometry.totalHeight,
            alignment: .topLeading
        )
        // Hardware idle draws no software pixels and keeps the physical
        // camera housing as its hover target. Flat-display idle paints that
        // same target as the virtual core. AppKit still gates both through
        // the exact rendered-shape hit region.
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
        .accessibilityLabel(presentation.accessibilityLabel)
        .onHover(perform: onHoverChanged)
        .onAppear {
            renderedGeometry = presentation.geometry
            renderedOuterCornerRadius = compactOuterCornerRadius
            renderedShoulderCornerRadius = bodyShoulderCornerRadius
            surfaceRevealProgress = presentation.visualState == .idle ? 0 : 1
            renderedVisualState = presentation.visualState
        }
        .onChange(of: presentation.geometry) { _, presentedGeometry in
            // 2.3 lane U4: launcher <-> History is drawn from the History progress, which already moved the
            // shell; the state geometry follows unanimated so nothing springs a second time underneath it.
            let historyOwnsMorph = historyMorph != nil || renderedVisualState == .history
            let wasHistory = renderedVisualState
            renderedVisualState = presentation.visualState
            if historyOwnsMorph, Self.isHistoryPair(wasHistory, presentation.visualState) {
                var snap = Transaction()
                snap.disablesAnimations = true
                withTransaction(snap) {
                    renderedGeometry = presentedGeometry
                    renderedOuterCornerRadius = compactOuterCornerRadius
                    renderedShoulderCornerRadius = bodyShoulderCornerRadius
                    surfaceRevealProgress = 1
                }
                pendingTabMorph = nil
                return
            }
            let transition = VoiceBarNotchShellTransition.resolve(
                from: renderedGeometry,
                to: presentedGeometry,
                visualState: presentation.visualState
            )
            // N1: the spring runs between these; they differ from the presented geometry only in a bodiless
            // shell's invisible body extents (see `morphEndpoints`).
            let endpoints = VoiceBarNotchShellTransition.morphEndpoints(from: renderedGeometry, to: presentedGeometry)
            let nextGeometry = endpoints.end
            let outerRadius = compactOuterCornerRadius
            let shoulderRadius = bodyShoulderCornerRadius
            let animate = {
                // The radii and the reveal mask ride the same transaction as the geometry, so they share one spring.
                withAnimation(shellAnimation.delay(transition.delay)) {
                    renderedGeometry = nextGeometry
                    renderedOuterCornerRadius = outerRadius
                    renderedShoulderCornerRadius = shoulderRadius
                    surfaceRevealProgress = transition.revealProgress
                }
            }
            guard endpoints.start != renderedGeometry else {
                pendingTabMorph = nil
                return animate()
            }
            // N1: commit the invisible extent rewrite unanimated in this update; the spring starts from it in the
            // next one. Only a bodiless, already revealed shell takes this path, so the reveal mask is unaffected.
            var snap = Transaction()
            snap.disablesAnimations = true
            withTransaction(snap) { renderedGeometry = endpoints.start }
            pendingTabMorph = VoiceBarNotchPendingMorph(
                serial: (pendingTabMorph?.serial ?? 0) &+ 1, presented: presentedGeometry,
                start: endpoints.start, geometry: nextGeometry, delay: transition.delay
            )
        }
        .onChange(of: pendingTabMorph) { _, pending in
            // A newer geometry change in the same update has already taken over; never spring to a stale target
            // (formal/notch-motion/TabMorph.tla, Unguarded fails NoSlabSweep).
            guard let pending, pending.presented == presentation.geometry, pending.start == renderedGeometry
            else { return }
            withAnimation(shellAnimation.delay(pending.delay)) {
                renderedGeometry = pending.geometry
                renderedOuterCornerRadius = compactOuterCornerRadius
                renderedShoulderCornerRadius = bodyShoulderCornerRadius
            }
        }
        .onChange(of: compactOuterCornerRadius) { _, nextRadius in
            // The geometry change carries it.
            guard renderedGeometry.drawsIdentically(to: presentation.geometry) else { return }
            withAnimation(shellAnimation) {
                renderedOuterCornerRadius = nextRadius
            }
        }
    }

    // Keep the native wing hosts (and their tooltip tracking) mounted when pause
    // collapses the teleprompter. Geometry still animates on the shared shell.
    private var morphingNotchSurface: some View {
        notchSurface
            .matchedGeometryEffect(
                id: VoiceBarNotchMorphVariant.sharedShellID,
                in: morphNamespace,
                properties: .frame,
                anchor: .top
            )
    }

    private var resolvedCanvasGeometry: VoiceBarNotchGeometry {
        canvasGeometry ?? presentation.geometry
    }

    private var surfaceOffsetX: CGFloat {
        resolvedCanvasGeometry.coreOriginX - slotGeometry.coreOriginX
    }

    /// The geometry the slots are laid out in. While History is mounted its content sits at the OPEN panel's
    /// rects for the whole morph: the rows grow out of the notch by scale, they never reflow.
    private var slotGeometry: VoiceBarNotchGeometry {
        historyMorph?.open ?? renderedGeometry
    }
    // (`open` keeps the launcher's wing rects, so the controls and their hit targets never move.)

    static func isHistoryPair(_ from: VoiceBarNotchVisualState?, _ to: VoiceBarNotchVisualState) -> Bool {
        let pair: Set<VoiceBarNotchVisualState?> = [.hoverLauncher, .history]
        return from != to && pair.contains(from) && pair.contains(to)
    }

    private var shellAnimation: Animation {
        if accessibilityReduceMotion {
            return .easeOut(duration: 0.18)
        }
        let descriptor = morphDescriptor
        if descriptor.effectiveVariant == .p3SpringDelight {
            return .spring(
                response: descriptor.totalDuration,
                dampingFraction: descriptor.heroDampingFraction
            )
        }
        return .interpolatingSpring(
            mass: descriptor.mass,
            stiffness: descriptor.stiffness,
            damping: descriptor.damping
        )
    }

    private var morphDescriptor: VoiceBarNotchMorphDescriptor {
        if #available(macOS 26.0, *) {
            morphVariant.descriptor(
                nativeGlassAvailable: true,
                reducedMotion: accessibilityReduceMotion
            )
        } else {
            morphVariant.descriptor(
                nativeGlassAvailable: false,
                reducedMotion: accessibilityReduceMotion
            )
        }
    }

    private func surfaceTransition(delay: TimeInterval) -> AnyTransition {
        let insertionAnimation = Animation.easeOut(
            duration: accessibilityReduceMotion ? 0.18 : 0.12
        )
        .delay(delay)
        let removalAnimation = Animation.easeOut(
            duration: VoiceBarNotchContract.motion.contentExitDuration
        )

        return .asymmetric(
            insertion: .opacity.animation(insertionAnimation),
            removal: .opacity.animation(removalAnimation)
        )
    }

    private var layout: VoiceBarNotchShapeLayout {
        VoiceBarNotchShapeLayout(geometry: slotGeometry)
    }

    @ViewBuilder
    private var virtualIdleCore: some View {
        if presentation.visualState == .idle,
           presentation.virtualNotchIdleCoreHeight != nil {
            VoiceBarNotchHardwareCoreShape(
                lowerCornerRadius: VoiceBarNotchContract.material.hardwareCoreLowerCornerRadius
            )
            .fill(.black)
            .frame(
                width: resolvedCanvasGeometry.coreWidth,
                height: resolvedCanvasGeometry.topHeight
            )
            .position(
                x: resolvedCanvasGeometry.coreOriginX + resolvedCanvasGeometry.coreWidth / 2,
                y: resolvedCanvasGeometry.topHeight / 2
            )
            .accessibilityHidden(true)
            .transaction { transaction in
                transaction.animation = nil
            }
            .zIndex(10)
        }
    }

    @ViewBuilder
    private var fixedHardwareCore: some View {
        if presentation.visualState != .idle {
            VoiceBarNotchHardwareCoreShape(
                lowerCornerRadius: VoiceBarNotchContract.material.hardwareCoreLowerCornerRadius
            )
            .fill(.black)
            .frame(
                width: resolvedCanvasGeometry.coreWidth,
                height: resolvedCanvasGeometry.topHeight
            )
            .position(
                x: resolvedCanvasGeometry.coreOriginX + resolvedCanvasGeometry.coreWidth / 2,
                y: resolvedCanvasGeometry.topHeight / 2
            )
            .accessibilityHidden(true)
            .transaction { transaction in
                transaction.animation = nil
            }
            .zIndex(10)
        }
    }

    @ViewBuilder
    private var notchSurface: some View {
        if let historyMorph {
            notchSurface(shape: VoiceBarNotchHistoryMorphShape(
                morph: historyMorph, coreAnchorX: resolvedCanvasGeometry.coreOriginX
            ))
        } else {
            notchSurface(shape: VoiceBarNotchContinuousShape(
                geometry: renderedGeometry,
                compactOuterCornerRadius: renderedOuterCornerRadius,
                bodyShoulderCornerRadius: renderedShoulderCornerRadius,
                coreAnchorX: resolvedCanvasGeometry.coreOriginX
            ))
        }
    }

    private func notchSurface(shape: some Shape) -> some View {
        ZStack(alignment: .topLeading) {
            notchSlots
                .frame(
                    width: slotGeometry.totalWidth,
                    height: slotGeometry.totalHeight,
                    alignment: .topLeading
                )
                .offset(x: surfaceOffsetX)
        }
        .frame(
            width: resolvedCanvasGeometry.totalWidth,
            height: resolvedCanvasGeometry.totalHeight,
            alignment: .topLeading
        )
        .modifier(
            VoiceBarGlassMaterial(
                shape: shape,
                appearance: appearance,
                morphVariant: morphVariant
            )
        )
        .overlay {
            VoiceBarNotchMorphDelightEdge(
                shape: shape,
                trigger: presentation.visualState,
                descriptor: morphDescriptor,
                reducedMotion: accessibilityReduceMotion
            )
            .allowsHitTesting(false)
        }
        .mask {
            VoiceBarNotchCoreAnchoredRevealMask(
                progress: surfaceRevealProgress,
                coreRect: CGRect(
                    x: resolvedCanvasGeometry.coreOriginX,
                    y: 0,
                    width: resolvedCanvasGeometry.coreWidth,
                    height: resolvedCanvasGeometry.topHeight
                )
            )
        }
        .contentShape(shape)
    }

    private var compactOuterCornerRadius: CGFloat {
        VoiceBarNotchContract.material.compactOuterCornerRadius(
            for: presentation.visualState
        )
    }

    private var bodyShoulderCornerRadius: CGFloat {
        VoiceBarNotchContract.material.bodyShoulderCornerRadius(
            for: presentation.visualState
        )
    }

    private var notchSlots: some View {
        ZStack(alignment: .topLeading) {
            let leadingWing = layout.leadingWingRect
            if leadingWing.width > 0 {
                wingSlot(leadingContent, side: .leading)
                    .frame(width: leadingWing.width, height: leadingWing.height)
                    .position(x: leadingWing.midX, y: leadingWing.midY)
            }

            let trailingWing = layout.trailingWingRect
            if trailingWing.width > 0 {
                wingSlot(trailingContent, side: .trailing)
                    .frame(width: trailingWing.width, height: trailingWing.height)
                    .position(x: trailingWing.midX, y: trailingWing.midY)
            }

            if historyMorph != nil, !layout.bodyRect.isEmpty {
                // Morph B: the rows ride the History progress themselves (`NotchHistoryRowsMorph`); no
                // opacity transition of their own.
                lowerContent
                    .frame(width: layout.bodyRect.width, height: layout.bodyRect.height)
                    .position(x: layout.bodyRect.midX, y: layout.bodyRect.midY)
            } else if !layout.bodyRect.isEmpty {
                lowerContent
                    .transition(
                        surfaceTransition(
                            delay: VoiceBarNotchContract.motion.panelDelay * 2
                        )
                    )
                    .frame(
                        width: layout.bodyRect.width,
                        height: layout.bodyRect.height
                    )
                    .clipped()
                    .position(
                        x: layout.bodyRect.midX,
                        y: layout.bodyRect.midY
                    )
            }
        }
    }

    private func wingSlot(
        _ content: some View,
        side: VoiceBarNotchSide
    ) -> some View {
        let slot = VoiceBarNotchContract.material.wingContentLayout(
            for: side,
            state: presentation.visualState,
            visibleCoreOcclusionInset: presentation.visibleCoreOcclusionInset
        )
        return content
            .padding(contentInsets(for: slot))
            .frame(
                maxWidth: .infinity,
                maxHeight: .infinity,
                alignment: contentAlignment(for: slot)
            )
            .clipped()
    }

    private func contentInsets(for slot: VoiceBarNotchWingContentLayout) -> EdgeInsets {
        switch slot.side {
        case .leading:
            EdgeInsets(
                top: 0,
                leading: slot.outerInset,
                bottom: 0,
                trailing: slot.coreInset
            )
        case .trailing:
            EdgeInsets(
                top: 0,
                leading: slot.coreInset,
                bottom: 0,
                trailing: slot.outerInset
            )
        }
    }

    private func contentAlignment(for slot: VoiceBarNotchWingContentLayout) -> Alignment {
        switch slot.alignment {
        case .center:
            .center
        case .screenLeading:
            .leading
        case .core:
            slot.side == .leading ? .trailing : .leading
        }
    }
}

struct VoiceBarNotchPendingMorph: Equatable {
    let serial: Int
    /// The presented geometry this spring was made for, and the snapped geometry it springs from.
    let presented: VoiceBarNotchGeometry
    let start: VoiceBarNotchGeometry
    let geometry: VoiceBarNotchGeometry
    let delay: TimeInterval
}

enum VoiceBarNotchCoreAnchoredRevealLayout {
    static func rect(
        progress: CGFloat,
        in canvas: CGRect,
        coreRect: CGRect
    ) -> CGRect {
        let fraction = min(1, max(0, progress))
        let leading = coreRect.minX - (coreRect.minX - canvas.minX) * fraction
        let trailing = coreRect.maxX + (canvas.maxX - coreRect.maxX) * fraction
        let bottom = coreRect.maxY + (canvas.maxY - coreRect.maxY) * fraction
        return CGRect(
            x: leading,
            y: canvas.minY,
            width: max(0, trailing - leading),
            height: max(0, bottom - canvas.minY)
        )
    }
}

private struct VoiceBarNotchCoreAnchoredRevealMask: Shape {
    var progress: CGFloat
    let coreRect: CGRect

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func path(in rect: CGRect) -> Path {
        Path(
            VoiceBarNotchCoreAnchoredRevealLayout.rect(
                progress: progress,
                in: rect,
                coreRect: coreRect
            )
        )
    }
}

private struct VoiceBarNotchMorphDelightEdge<SurfaceShape: Shape>: View {
    let shape: SurfaceShape
    let trigger: VoiceBarNotchVisualState
    let descriptor: VoiceBarNotchMorphDescriptor
    let reducedMotion: Bool
    @State private var scale: CGFloat = 1

    var body: some View {
        shape
            .stroke(.white.opacity(descriptor.maximumMaterialScaleDelta > 0 ? 0.18 : 0), lineWidth: 0.8)
            .scaleEffect(scale, anchor: .top)
            .onChange(of: trigger) { _, _ in
                guard descriptor.maximumMaterialScaleDelta > 0, !reducedMotion else {
                    scale = 1
                    return
                }
                scale = 1 - descriptor.maximumMaterialScaleDelta
                withAnimation(
                    .spring(
                        response: descriptor.totalDuration,
                        dampingFraction: descriptor.heroDampingFraction
                    )
                    .delay(descriptor.childStagger)
                ) {
                    scale = 1
                }
            }
    }
}
