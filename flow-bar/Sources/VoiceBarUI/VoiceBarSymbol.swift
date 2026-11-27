import AppKit
import SwiftUI

/// T19b (L68): VoiceBar's own symbols. They are SF Symbols templates compiled from
/// `flow-bar/Symbols/VoiceBarSymbols.xcassets` into the app's `Contents/Resources/Assets.car` by `build-app.sh`, so
/// they size with the font, take the foreground style and animate like system symbols.
///
/// A name with the `voicebar.` prefix is VoiceBar's; any other name is a system symbol. When the compiled catalog is
/// absent (`swift test`, a dev binary not built by `build-app.sh`) a custom name falls back to the system symbol it
/// replaces, so no control ever draws empty.
public enum VoiceBarSymbol {
    /// The History glyph, concept A "take loop": History's loop around the take (three waveform bars).
    public static let history = "voicebar.history.take"

    static let fallbacks: [String: String] = [history: "clock.arrow.circlepath"]

    /// The bundle whose `Assets.car` holds the custom symbols. Tests point it at a catalog they compiled.
    nonisolated(unsafe) static var bundle: Bundle = .main {
        didSet { resolved.removeAll() }
    }

    nonisolated(unsafe) private static var resolved: [String: Bool] = [:]

    static func isCustom(_ name: String) -> Bool { name.hasPrefix("voicebar.") }

    /// Whether the custom symbol `name` ships in `bundle` (looked up once per name).
    static func isAvailable(_ name: String) -> Bool {
        if let known = resolved[name] { return known }
        let found = NSImage(symbolName: name, bundle: bundle, variableValue: 0) != nil
        resolved[name] = found
        return found
    }

    /// The system symbol drawn for `name`: itself, or a missing custom symbol's fallback.
    public static func systemName(for name: String) -> String? {
        guard isCustom(name) else { return name }
        return isAvailable(name) ? nil : (fallbacks[name] ?? "questionmark")
    }

    /// The image for `name`, a VoiceBar or system symbol.
    public static func image(_ name: String) -> Image {
        if let system = systemName(for: name) { return Image(systemName: system) }
        return Image(name, bundle: bundle)
    }

    /// The AppKit image for `name` (menus, status items).
    public static func nsImage(_ name: String, accessibilityDescription: String?) -> NSImage? {
        if let system = systemName(for: name) {
            return NSImage(systemSymbolName: system, accessibilityDescription: accessibilityDescription)
        }
        let image = NSImage(symbolName: name, bundle: bundle, variableValue: 0)
        image?.accessibilityDescription = accessibilityDescription
        return image
    }
}

/// T19 (L67/L69): how a symbol swaps. A state swap (Copy → ✓, Mute ⇄ Unmute, a setup step turning done) uses the
/// system's replace effect; with Reduce Motion on it only cross-fades, because replace scales and offsets the glyph
/// (the card-8 rule: fade only). Every symbol swap in VoiceBar goes through here (VoiceBarSymbolMotionSourceTests).
public enum VoiceBarSymbolMotion {
    public static func swap(reduceMotion: Bool) -> ContentTransition {
        reduceMotion ? .opacity : .symbolEffect(.replace)
    }

    /// The Copy → ✓ swap: the tick drops in and the copy glyph leaves upward, layer by layer.
    public static func copyConfirmation(reduceMotion: Bool) -> ContentTransition {
        reduceMotion ? .opacity : .symbolEffect(.replace.downUp.byLayer)
    }

    /// The animation that carries a click-driven swap (the state change itself is not animated).
    public static let swapAnimation: Animation = .snappy(duration: 0.2)
}
