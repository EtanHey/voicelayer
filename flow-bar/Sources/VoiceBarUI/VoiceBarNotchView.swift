import SwiftUI

public struct VoiceBarNotchViewDescriptor: Equatable {
    public let shellIdentity: String
    public let fixedCoreCount: Int
    public let reusableWingSlotCount: Int
    public let coreEdgeVeilCount: Int
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
            coreEdgeVeilCount: presentation.visualState == .idle ? 0 : 2,
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
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion

    public init(
        presentation: VoiceBarNotchPresentation,
        appearance: VoiceBarNotchAppearance = .dark,
        onHoverChanged: @escaping (Bool) -> Void = { _ in },
        @ViewBuilder leadingContent: () -> LeadingContent,
        @ViewBuilder trailingContent: () -> TrailingContent,
        @ViewBuilder lowerContent: () -> LowerContent
    ) {
        self.presentation = presentation
        self.appearance = appearance
        self.onHoverChanged = onHoverChanged
        self.leadingContent = leadingContent()
        self.trailingContent = trailingContent()
        self.lowerContent = lowerContent()
    }

    public var body: some View {
        ZStack(alignment: .topLeading) {
            if presentation.visualState == .teleprompter {
                teleprompterSurfaceUnit
                    .transition(.identity)
            } else if presentation.visualState != .idle {
                compactSurface
                    .transition(.identity)
            }

            fixedHardwareCore
        }
        .frame(
            width: presentation.geometry.totalWidth,
            height: presentation.geometry.totalHeight,
            alignment: .topLeading
        )
        // The collapsed state draws no software pixels, but the physical
        // camera housing remains the intentional hover target that summons
        // VoiceBar again. AppKit still gates this rectangle through the exact
        // rendered-shape hit region for every expanded state.
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
        .accessibilityLabel(presentation.accessibilityLabel)
        .onHover(perform: onHoverChanged)
    }

    private func surfaceTransition(delay: TimeInterval) -> AnyTransition {
        let insertionAnimation: Animation = if accessibilityReduceMotion {
            .easeOut(duration: 0.18).delay(delay)
        } else {
            .interpolatingSpring(
                mass: VoiceBarNotchContract.motion.mass,
                stiffness: VoiceBarNotchContract.motion.stiffness,
                damping: VoiceBarNotchContract.motion.damping
            )
            .delay(delay)
        }
        let removalAnimation = Animation.easeOut(
            duration: VoiceBarNotchContract.motion.contentExitDuration
        )
        let insertion: AnyTransition = if accessibilityReduceMotion {
            .opacity.animation(insertionAnimation)
        } else {
            .scale(scale: 0.97, anchor: .top)
                .combined(with: .opacity)
                .animation(insertionAnimation)
        }

        return .asymmetric(
            insertion: insertion,
            removal: .opacity.animation(removalAnimation)
        )
    }

    private var layout: VoiceBarNotchShapeLayout {
        VoiceBarNotchShapeLayout(geometry: presentation.geometry)
    }

    @ViewBuilder
    private var fixedHardwareCore: some View {
        if presentation.visualState != .idle {
            VoiceBarNotchHardwareCoreShape(
                lowerCornerRadius: VoiceBarNotchContract.material.hardwareCoreLowerCornerRadius
            )
            .fill(.black)
            .frame(width: layout.coreRect.width, height: layout.coreRect.height)
            .position(x: layout.coreRect.midX, y: layout.coreRect.midY)
            .accessibilityHidden(true)
            .transaction { transaction in
                transaction.animation = nil
            }
            .zIndex(10)
        }
    }

    private var compactSurface: some View {
        ZStack(alignment: .topLeading) {
            compactWings
            coreEdgeVeils
        }
    }

    private var compactWings: some View {
        VoiceBarGlassContainer {
            ZStack(alignment: .topLeading) {
                if layout.leadingWingRect.width > 0 {
                    VoiceBarGlassWing(
                        side: .leading,
                        outerCornerRadius: compactOuterCornerRadius,
                        appearance: appearance
                    ) {
                        wingSlot(leadingContent, side: .leading)
                    }
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
                    VoiceBarGlassWing(
                        side: .trailing,
                        outerCornerRadius: compactOuterCornerRadius,
                        appearance: appearance
                    ) {
                        wingSlot(trailingContent, side: .trailing)
                    }
                    .frame(
                        width: layout.trailingWingRect.width,
                        height: layout.trailingWingRect.height
                    )
                    .position(
                        x: layout.trailingWingRect.midX,
                        y: layout.trailingWingRect.midY
                    )
                }
            }
            .frame(
                width: presentation.geometry.totalWidth,
                height: presentation.geometry.topHeight,
                alignment: .topLeading
            )
        }
    }

    private var teleprompterSurface: some View {
        let shape = VoiceBarNotchContinuousShape(
            geometry: presentation.geometry
        )
        return Color.clear
            .frame(
                width: presentation.geometry.totalWidth,
                height: presentation.geometry.totalHeight
            )
            .modifier(
                VoiceBarGlassMaterial(
                    shape: shape,
                    appearance: appearance
                )
            )
            .contentShape(shape)
            .overlay(alignment: .topLeading) {
                coreEdgeVeils
            }
    }

    private var coreEdgeVeils: some View {
        let leadingPlacement = VoiceBarNotchCoreSeamPlacement.resolve(
            for: .leading,
            coreRect: layout.coreRect,
            visibleCoreOcclusionInset: presentation.visibleCoreOcclusionInset
        )
        let trailingPlacement = VoiceBarNotchCoreSeamPlacement.resolve(
            for: .trailing,
            coreRect: layout.coreRect,
            visibleCoreOcclusionInset: presentation.visibleCoreOcclusionInset
        )
        return ZStack(alignment: .topLeading) {
            VoiceBarBlackToGlassFade(wing: .leading)
                .frame(
                    width: leadingPlacement.frame.width,
                    height: leadingPlacement.frame.height
                )
                .position(
                    x: leadingPlacement.frame.midX,
                    y: leadingPlacement.frame.midY
                )
            VoiceBarBlackToGlassFade(wing: .trailing)
                .frame(
                    width: trailingPlacement.frame.width,
                    height: trailingPlacement.frame.height
                )
                .position(
                    x: trailingPlacement.frame.midX,
                    y: trailingPlacement.frame.midY
                )
        }
        .frame(
            width: presentation.geometry.totalWidth,
            height: presentation.geometry.topHeight,
            alignment: .topLeading
        )
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var compactOuterCornerRadius: CGFloat {
        VoiceBarNotchContract.material.compactOuterCornerRadius(
            for: presentation.visualState
        )
    }

    private var teleprompterSurfaceUnit: some View {
        ZStack(alignment: .topLeading) {
            teleprompterSurface
            teleprompterSlots
        }
    }

    private var teleprompterSlots: some View {
        ZStack(alignment: .topLeading) {
            wingSlot(leadingContent, side: .leading)
                .frame(
                    width: layout.leadingWingRect.width,
                    height: layout.leadingWingRect.height
                )
                .position(
                    x: layout.leadingWingRect.midX,
                    y: layout.leadingWingRect.midY
                )

            wingSlot(trailingContent, side: .trailing)
                .frame(
                    width: layout.trailingWingRect.width,
                    height: layout.trailingWingRect.height
                )
                .position(
                    x: layout.trailingWingRect.midX,
                    y: layout.trailingWingRect.midY
                )

            lowerContent
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
