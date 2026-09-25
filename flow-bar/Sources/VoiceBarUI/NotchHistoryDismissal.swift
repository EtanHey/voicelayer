import AppKit
import SwiftUI

/// #166 review MUST-FIX 2: the old History popover was transient and closed on any outside click. The
/// panel lives in the notch's non-activating panel, and its body takes clicks, so a forgotten open panel
/// would keep eating clicks at the top of the screen. While it's open, a mouse-down in another app (a
/// global monitor sees only events going elsewhere, which is exactly "outside") or Esc closes it.
/// The hotkey/Escape recording path is not involved.
@MainActor
public final class NotchHistoryDismissal {
    private let onClose: () -> Void
    private var monitors: [Any] = []
    /// The notch panel. Only an Esc aimed at it is the panel's to consume (CodeRabbit on #166: the local
    /// monitor swallowed Esc in every VoiceBar window, e.g. a Settings sheet).
    public weak var panelWindow: NSWindow?

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
                MainActor.assumeIsolated { self?.handleGlobalKeyDown(event) }
            }
        ) {
            monitors.append(globalKey)
        }
        if let localKey = NSEvent.addLocalMonitorForEvents(
            matching: .keyDown,
            handler: { [weak self] event in
                MainActor.assumeIsolated { self?.handleLocalKeyDown(event) == true ? nil : event }
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

    /// Esc going to another app closes the panel (a global monitor can't consume it anyway).
    func handleGlobalKeyDown(_ event: NSEvent) {
        guard event.keyCode == 53 else { return }
        onClose()
    }

    /// Inside VoiceBar, only an Esc aimed at the notch panel closes and is consumed; Esc in any other VoiceBar
    /// window (Settings, its sheets) is left to that window.
    func handleLocalKeyDown(_ event: NSEvent) -> Bool {
        guard event.keyCode == 53, let panelWindow, event.window === panelWindow else { return false }
        onClose()
        return true
    }
}

/// Reports the window a SwiftUI view is hosted in (the notch panel for the History dismissal).
struct HostWindowReader: NSViewRepresentable {
    let onWindow: (NSWindow?) -> Void

    func makeNSView(context _: Context) -> NSView {
        let view = WindowReportingView()
        view.onWindow = onWindow
        return view
    }

    func updateNSView(_: NSView, context _: Context) {}

    private final class WindowReportingView: NSView {
        var onWindow: ((NSWindow?) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onWindow?(window)
        }
    }
}

/// Holds the host window for a SwiftUI view without retaining it.
final class HostWindowBox {
    weak var window: NSWindow?
}
