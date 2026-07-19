import AppKit
import SwiftUI

public enum VoiceBarNotchAppearance: Equatable {
    case light
    case dark

    public init(effectiveAppearance: NSAppearance) {
        self = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? .dark
            : .light
    }
}

public enum VoiceBarNotchGlyphForegroundRole: Equatable {
    case primaryLabel
    case stateAccent

    public static func resolve(
        isDestructive: Bool,
        isSelected: Bool
    ) -> Self {
        isDestructive || isSelected ? .stateAccent : .primaryLabel
    }
}

public struct VoiceBarNotchAppearanceTracker {
    public private(set) var appearance: VoiceBarNotchAppearance

    public init(initial: VoiceBarNotchAppearance) {
        appearance = initial
    }

    @discardableResult
    public mutating func receive(effectiveAppearance: NSAppearance) -> Bool {
        let next = VoiceBarNotchAppearance(effectiveAppearance: effectiveAppearance)
        guard next != appearance else { return false }
        appearance = next
        return true
    }
}

public struct VoiceBarRGB: Equatable {
    public let red: Double
    public let green: Double
    public let blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }
}

public struct VoiceBarRGBA: Equatable {
    public let red: Double
    public let green: Double
    public let blue: Double
    public let alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    public var color: Color {
        Color(red: red, green: green, blue: blue).opacity(alpha)
    }

    public func composited(over background: VoiceBarRGB) -> VoiceBarRGB {
        let clampedAlpha = min(1, max(0, alpha))
        return VoiceBarRGB(
            red: red * clampedAlpha + background.red * (1 - clampedAlpha),
            green: green * clampedAlpha + background.green * (1 - clampedAlpha),
            blue: blue * clampedAlpha + background.blue * (1 - clampedAlpha)
        )
    }
}

public struct VoiceBarNotchContrastPalette: Equatable {
    public let primary: VoiceBarRGBA
    public let secondary: VoiceBarRGBA
    public let tertiary: VoiceBarRGBA
    public let subtleTrack: VoiceBarRGBA
    public let destructiveForeground: VoiceBarRGBA
    public let surfaceTint: VoiceBarRGBA
    public let surfaceOverlay: VoiceBarRGBA

    public static func resolve(for appearance: VoiceBarNotchAppearance) -> Self {
        switch appearance {
        case .light:
            VoiceBarNotchContrastPalette(
                primary: VoiceBarRGBA(red: 0.06, green: 0.07, blue: 0.10, alpha: 0.96),
                secondary: VoiceBarRGBA(red: 0.06, green: 0.07, blue: 0.10, alpha: 0.82),
                tertiary: VoiceBarRGBA(red: 0.06, green: 0.07, blue: 0.10, alpha: 0.72),
                subtleTrack: VoiceBarRGBA(red: 0.06, green: 0.07, blue: 0.10, alpha: 0.20),
                destructiveForeground: VoiceBarRGBA(red: 1, green: 1, blue: 1, alpha: 1),
                surfaceTint: VoiceBarRGBA(red: 1, green: 1, blue: 1, alpha: 0.06),
                surfaceOverlay: VoiceBarRGBA(red: 1, green: 1, blue: 1, alpha: 0.035)
            )
        case .dark:
            VoiceBarNotchContrastPalette(
                primary: VoiceBarRGBA(red: 1, green: 1, blue: 1, alpha: 0.96),
                secondary: VoiceBarRGBA(red: 1, green: 1, blue: 1, alpha: 0.86),
                tertiary: VoiceBarRGBA(red: 1, green: 1, blue: 1, alpha: 0.72),
                subtleTrack: VoiceBarRGBA(red: 1, green: 1, blue: 1, alpha: 0.14),
                destructiveForeground: VoiceBarRGBA(red: 1, green: 1, blue: 1, alpha: 1),
                surfaceTint: VoiceBarRGBA(red: 0, green: 0, blue: 0, alpha: 0.22),
                surfaceOverlay: VoiceBarRGBA(red: 0, green: 0, blue: 0, alpha: 0.14)
            )
        }
    }

    public static func minimumTeleprompterOpacity(
        for appearance: VoiceBarNotchAppearance
    ) -> Double {
        appearance == .light ? 0.72 : 0.58
    }
}

public enum VoiceBarContrast {
    public static let minimumTextRatio = 4.5
    public static let minimumControlRatio = 3.0
    public static let minimumForegroundLuminanceDelta = 0.035

    public static func ratio(foreground: VoiceBarRGB, background: VoiceBarRGB) -> Double {
        let foregroundLuminance = relativeLuminance(foreground)
        let backgroundLuminance = relativeLuminance(background)
        let lighter = max(foregroundLuminance, backgroundLuminance)
        let darker = min(foregroundLuminance, backgroundLuminance)
        return (lighter + 0.05) / (darker + 0.05)
    }

    public static func passesPixelSample(
        foregroundPixels: [VoiceBarRGB],
        background: VoiceBarRGB,
        minimumRatio: Double
    ) -> Bool {
        guard !foregroundPixels.isEmpty else { return false }
        let readableCount = foregroundPixels.lazy.filter {
            ratio(foreground: $0, background: background) >= minimumRatio
        }.count
        return readableCount >= max(8, Int(ceil(Double(foregroundPixels.count) * 0.25)))
    }

    public static func isForegroundCandidate(
        _ pixel: VoiceBarRGB,
        against background: VoiceBarRGB,
        appearance: VoiceBarNotchAppearance
    ) -> Bool {
        let delta = relativeLuminance(pixel) - relativeLuminance(background)
        switch appearance {
        case .light:
            return delta <= -minimumForegroundLuminanceDelta
        case .dark:
            return delta >= minimumForegroundLuminanceDelta
        }
    }

    public static func relativeLuminance(_ color: VoiceBarRGB) -> Double {
        let red = linearComponent(color.red)
        let green = linearComponent(color.green)
        let blue = linearComponent(color.blue)
        return 0.2126 * red + 0.7152 * green + 0.0722 * blue
    }

    private static func linearComponent(_ component: Double) -> Double {
        let clamped = min(1, max(0, component))
        if clamped <= 0.04045 {
            return clamped / 12.92
        }
        return pow((clamped + 0.055) / 1.055, 2.4)
    }
}
