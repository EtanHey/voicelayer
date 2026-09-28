import AppKit
import SwiftUI

/// The action glyphs shared by every surface (UXP-3).
public enum VoiceBarActionSymbol {
    public static let copy = "doc.on.doc"
    /// UXP-3 part 2 stub.
    public static let paste = "doc.on.clipboard"
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

/// UXP-3 part 2 stub.
public struct SettingsIconButtonSpec: Equatable {
    public let symbol: String
    public let help: String

    public static let hitTarget: CGFloat = 0
    public static let all: [SettingsIconButtonSpec] = []
}
