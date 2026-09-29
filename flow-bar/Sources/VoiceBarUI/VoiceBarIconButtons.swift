import AppKit
import SwiftUI

/// The action glyphs shared by every surface (UXP-3, UX pass #7).
public enum VoiceBarActionSymbol {
    public static let copy = "doc.on.doc"
    /// Paste types the text into the app you were using, so it shows text going in at a cursor. The old
    /// `doc.on.clipboard` was a near twin of Copy's `doc.on.doc` at 12 pt.
    public static let paste = "text.insert"
    public static let copied = "checkmark"
}

/// Copy's "✓" feedback as a pure state machine over an explicit clock (UXP-3, UX pass #5). Hosts own it, so a
/// notch row can stay revealed while its tick shows; `key` tells rows apart.
public struct CopyFeedback: Equatable {
    public static let duration: TimeInterval = 1.5

    private var copiedKey: String?
    private var copiedUntil: Date?
    /// The #200 pattern: a pointer click must not leave a focus ring behind; focus that arrives by keyboard or
    /// VoiceOver keeps it. Cleared when focus leaves.
    public private(set) var hidesFocusRing = false

    public init() {}

    public func isCopied(key: String = "", at now: Date) -> Bool {
        guard copiedKey == key, let copiedUntil else { return false }
        return now < copiedUntil
    }

    /// A copy that never reached the pasteboard claims nothing (#161 review).
    public mutating func copied(key: String = "", succeeded: Bool, byPointer: Bool, at now: Date) {
        hidesFocusRing = byPointer
        guard succeeded else { return }
        copiedKey = key
        copiedUntil = now.addingTimeInterval(Self.duration)
    }

    /// Clears the tick once its window has passed. A timer from an earlier copy fires too early to clear a later one.
    public mutating func expire(at now: Date) {
        guard let copiedUntil, now >= copiedUntil else { return }
        copiedKey = nil
        self.copiedUntil = nil
    }

    public mutating func focusChanged(to focused: Bool) {
        if !focused { hidesFocusRing = false }
    }

    static func isPointerEvent(_ event: NSEvent?) -> Bool {
        guard let type = event?.type else { return false }
        return [.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp]
            .contains(type)
    }
}

/// The one Copy button (UXP-3): the notch History rows, General › Last dictation and the menu-bar popover. The glyph
/// turns into a tick for `CopyFeedback.duration` and VoiceOver hears "Copied".
public struct CopyFeedbackButton: View {
    public static let hitTarget: CGFloat = 24

    private let label: String
    private let key: String
    @Binding private var feedback: CopyFeedback
    private let foreground: Color?
    private let glyphSize: CGFloat
    private let copy: () -> Bool
    @FocusState private var isFocused: Bool

    /// `copy` returns whether the text reached the pasteboard.
    public init(
        _ label: String,
        key: String = "",
        feedback: Binding<CopyFeedback>,
        foreground: Color? = nil,
        glyphSize: CGFloat = 12,
        copy: @escaping () -> Bool
    ) {
        self.label = label
        self.key = key
        _feedback = feedback
        self.foreground = foreground
        self.glyphSize = glyphSize
        self.copy = copy
    }

    public var body: some View {
        let isCopied = feedback.isCopied(key: key, at: Date())
        Button {
            let succeeded = copy()
            feedback.copied(
                key: key,
                succeeded: succeeded,
                byPointer: CopyFeedback.isPointerEvent(NSApp.currentEvent),
                at: Date()
            )
            guard succeeded else { return }
            AccessibilityNotification.Announcement("Copied").post()
            let binding = $feedback
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(CopyFeedback.duration))
                binding.wrappedValue.expire(at: Date())
            }
        } label: {
            Image(systemName: isCopied ? VoiceBarActionSymbol.copied : VoiceBarActionSymbol.copy)
                .font(.system(size: glyphSize, weight: .semibold))
                .foregroundStyle(foreground ?? Color.secondary)
                .frame(width: Self.hitTarget, height: Self.hitTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focused($isFocused)
        .focusEffectDisabled(feedback.hidesFocusRing)
        .onChange(of: isFocused) { _, focused in feedback.focusChanged(to: focused) }
        .help(isCopied ? "Copied" : label)
        .accessibilityLabel(isCopied ? "Copied" : label)
    }
}

/// An icon-only Settings button (UXP-3, UX pass #7/#15): always a tooltip, always a 24 pt target.
public struct SettingsIconButtonSpec: Equatable {
    public let symbol: String
    public let help: String

    public static let hitTarget: CGFloat = 24

    public static let refreshHistory = Self(symbol: "arrow.clockwise", help: "Refresh history")
    public static let refreshAskHistory = Self(symbol: "arrow.clockwise", help: "Refresh ask history")
    public static let jumpToLatest = Self(symbol: "arrow.up.to.line", help: "Jump to latest")
    public static let clearSearch = Self(symbol: "xmark.circle.fill", help: "Clear search")

    public static let all: [Self] = [refreshHistory, refreshAskHistory, jumpToLatest, clearSearch]
}

struct SettingsIconButton: View {
    let spec: SettingsIconButtonSpec
    /// Pulls the 24 pt target back into the layout by this much per side, for a button that sits inside a field.
    var layoutInset: CGFloat = 0
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: spec.symbol)
                .frame(width: SettingsIconButtonSpec.hitTarget, height: SettingsIconButtonSpec.hitTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .padding(-layoutInset)
        .help(spec.help)
        .accessibilityLabel(spec.help)
    }
}
