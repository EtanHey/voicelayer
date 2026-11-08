import AppKit
import SwiftUI

/// 2.4 Lane A: how an open notch drawer (History or Settings) is dismissed from outside the notch. It never
/// decides anything itself: every decision becomes `NotchSurfaceEvent.dismiss(reason)` on the one surface model.
///
/// - Any mouse-down outside the notch closes the drawer, and the click still does whatever it was for:
///   - in another app (a global monitor sees only events going elsewhere);
///   - in VoiceBar's own Settings window, the menu-bar popover or any other VoiceBar window (a local monitor;
///     2.3 treated those as inside and left the drawer open, Etan's bug).
///   A press on the notch panel itself is inside: the panel's hit test lets clicks on empty canvas fall through
///   to the window below, so whatever reaches the panel landed on the drawn notch.
/// - Esc closes the drawer whichever app is frontmost. Inside VoiceBar it is consumed, except while a sheet or
///   modal owns it or a text field is composing (marked text), which keep their Esc.
///
/// NATIVE-U4's missing Esc receipt, root cause: the 2.3 local monitor only acted on Esc whose `event.window`
/// was the notch panel. The panel is non-activating and a click on History never makes it key (the U2 no-key
/// invariant), so a key event delivered to VoiceBar always carries the KEY window (Settings) or none, never the
/// panel. Every Esc that reached VoiceBar, including XCUI's `typeKey(.escape)` aimed at the app, fell through
/// unconsumed and closed nothing. The global monitor only sees keys going to other apps, so it never fired
/// either. Now the local path decides by modality, not by the event's window.
@MainActor
public final class NotchDrawerDismissal {
    public static let escapeKeyCode: UInt16 = 53

    private let onDismiss: (NotchDismissReason) -> Void
    private var monitors: [Any] = []
    /// The notch panel: presses that reach it are inside the drawn notch.
    public weak var panelWindow: NSWindow?
    /// Whether Esc inside VoiceBar belongs to someone else right now (a sheet, a modal, IME composition).
    public var escapeIsOwnedElsewhere: () -> Bool = NotchDrawerDismissal.escapeIsOwnedByModalOrComposition

    public init(onDismiss: @escaping (NotchDismissReason) -> Void) {
        self.onDismiss = onDismiss
    }

    public var isMonitoring: Bool {
        !monitors.isEmpty
    }

    private static let mouseDownMask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]

    public func start() {
        guard monitors.isEmpty else { return }
        if let mouse = NSEvent.addGlobalMonitorForEvents(matching: Self.mouseDownMask, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.handleGlobalMouseDown() }
        }) {
            monitors.append(mouse)
        }
        if let localMouse = NSEvent.addLocalMonitorForEvents(matching: Self.mouseDownMask, handler: { [weak self] event in
            let window = event.window
            _ = MainActor.assumeIsolated { self?.handleLocalMouseDown(in: window) }
            return event // the click still lands where it was aimed
        }) {
            monitors.append(localMouse)
        }
        if let globalKey = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.handleGlobalKeyDown(keyCode: event.keyCode) }
        }) {
            monitors.append(globalKey)
        }
        if let localKey = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            let keyCode = event.keyCode
            let consumed = MainActor.assumeIsolated { self?.handleLocalKeyDown(keyCode: keyCode) == true }
            return consumed ? nil : event
        }) {
            monitors.append(localKey)
        }
    }

    public func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
    }

    // MARK: Decisions (the monitors call these; tests call them directly)

    /// A mouse-down in another app.
    public func handleGlobalMouseDown() {
        onDismiss(.outsideClick)
    }

    /// A mouse-down inside VoiceBar: outside unless it reached the notch panel itself.
    @discardableResult
    public func handleLocalMouseDown(in window: NSWindow?) -> Bool {
        guard Self.isOutside(window: window, panel: panelWindow) else { return false }
        onDismiss(.outsideClick)
        return true
    }

    public static func isOutside(window: NSWindow?, panel: NSWindow?) -> Bool {
        guard let window, let panel else { return true }
        return window !== panel
    }

    /// Esc going to another app.
    public func handleGlobalKeyDown(keyCode: UInt16) {
        guard keyCode == Self.escapeKeyCode else { return }
        onDismiss(.escape)
    }

    /// Esc delivered to VoiceBar, whichever window it was routed to. Returns whether it was consumed.
    public func handleLocalKeyDown(keyCode: UInt16) -> Bool {
        guard keyCode == Self.escapeKeyCode, !escapeIsOwnedElsewhere() else { return false }
        onDismiss(.escape)
        return true
    }

    public static func escapeIsOwnedByModalOrComposition() -> Bool {
        if NSApp.modalWindow != nil { return true }
        guard let key = NSApp.keyWindow else { return false }
        if key.attachedSheet != nil || key.isSheet { return true }
        if let editor = key.firstResponder as? NSTextView, editor.hasMarkedText() { return true }
        return false
    }
}

/// Reports the window a SwiftUI view is hosted in (the notch panel for the drawer dismissal).
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
