import SwiftUI

public enum VoiceBarNotchGlassTopology: Equatable {
    case compactSiblingContainer
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
            compact(surfaceCount: 0)
        case .hoverLauncher, .recording, .compactStatus:
            compact(surfaceCount: 2)
        case .teleprompter:
            VoiceBarNotchMaterialDescriptor(
                topology: .directContinuousSurface,
                surfaceCount: VoiceBarNotchContract.material.lowerSurfaceLayerCount,
                insetFrameCount: VoiceBarNotchContract.material.teleprompterInsetFrameCount,
                usesFilledBackdropMaterial: true,
                hasOuterTopAndBottomEdgeTreatment: true,
                usesTransparentBorderOnlyShell: false
            )
        }
    }

    private static func compact(surfaceCount: Int) -> VoiceBarNotchMaterialDescriptor {
        VoiceBarNotchMaterialDescriptor(
            topology: .compactSiblingContainer,
            surfaceCount: surfaceCount,
            insetFrameCount: 0,
            usesFilledBackdropMaterial: surfaceCount > 0,
            hasOuterTopAndBottomEdgeTreatment: VoiceBarNotchContract.material.compactWingsHaveOuterEdgeTreatment,
            usesTransparentBorderOnlyShell: false
        )
    }
}

public struct VoiceBarNotchCoreSeamDescriptor: Equatable {
    public let width: CGFloat
    public let opaqueEdge: VoiceBarNotchSide
    public let stops: [VoiceBarNotchCoreSeamStop]

    public static func resolve(
        for wing: VoiceBarNotchSide
    ) -> VoiceBarNotchCoreSeamDescriptor {
        let glassToCoreStops = [
            VoiceBarNotchCoreSeamStop(location: 0, opacity: 0),
            VoiceBarNotchCoreSeamStop(location: 0.34, opacity: 0.06),
            VoiceBarNotchCoreSeamStop(location: 0.70, opacity: 0.52),
            VoiceBarNotchCoreSeamStop(location: 1, opacity: 1),
        ]
        let stops = switch wing {
        case .leading:
            glassToCoreStops
        case .trailing:
            glassToCoreStops.reversed().map {
                VoiceBarNotchCoreSeamStop(
                    location: 1 - $0.location,
                    opacity: $0.opacity
                )
            }
        }
        return VoiceBarNotchCoreSeamDescriptor(
            width: VoiceBarNotchContract.material.blackToGlassFadeWidth,
            opaqueEdge: wing == .leading ? .trailing : .leading,
            stops: stops
        )
    }
}

public struct VoiceBarNotchCoreSeamStop: Equatable {
    public let location: CGFloat
    public let opacity: Double

    public init(location: CGFloat, opacity: Double) {
        self.location = location
        self.opacity = opacity
    }
}

/// Groups the two compact wing materials on macOS 26 so their native glass
/// samples as siblings. Older systems preserve the exact same geometry.
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

/// Shared filled material primitive for compact wings and the direct
/// teleprompter surface. It deliberately never wraps the black hardware core.
public struct VoiceBarGlassMaterial<SurfaceShape: Shape>: ViewModifier {
    public let shape: SurfaceShape
    public let forceOpaqueFallback: Bool

    public init(shape: SurfaceShape, forceOpaqueFallback: Bool = false) {
        self.shape = shape
        self.forceOpaqueFallback = forceOpaqueFallback
    }

    public func body(content: Content) -> some View {
        materialBody(content: content)
            .overlay {
                shape.stroke(.white.opacity(0.14), lineWidth: 0.7)
            }
            .overlay {
                shape
                    .stroke(.black.opacity(0.10), lineWidth: 1)
                    .blur(radius: 0.35)
                    .offset(y: 0.5)
                    .mask(shape)
            }
            .shadow(color: .black.opacity(0.24), radius: 12, y: 5)
    }

    @ViewBuilder
    private func materialBody(content: Content) -> some View {
        if forceOpaqueFallback {
            content.background(Color.black.opacity(0.88), in: shape)
        } else if #available(macOS 26.0, *) {
            content.glassEffect(
                .regular.tint(.white.opacity(0.06)),
                in: shape
            )
        } else {
            content
                .background(.ultraThinMaterial, in: shape)
                .overlay {
                    shape.fill(.white.opacity(0.055))
                }
        }
    }
}

public struct VoiceBarBlackToGlassFade: View {
    public let wing: VoiceBarNotchSide

    public init(wing: VoiceBarNotchSide) {
        self.wing = wing
    }

    public var body: some View {
        let descriptor = VoiceBarNotchCoreSeamDescriptor.resolve(for: wing)
        let stops = descriptor.stops.map {
            Gradient.Stop(
                color: .black.opacity($0.opacity),
                location: $0.location
            )
        }

        LinearGradient(stops: stops, startPoint: .leading, endPoint: .trailing)
            .frame(width: descriptor.width)
            .accessibilityHidden(true)
    }
}

public struct VoiceBarGlassWing<Content: View>: View {
    public let side: VoiceBarNotchSide
    public let outerCornerRadius: CGFloat
    private let content: Content

    public init(
        side: VoiceBarNotchSide,
        outerCornerRadius: CGFloat = 11,
        @ViewBuilder content: () -> Content
    ) {
        self.side = side
        self.outerCornerRadius = outerCornerRadius
        self.content = content()
    }

    public var body: some View {
        let shape = VoiceBarNotchWingShape(
            side: side,
            outerCornerRadius: outerCornerRadius
        )
        content
            .modifier(VoiceBarGlassMaterial(shape: shape))
            .overlay(alignment: seamAlignment) {
                VoiceBarBlackToGlassFade(wing: side)
                    .allowsHitTesting(false)
            }
            .clipShape(shape)
    }

    private var seamAlignment: Alignment {
        side == .leading ? .trailing : .leading
    }
}
