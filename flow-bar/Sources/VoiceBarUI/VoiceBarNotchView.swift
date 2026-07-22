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
            fixedCoreCount: presentation.visualState == .idle ? 0 : 1,
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

public struct VoiceBarNotchView<LeadingContent: View, TrailingContent: View, LowerContent: View>: View {
    public let presentation: VoiceBarNotchPresentation
    public let appearance: VoiceBarNotchAppearance
    private let leadingContent: LeadingContent
    private let trailingContent: TrailingContent
    private let lowerContent: LowerContent
    private let onHoverChanged: (Bool) -> Void
    private let morphVariant: VoiceBarNotchMorphVariant
    private let canvasGeometry: VoiceBarNotchGeometry?
    @State private var renderedGeometry: VoiceBarNotchGeometry
    @State private var surfaceRevealProgress: CGFloat
    @Namespace private var morphNamespace
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion

    public init(
        presentation: VoiceBarNotchPresentation,
        appearance: VoiceBarNotchAppearance = .dark,
        morphVariant: VoiceBarNotchMorphVariant = .p1Matched,
        canvasGeometry: VoiceBarNotchGeometry? = nil,
        onHoverChanged: @escaping (Bool) -> Void = { _ in },
        @ViewBuilder leadingContent: () -> LeadingContent,
        @ViewBuilder trailingContent: () -> TrailingContent,
        @ViewBuilder lowerContent: () -> LowerContent
    ) {
        self.presentation = presentation
        self.appearance = appearance
        self.morphVariant = morphVariant
        self.canvasGeometry = canvasGeometry
        _renderedGeometry = State(initialValue: presentation.geometry)
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

            fixedHardwareCore
        }
        .frame(
            width: resolvedCanvasGeometry.totalWidth,
            height: resolvedCanvasGeometry.totalHeight,
            alignment: .topLeading
        )
        // Idle draws no software pixels. Hardware keeps the physical camera
        // housing as its hover target; flat displays keep a separate clear
        // AppKit tracking band resolved by VoiceBarPanelLayout.
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
        .accessibilityLabel(presentation.accessibilityLabel)
        .onHover(perform: onHoverChanged)
        .onAppear {
            renderedGeometry = presentation.geometry
            surfaceRevealProgress = presentation.visualState == .idle ? 0 : 1
        }
        .onChange(of: presentation.geometry) { _, nextGeometry in
            let closingGeometryDelay = renderedGeometry.lowerSurfaceHeight > 0
                && nextGeometry.lowerSurfaceHeight == 0
                ? VoiceBarNotchContract.motion.contentExitDuration
                : 0
            withAnimation(shellAnimation.delay(closingGeometryDelay)) {
                renderedGeometry = nextGeometry
            }
        }
        .task(id: presentation.visualState) {
            guard presentation.visualState != .idle else {
                withAnimation(shellAnimation) {
                    surfaceRevealProgress = 0
                }
                return
            }

            // Visible-to-visible changes keep the shared surface mounted and
            // interpolate its geometry directly. Only an actually collapsed
            // surface needs to reveal outward from the fixed hardware core.
            guard surfaceRevealProgress == 0 else { return }
            await Task.yield()
            guard !Task.isCancelled else { return }
            withAnimation(shellAnimation) {
                surfaceRevealProgress = 1
            }
        }
    }

    @ViewBuilder
    private var morphingNotchSurface: some View {
        if presentation.visualState == .teleprompter {
            notchSurface
                .matchedGeometryEffect(
                    id: VoiceBarNotchMorphVariant.sharedShellID,
                    in: morphNamespace,
                    properties: .frame,
                    anchor: .top
                )
        } else {
            notchSurface
                .matchedGeometryEffect(
                    id: VoiceBarNotchMorphVariant.sharedShellID,
                    in: morphNamespace,
                    properties: .frame,
                    anchor: .top
                )
        }
    }

    private var resolvedCanvasGeometry: VoiceBarNotchGeometry {
        canvasGeometry ?? presentation.geometry
    }

    private var surfaceOffsetX: CGFloat {
        resolvedCanvasGeometry.coreOriginX - renderedGeometry.coreOriginX
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
        VoiceBarNotchShapeLayout(geometry: renderedGeometry)
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

    private var notchSurface: some View {
        let shape = VoiceBarNotchContinuousShape(
            geometry: renderedGeometry,
            compactOuterCornerRadius: compactOuterCornerRadius,
            coreAnchorX: resolvedCanvasGeometry.coreOriginX
        )
        return ZStack(alignment: .topLeading) {
            notchSlots
                .frame(
                    width: renderedGeometry.totalWidth,
                    height: renderedGeometry.totalHeight,
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

    private var notchSlots: some View {
        ZStack(alignment: .topLeading) {
            if layout.leadingWingRect.width > 0 {
                wingSlot(leadingContent, side: .leading)
                    .frame(
                        width: layout.leadingWingRect.width,
                        height: layout.leadingWingRect.height
                    )
                    .position(
                        x: layout.leadingWingRect.midX,
                        y: layout.leadingWingRect.midY
                    )
            }

            if layout.trailingWingRect.width > 0 {
                wingSlot(trailingContent, side: .trailing)
                    .frame(
                        width: layout.trailingWingRect.width,
                        height: layout.trailingWingRect.height
                    )
                    .position(
                        x: layout.trailingWingRect.midX,
                        y: layout.trailingWingRect.midY
                    )
            }

            if !layout.bodyRect.isEmpty {
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
