import AppKit
import SwiftUI

/// The menu-bar popover as the status item sees it: `NSPopover` in the app, a fake in tests.
@MainActor
protocol MenuBarPopoverPresenting: AnyObject {
    var isShown: Bool { get }
    var window: NSWindow? { get }
    /// Called whenever the popover closes, including the transient close on an outside click or Escape.
    var onClose: (() -> Void)? { get set }
    func show(relativeTo button: NSButton)
    func close()
}

/// UXP-4 (UX pass #6): the menu-bar status item. It was a window-style SwiftUI `MenuBarExtra`, which on macOS 27 is
/// presented through a private AppKit session with no action on its button. So an accessibility press (VoiceOver's
/// VO-Space, `AXPress`) returned success and opened nothing. A plain `NSStatusItem` button with a target/action opens
/// for a click and for an accessibility press alike.
@MainActor
final class MenuBarStatusItemController: NSObject {
    /// A transient popover closes on the mouse-down outside it, and a click on the status item is outside it. The
    /// button's own action for that same click lands right after, so it must not reopen what it just closed.
    static let reopenGuard: TimeInterval = 0.3

    private let button: NSButton
    private let presenter: MenuBarPopoverPresenting
    private let clock: () -> TimeInterval
    private let isMouseEvent: @MainActor () -> Bool
    private var lastClosedAt: TimeInterval?

    init(
        button: NSButton,
        presenter: MenuBarPopoverPresenting,
        clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        isMouseEvent: @escaping @MainActor () -> Bool = {
            guard let type = NSApp.currentEvent?.type else { return false }
            return type == .leftMouseDown || type == .leftMouseUp
        }
    ) {
        self.button = button
        self.presenter = presenter
        self.clock = clock
        self.isMouseEvent = isMouseEvent
        super.init()
        button.target = self
        button.action = #selector(togglePopover(_:))
        // R4 UI pass #20: VoiceOver reads the name, never the SF Symbol's.
        button.setAccessibilityTitle("VoiceBar")
        setAlert(false)
        presenter.onClose = { [weak self] in
            guard let self else { return }
            lastClosedAt = self.clock()
            self.button.highlight(false)
        }
    }

    var isPopoverShown: Bool {
        presenter.isShown
    }

    /// The popover's window while it is open, for "Open Settings…" / "Run setup…" to close.
    var popoverWindow: NSWindow? {
        presenter.isShown ? presenter.window : nil
    }

    @objc func togglePopover(_: Any?) {
        if presenter.isShown {
            presenter.close()
            return
        }
        if isMouseEvent(), let lastClosedAt, clock() - lastClosedAt < Self.reopenGuard {
            return
        }
        presenter.show(relativeTo: button)
        button.highlight(true)
    }

    /// The polish-degradation warning replaces the waveform, as the MenuBarExtra label did.
    func setAlert(_ alert: Bool) {
        iconSymbolName = alert ? "exclamationmark.triangle.fill" : "waveform.circle.fill"
        button.image = NSImage(systemSymbolName: iconSymbolName, accessibilityDescription: "VoiceBar")
    }

    /// The SF Symbol on the button now (a symbol image has no `name()` to read back).
    private(set) var iconSymbolName = ""

    /// The warning icon follows `alert` (the polish signal) for as long as the item exists.
    func trackAlert(_ alert: @escaping @MainActor () -> Bool) {
        withObservationTracking {
            setAlert(alert())
        } onChange: { [weak self] in
            Task { @MainActor in self?.trackAlert(alert) }
        }
    }

    /// Closes the popover through NSPopover (not by ordering its window out), so the next press opens it again.
    func closeIfPresenting(_ window: NSWindow?) {
        guard let window, window === popoverWindow else { return }
        presenter.close()
    }
}

/// `NSPopover(.transient)` with a fresh hosting controller per open, so the content's `onAppear` runs on every
/// open as it did in the MenuBarExtra window. Escape and an outside click close it.
@MainActor
final class MenuBarPopoverPresenter: NSObject, MenuBarPopoverPresenting, NSPopoverDelegate {
    nonisolated static let windowIdentifier = NSUserInterfaceItemIdentifier("VoiceBarMenuBarPopover")

    private let popover = NSPopover()
    private let makeContent: () -> AnyView
    var onClose: (() -> Void)?

    init(makeContent: @escaping () -> AnyView) {
        self.makeContent = makeContent
        super.init()
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
    }

    var isShown: Bool {
        popover.isShown
    }

    var window: NSWindow? {
        popover.contentViewController?.view.window
    }

    func show(relativeTo button: NSButton) {
        let hosting = NSHostingController(rootView: makeContent())
        hosting.sizingOptions = .preferredContentSize
        popover.contentViewController = hosting
        NSApp.activate()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        window?.identifier = Self.windowIdentifier
        window?.makeKey()
    }

    func close() {
        popover.performClose(nil)
    }

    func popoverDidClose(_: Notification) {
        popover.contentViewController = nil
        onClose?()
    }
}
