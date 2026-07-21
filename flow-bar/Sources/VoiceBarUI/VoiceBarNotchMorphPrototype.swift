import CoreGraphics
import Foundation
import Observation

public enum VoiceBarNotchMorphVariant: String, CaseIterable, Equatable, Sendable {
    case p1Matched = "p1-matched"
    case p2NativeGlass = "p2-native-glass"
    case p3SpringDelight = "p3-spring-delight"

    public static let environmentVariable = "VOICEBAR_NOTCH_MORPH_VARIANT"
    public static let sharedShellID = "VoiceBarNotchMorphShell"
    public static let sharedGlassID = "VoiceBarNotchMorphGlass"

    public var menuTitle: String {
        switch self {
        case .p1Matched:
            "P1 — Matched Shell"
        case .p2NativeGlass:
            "P2 — Native Glass"
        case .p3SpringDelight:
            "P3 — Spring Delight"
        }
    }

    public static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        persistedRawValue: String?
    ) -> Self {
        if let explicit = environment[environmentVariable] {
            return Self(rawValue: explicit) ?? .p1Matched
        }
        return persistedRawValue.flatMap(Self.init(rawValue:)) ?? .p1Matched
    }

    public func descriptor(
        nativeGlassAvailable: Bool,
        reducedMotion: Bool
    ) -> VoiceBarNotchMorphDescriptor {
        let effectiveVariant: Self = self == .p2NativeGlass && !nativeGlassAvailable
            ? .p1Matched
            : self
        let usesDelight = effectiveVariant == .p3SpringDelight && !reducedMotion
        return VoiceBarNotchMorphDescriptor(
            selectedVariant: self,
            effectiveVariant: effectiveVariant,
            usesMatchedGeometry: true,
            usesNativeGlassContainer: effectiveVariant == .p2NativeGlass,
            usesGlassEffectID: effectiveVariant == .p2NativeGlass,
            usesSwiftUIGlassMaterial: false,
            transformsContent: false,
            blursContent: false,
            fixedCoreTranslation: .zero,
            mass: VoiceBarNotchContract.motion.mass,
            stiffness: VoiceBarNotchContract.motion.stiffness,
            damping: VoiceBarNotchContract.motion.damping,
            heroDampingFraction: usesDelight ? 0.75 : 0.82,
            nativeGlassSpacing: effectiveVariant == .p2NativeGlass ? 12 : 0,
            maximumMaterialScaleDelta: usesDelight ? 0.025 : 0,
            maximumOvershoot: usesDelight ? 4 : 0,
            childStagger: usesDelight ? 0.05 : VoiceBarNotchContract.motion.panelDelay,
            totalDuration: usesDelight ? 0.32 : 0.28
        )
    }
}

public struct VoiceBarNotchMorphDescriptor: Equatable, Sendable {
    public let selectedVariant: VoiceBarNotchMorphVariant
    public let effectiveVariant: VoiceBarNotchMorphVariant
    public let usesMatchedGeometry: Bool
    public let usesNativeGlassContainer: Bool
    public let usesGlassEffectID: Bool
    public let usesSwiftUIGlassMaterial: Bool
    public let transformsContent: Bool
    public let blursContent: Bool
    public let fixedCoreTranslation: CGPoint
    public let mass: Double
    public let stiffness: Double
    public let damping: Double
    public let heroDampingFraction: Double
    public let nativeGlassSpacing: CGFloat
    public let maximumMaterialScaleDelta: CGFloat
    public let maximumOvershoot: CGFloat
    public let childStagger: TimeInterval
    public let totalDuration: TimeInterval
}

public struct VoiceBarNotchMorphCanvasLayout: Equatable, Sendable {
    public let canvasGeometry: VoiceBarNotchGeometry
    public let contentOffsetX: CGFloat

    public static func resolve(
        for presentation: VoiceBarNotchPresentation
    ) -> VoiceBarNotchMorphCanvasLayout {
        guard presentation.visualState != .idle else {
            return VoiceBarNotchMorphCanvasLayout(
                canvasGeometry: presentation.geometry,
                contentOffsetX: 0
            )
        }
        let teleprompterGeometry = VoiceBarNotchContract.geometry(
            for: .teleprompter,
            coreWidth: presentation.geometry.coreWidth,
            visibleCoreOcclusionInset: presentation.visibleCoreOcclusionInset
        )
        let maximumRecordingWingWidth = VoiceBarNotchContract.recordingWingWidthWithHoldControl
        let canvasGeometry = VoiceBarNotchGeometry(
            coreWidth: teleprompterGeometry.coreWidth,
            topHeight: teleprompterGeometry.topHeight,
            leadingWingWidth: max(
                teleprompterGeometry.leadingWingWidth,
                maximumRecordingWingWidth
            ),
            trailingWingWidth: max(
                teleprompterGeometry.trailingWingWidth,
                maximumRecordingWingWidth
            ),
            bodyLeadingExtent: max(
                teleprompterGeometry.bodyLeadingExtent,
                maximumRecordingWingWidth
            ),
            bodyTrailingExtent: max(
                teleprompterGeometry.bodyTrailingExtent,
                maximumRecordingWingWidth
            ),
            lowerSurfaceHeight: presentation.geometry.lowerSurfaceHeight
        )
        return VoiceBarNotchMorphCanvasLayout(
            canvasGeometry: canvasGeometry,
            contentOffsetX: canvasGeometry.coreOriginX - presentation.geometry.coreOriginX
        )
    }
}

@Observable
public final class VoiceBarNotchMorphSelection {
    public static let defaultsKey = "voicebar.notchMorphPrototype"

    public private(set) var variant: VoiceBarNotchMorphVariant
    @ObservationIgnored private let defaults: UserDefaults

    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        defaults: UserDefaults = .standard
    ) {
        self.defaults = defaults
        variant = VoiceBarNotchMorphVariant.resolve(
            environment: environment,
            persistedRawValue: defaults.string(forKey: Self.defaultsKey)
        )
    }

    public func select(_ variant: VoiceBarNotchMorphVariant) {
        guard self.variant != variant else { return }
        self.variant = variant
        defaults.set(variant.rawValue, forKey: Self.defaultsKey)
    }
}
