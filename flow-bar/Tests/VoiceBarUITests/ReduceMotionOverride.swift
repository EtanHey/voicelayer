import AppKit
import ObjectiveC

/// Test-only and process-local: pins what `NSWorkspace.accessibilityDisplayShouldReduceMotion` answers, which is
/// where SwiftUI's `accessibilityReduceMotion` comes from, then announces the change so SwiftUI re-reads it.
/// Nothing on the host changes: no defaults domain is written and no other process sees it.
///
/// Why the motion tests need it (C6 L2, #860): GitHub's hosted macOS runner has Reduce Motion ON. Under Reduce
/// Motion, SwiftUI on macOS 26 never runs a custom `.modifier(active:identity:)` transition: zero modifier
/// evaluations, the keyed view is swapped in one update. A test that proves the full-motion crossfade must pin the
/// setting it proves, instead of inheriting whatever the machine it runs on has.
enum ReduceMotionOverride {
    /// Returns the closure that restores the previous answer. Pins nest (restore in reverse order).
    static func pin(_ reduceMotion: Bool) -> () -> Void {
        let selector = #selector(getter: NSWorkspace.accessibilityDisplayShouldReduceMotion)
        guard let method = class_getInstanceMethod(NSWorkspace.self, selector) else { return {} }
        let answer: @convention(block) (AnyObject) -> Bool = { _ in reduceMotion }
        let previous = method_setImplementation(method, imp_implementationWithBlock(answer))
        announce()
        return {
            method_setImplementation(method, previous)
            announce()
        }
    }

    private static func announce() {
        NSWorkspace.shared.notificationCenter.post(
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: NSWorkspace.shared
        )
        NotificationCenter.default.post(
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: NSWorkspace.shared
        )
    }
}
