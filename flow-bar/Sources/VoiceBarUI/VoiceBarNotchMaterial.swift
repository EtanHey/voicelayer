import SwiftUI

public enum VoiceBarNotchGlassTopology: Equatable {
    case directContinuousSurface
}

public enum VoiceBarNotchMaterialStrategy: Equatable {
    case nativeGlass
    case visualEffectMaterial
    case opaque

    public static func resolve(
        nativeGlassAvailable: Bool,
        visualEffectAvailable: Bool
    ) -> VoiceBarNotchMaterialStrategy {
        if nativeGlassAvailable {
            .nativeGlass
        } else if visualEffectAvailable {
            .visualEffectMaterial
        } else {
            .opaque
        }
    }
}

public struct VoiceBarNotchMaterialDescriptor: Equatable {
    public let topology: VoiceBarNotchGlassTopology
    public let surfaceCount: Int
    public let insetFrameCount: Int
    public let usesFilledBackdropMaterial: Bool
    public let hasOuterTopAndBottomEdgeTreatment: Bool
    public let usesTransparentBorderOnlyShell: Bool

    public static func resolve(
        for state: VoiceBarNotchVisualState
    ) -> VoiceBarNotchMaterialDescriptor {
        switch state {
        case .idle:
            continuous(surfaceCount: 0)
        case .hoverLauncher, .recording, .compactStatus:
            continuous(surfaceCount: 1)
        case .teleprompter:
            continuous(surfaceCount: VoiceBarNotchContract.material.lowerSurfaceLayerCount)
        }
    }

    private static func continuous(surfaceCount: Int) -> VoiceBarNotchMaterialDescriptor {
        VoiceBarNotchMaterialDescriptor(
            topology: .directContinuousSurface,
            surfaceCount: surfaceCount,
            insetFrameCount: VoiceBarNotchContract.material.teleprompterInsetFrameCount,
            usesFilledBackdropMaterial: surfaceCount > 0,
            hasOuterTopAndBottomEdgeTreatment: VoiceBarNotchContract.material.compactWingsHaveOuterEdgeTreatment,
            usesTransparentBorderOnlyShell: false
        )
    }
}

public struct VoiceBarNotchGlassRecipe: Equatable {
    public let tint: VoiceBarRGBA
    public let nativeOverlay: VoiceBarRGBA?
    public let fallbackOverlay: VoiceBarRGBA

    public static func resolve(for _: VoiceBarNotchAppearance) -> Self {
        VoiceBarNotchGlassRecipe(
            tint: VoiceBarRGBA(red: 1, green: 1, blue: 1, alpha: 0.06),
            nativeOverlay: nil,
            fallbackOverlay: VoiceBarRGBA(red: 1, green: 1, blue: 1, alpha: 0.06)
        )
    }
}

/// Keeps one native-glass ownership boundary stable while the notch geometry
/// changes between compact wing subpaths and the connected teleprompter body.
public struct VoiceBarGlassContainer<Content: View>: View {
    private let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: 0) {
                content
            }
        } else {
            content
        }
    }
}

/// Shared filled material primitive for the persistent notch surface. It
/// deliberately never wraps the black hardware core.
public struct VoiceBarGlassMaterial<SurfaceShape: Shape>: ViewModifier {
    public let shape: SurfaceShape
    public let appearance: VoiceBarNotchAppearance
    public let forceOpaqueFallback: Bool

    public init(
        shape: SurfaceShape,
        appearance: VoiceBarNotchAppearance = .dark,
        forceOpaqueFallback: Bool = false
    ) {
        self.shape = shape
        self.appearance = appearance
        self.forceOpaqueFallback = forceOpaqueFallback
    }

    public func body(content: Content) -> some View {
        materialBody(content: content.clipShape(shape))
            .overlay {
                shape.stroke(.white.opacity(0.14), lineWidth: 0.7)
                    .allowsHitTesting(false)
            }
            .overlay {
                shape
                    .stroke(.black.opacity(0.10), lineWidth: 1)
                    .blur(radius: 0.35)
                    .offset(y: 0.5)
                    .mask(shape)
                    .allowsHitTesting(false)
            }
    }

    @ViewBuilder
    private func materialBody(content: some View) -> some View {
        let recipe = VoiceBarNotchGlassRecipe.resolve(for: appearance)
        if forceOpaqueFallback {
            content.background {
                shape.fill(
                    appearance == .dark
                        ? Color.black.opacity(0.88)
                        : Color.white.opacity(0.84)
                )
            }
        } else if #available(macOS 26.0, *) {
            // Native glass stays directly on the content-bearing view. A
            // separate filled overlay turns this into a tint and defeats its
            // adaptive frosting over black and bright backdrops.
            content
                .glassEffect(
                    .regular.tint(recipe.tint.color),
                    in: shape
                )
                .glassEffectTransition(.identity)
        } else {
            content
                .background(.ultraThinMaterial, in: shape)
                .background {
                    shape.fill(recipe.fallbackOverlay.color)
                        .allowsHitTesting(false)
                }
        }
    }
}
