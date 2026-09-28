import SwiftUI

/// UXP-3 stub.
public enum VoiceBarActionSymbol {
    public static let copy = "doc.on.doc"
    public static let copied = "checkmark"
}

/// UXP-3 stub.
public struct CopyFeedback: Equatable {
    public static let duration: TimeInterval = 1.5

    public private(set) var hidesFocusRing = false

    public init() {}

    public func isCopied(key _: String = "", at _: Date) -> Bool {
        false
    }

    public mutating func copied(key _: String = "", succeeded _: Bool, byPointer _: Bool, at _: Date) {}

    public mutating func expire(at _: Date) {}

    public mutating func focusChanged(to _: Bool) {}
}

/// UXP-3 stub.
public struct CopyFeedbackButton: View {
    public static let hitTarget: CGFloat = 0

    public var body: some View {
        EmptyView()
    }
}
