import Foundation

/// L105 (GO-1126 W1 slice B): which key and which mouse side buttons feed VoiceBar's dictation gestures. Only the
/// INPUT that reaches the unchanged gesture machine is chosen here: tap, hold to talk, double-tap to lock, Shift+key
/// re-paste and Option+key speak selection all keep their rules and simply follow the chosen key. Capture, the
/// recorder and the gesture state machine are not configured by this type.
public struct VoiceBarHotkeyBindings: Codable, Equatable, Sendable {
    /// The dictation key. F18 is not offered: it is the internal relay the 🎤 key helper maps the dictation key to.
    public enum Key: String, Codable, CaseIterable, Sendable {
        case f5, f6, f7, f8, f9, f10, f11, f12, f13, f14, f15, f16, f17, f19

        public var label: String { rawValue.uppercased() }

        /// The virtual keycode the event tap matches (Carbon kVK_F*).
        public var keycode: Int64 {
            switch self {
            case .f5: 96
            case .f6: 97
            case .f7: 98
            case .f8: 100
            case .f9: 101
            case .f10: 109
            case .f11: 103
            case .f12: 111
            case .f13: 105
            case .f14: 107
            case .f15: 113
            case .f16: 106
            case .f17: 64
            case .f19: 80
            }
        }
    }

    /// What a mouse side button does.
    public enum MouseRole: String, Codable, CaseIterable, Sendable {
        /// Acts exactly like the dictation key (tap, hold, double-tap).
        case dictation
        /// Sends Return.
        case returnKey
        /// Left to the app under the pointer.
        case nothing
    }

    /// The F18 relay keycode: the 🎤 key helper remaps the dictation key to F18, so F18 starts dictation whenever F5
    /// is the key (the default the helper was built for).
    public static let relayKeycode: Int64 = 79
    /// Event-tap mouse button indices: Forward is side button 5 (index 4; some mice report 5), Back is side button 4 (index 3).
    public static let forwardButtonIndices: Set<Int64> = [4, 5]
    public static let backButtonIndices: Set<Int64> = [3]

    public var key: Key
    public var forward: MouseRole
    public var back: MouseRole

    public init(key: Key = .f5, forward: MouseRole = .dictation, back: MouseRole = .returnKey) {
        self.key = key
        self.forward = forward
        self.back = back
    }

    /// Today's wiring (Etan ruling 3, 2026-09-24): F5 (plus the F18 relay), Forward acts like F5, Back sends Return.
    public static let defaults = VoiceBarHotkeyBindings()

    /// The keycodes the tap treats as the dictation key.
    public var keycodes: Set<Int64> {
        key == .f5 ? [Self.relayKeycode, key.keycode] : [key.keycode]
    }

    /// Mouse buttons that act like the dictation key.
    public var dictationMouseButtons: Set<Int64> { buttons(for: .dictation) }

    /// Mouse buttons that send Return.
    public var returnMouseButtons: Set<Int64> { buttons(for: .returnKey) }

    private func buttons(for role: MouseRole) -> Set<Int64> {
        (forward == role ? Self.forwardButtonIndices : []).union(back == role ? Self.backButtonIndices : [])
    }

    // MARK: Labels

    public var keyLabel: String { key.label }
    public var repasteLabel: String { "Shift+" + key.label }
    public var speakSelectionLabel: String { "Option+" + key.label }

    public func roleTitle(_ role: MouseRole) -> String {
        switch role {
        case .dictation: "Dictation"
        case .returnKey: "Return"
        case .nothing: "Nothing"
        }
    }

    // MARK: Persistence

    public static let defaultsKey = "VoiceBar.hotkeyBindings"

    /// The saved bindings, or the defaults when nothing (or something unreadable) is saved.
    public static func load(from defaults: UserDefaults) -> VoiceBarHotkeyBindings {
        guard let data = defaults.data(forKey: defaultsKey),
              let saved = try? JSONDecoder().decode(VoiceBarHotkeyBindings.self, from: data) else { return .defaults }
        return saved
    }

    public func save(to defaults: UserDefaults) {
        if self == .defaults {
            defaults.removeObject(forKey: Self.defaultsKey)
        } else if let data = try? JSONEncoder().encode(self) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }
}

/// L105: the one binding state every Settings surface reads (Codex r1 on #980: two surfaces each caching their own
/// copy could undo each other's edits). An edit applies to the latest bindings; the app applies it to the event tap
/// and the model changes only when that succeeded, so a failed switch never reads back as chosen.
@MainActor
public final class HotkeyBindingsModel: ObservableObject {
    @Published public private(set) var bindings: VoiceBarHotkeyBindings
    /// A change is being applied to the tap; the pickers wait for it.
    @Published public private(set) var isApplying = false
    /// Why the last change failed, in words for the person who made it; nil after a success.
    @Published public private(set) var error: String?
    /// Bumps whenever the bound key changes, so a shortcut check started for the old key is dropped.
    @Published public private(set) var keyGeneration = 0
    /// Why the pickers are locked right now (a recording or a held key); nil when a change is allowed.
    public let disabledReason: () -> String?
    private let apply: (VoiceBarHotkeyBindings, @escaping (String?) -> Void) -> Void

    /// `apply` switches the tap to the new bindings and calls back on main with nil, or the reason it failed.
    public init(bindings: VoiceBarHotkeyBindings, disabledReason: @escaping () -> String? = { nil },
                apply: @escaping (VoiceBarHotkeyBindings, @escaping (String?) -> Void) -> Void) {
        self.bindings = bindings
        self.disabledReason = disabledReason
        self.apply = apply
    }

    /// Changes one field of the latest bindings and applies the result.
    public func update(_ change: (inout VoiceBarHotkeyBindings) -> Void) {
        guard !isApplying else { return }
        var next = bindings
        change(&next)
        guard next != bindings else { return }
        let previous = bindings
        isApplying = true
        apply(next) { [weak self] failure in
            guard let self else { return }
            isApplying = false
            error = failure
            guard failure == nil else { return }
            bindings = next
            if next.key != previous.key { keyGeneration += 1 }
        }
    }
}
