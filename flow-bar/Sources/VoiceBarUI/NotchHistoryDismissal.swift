import AppKit

/// #166 review MUST-FIX 2: the old History popover was transient and closed on any outside click. The
/// panel lives in the notch's non-activating panel, and its body takes clicks, so a forgotten open panel
/// would keep eating clicks at the top of the screen. While it's open, a mouse-down in another app (a
/// global monitor sees only events going elsewhere, which is exactly "outside") or Esc closes it.
/// The hotkey/Escape recording path is not involved.
@MainActor
public final class NotchHistoryDismissal {
    private let onClose: () -> Void
    private var monitors: [Any] = []

    public init(onClose: @escaping () -> Void) {
        self.onClose = onClose
    }

    public var isMonitoring: Bool {
        !monitors.isEmpty
    }

    public func start() {
        guard monitors.isEmpty else { return }
        if let mouse = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown],
            handler: { [weak self] _ in
                MainActor.assumeIsolated { self?.handleOutsideMouseDown() }
            }
        ) {
            monitors.append(mouse)
        }
        if let globalKey = NSEvent.addGlobalMonitorForEvents(
            matching: .keyDown,
            handler: { [weak self] event in
                MainActor.assumeIsolated { _ = self?.handleKeyDown(event) }
            }
        ) {
            monitors.append(globalKey)
        }
        if let localKey = NSEvent.addLocalMonitorForEvents(
            matching: .keyDown,
            handler: { [weak self] event in
                MainActor.assumeIsolated { self?.handleKeyDown(event) == true ? nil : event }
            }
        ) {
            monitors.append(localKey)
        }
    }

    public func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
    }

    func handleOutsideMouseDown() {
        onClose()
    }

    /// Esc closes the panel (and a local Esc is consumed); every other key passes through.
    @discardableResult
    func handleKeyDown(_ event: NSEvent) -> Bool {
        guard event.keyCode == 53 else { return false }
        onClose()
        return true
    }
}
