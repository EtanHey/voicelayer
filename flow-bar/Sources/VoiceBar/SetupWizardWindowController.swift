import AppKit
import SwiftUI
import VoiceBarUI

/// F3: owns the one setup wizard window. It is an ordinary window (never modal), opened on first launch or from
/// Settings / the menu; closing it counts as Skip setup.
final class SetupWizardWindowController: NSObject, NSWindowDelegate {
    private let defaults: UserDefaults
    private let makeDependencies: () -> SetupWizardDependencies
    private var window: NSWindow?
    private var controller: SetupWizardController?

    init(defaults: UserDefaults, makeDependencies: @escaping () -> SetupWizardDependencies) {
        self.defaults = defaults
        self.makeDependencies = makeDependencies
    }

    func show() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        if let window {
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
            return
        }
        let controller = SetupWizardController(
            store: SetupWizardCompletionStore(defaults: defaults),
            onClose: { [weak self] in self?.window?.close() }
        )
        let hosting = NSHostingController(
            rootView: SetupWizardView(controller: controller, dependencies: makeDependencies())
        )
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: SetupWizardView.contentSize),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Set up VoiceBar"
        window.contentViewController = hosting
        window.setContentSize(SetupWizardView.contentSize)
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.collectionBehavior = [.moveToActiveSpace]
        // Like Settings: VoiceBar is an accessory app, so a normal-level window drops behind the app the user clicks
        // into for Try it.
        window.level = .floating
        window.center()
        self.window = window
        self.controller = controller
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow, closing === window else { return }
        controller?.windowDidClose()
        window = nil
        controller = nil
    }

    var windowForTesting: NSWindow? {
        window
    }

    var controllerForTesting: SetupWizardController? {
        controller
    }
}
