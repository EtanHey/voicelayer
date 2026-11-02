import CoreGraphics
import Foundation

/// Return is input ordering work: never wait for the UI queue, and never replay an
/// old submission into a newly focused app. Each down/up pair stays together.
final class HotkeyReturnKeyPoster {
    static let live = HotkeyReturnKeyPoster()
    private let queue: DispatchQueue
    private let now: () -> UInt64
    private let post: (Bool) -> Void
    private var pending: [(UInt64, () -> Bool)] = []
    private var posting = false

    init(queue: DispatchQueue = DispatchQueue(label: "VoiceBar.HotkeyReturn", qos: .userInteractive),
         now: @escaping () -> UInt64 = { DispatchTime.now().uptimeNanoseconds },
         post: @escaping (Bool) -> Void = { down in
             CGEvent(keyboardEventSource: CGEventSource(stateID: .hidSystemState),
                     virtualKey: 36, keyDown: down)?.post(tap: .cghidEventTap)
         }) {
        self.queue = queue
        self.now = now
        self.post = post
    }

    func enqueue(timestamp: UInt64, isCurrent: @escaping () -> Bool) {
        queue.async {
            self.pending.append((timestamp, isCurrent))
            self.startNext()
        }
    }

    private func startNext() {
        guard !posting else { return }
        while !pending.isEmpty {
            let (timestamp, isCurrent) = pending.removeFirst()
            let current = now()
            guard isCurrent(), current >= timestamp, current - timestamp <= 250_000_000 else {
                HotkeyDiagnostics.log("[HotkeyManager] Dropped stale or stopped Return submission")
                continue
            }
            posting = true
            post(true)
            queue.asyncAfter(deadline: .now() + .milliseconds(10)) {
                // Always balance a down, including when the listener stopped meanwhile.
                self.post(false)
                self.posting = false
                self.startNext()
            }
            return
        }
    }
}

struct HotkeyTapDriver {
    var create: (CGEventMask, UnsafeMutableRawPointer) -> CFMachPort? = { mask, pointer in
        CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                          options: .defaultTap, eventsOfInterest: mask,
                          callback: hotkeyCallback, userInfo: pointer)
    }
    var enable: (CFMachPort, Bool) -> Void = { CGEvent.tapEnable(tap: $0, enable: $1) }
    var isEnabled: (CFMachPort) -> Bool = { CGEvent.tapIsEnabled(tap: $0) }
    var invalidate: (CFMachPort) -> Void = { CFMachPortInvalidate($0) }
}
