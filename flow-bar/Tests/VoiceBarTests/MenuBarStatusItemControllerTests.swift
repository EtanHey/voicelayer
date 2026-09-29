import AppKit
import Observation
@testable import VoiceBar
@testable import VoiceBarUI
import XCTest

/// UXP-4 (UX pass #6): VoiceOver's VO-Space is an accessibility press on the status item. The window-style
/// MenuBarExtra ignored it on macOS 27, since its button has no action. These drive the status button through its
/// accessibility press handler, with a fake popover: no synthetic clicks and no real status item.
@MainActor
final class MenuBarStatusItemControllerTests: XCTestCase {
    private final class FakePopover: MenuBarPopoverPresenting {
        var isShown = false
        var window: NSWindow?
        var onClose: ((MenuBarPopoverCloseCause) -> Void)?
        private(set) var shows = 0
        private(set) var closes = 0

        func show(relativeTo _: NSButton) {
            shows += 1
            isShown = true
        }

        func close() {
            closes += 1
            dismiss(.other)
        }

        /// What the transient popover does by itself: an outside click, or Escape (`.other`).
        func dismiss(_ cause: MenuBarPopoverCloseCause = .outsideClick) {
            guard isShown else { return }
            isShown = false
            onClose?(cause)
        }
    }

    private var now: TimeInterval = 1000
    private var mouse = false

    private func controller(_ popover: FakePopover, button: NSButton) -> MenuBarStatusItemController {
        MenuBarStatusItemController(
            button: button,
            presenter: popover,
            clock: { [unowned self] in now },
            isMouseEvent: { [unowned self] in mouse }
        )
    }

    func testAnAccessibilityPressOpensThePopover() {
        let popover = FakePopover()
        let button = NSButton()
        let item = controller(popover, button: button)
        XCTAssertTrue(button.target === item)
        XCTAssertEqual(button.action, #selector(MenuBarStatusItemController.togglePopover(_:)))
        // A bare NSButton outside a window reports false here but still performs; the menu bar's AXPress returns
        // success (checked on a scratch status item, macOS 27).
        _ = button.accessibilityPerformPress()
        XCTAssertEqual(popover.shows, 1)
        XCTAssertTrue(item.isPopoverShown)
    }

    func testASecondAccessibilityPressClosesIt() {
        let popover = FakePopover()
        let button = NSButton()
        let item = controller(popover, button: button)
        _ = button.accessibilityPerformPress()
        _ = button.accessibilityPerformPress()
        XCTAssertEqual(popover.closes, 1)
        XCTAssertFalse(item.isPopoverShown)
        _ = button.accessibilityPerformPress()
        XCTAssertEqual(popover.shows, 2, "open ↔ closed, as many times as it is pressed")
    }

    func testTheStatusItemIsAnnouncedAsVoiceBar() {
        let button = NSButton()
        let item = controller(FakePopover(), button: button)
        XCTAssertEqual(button.accessibilityTitle(), "VoiceBar")
        XCTAssertEqual(button.image?.accessibilityDescription, "VoiceBar")
        item.setAlert(true)
        XCTAssertEqual(button.accessibilityTitle(), "VoiceBar", "the polish warning icon keeps the name")
        XCTAssertEqual(button.image?.accessibilityDescription, "VoiceBar")
    }

    func testThePolishWarningSwapsTheIcon() {
        let button = NSButton()
        let item = controller(FakePopover(), button: button)
        XCTAssertEqual(item.iconSymbolName, "waveform.circle.fill")
        item.setAlert(true)
        XCTAssertEqual(item.iconSymbolName, "exclamationmark.triangle.fill")
        XCTAssertNotNil(button.image)
        item.setAlert(false)
        XCTAssertEqual(item.iconSymbolName, "waveform.circle.fill")
    }

    @Observable
    final class Signal {
        var pending = false
    }

    func testTheIconFollowsTheObservedPolishSignal() {
        let button = NSButton()
        let item = controller(FakePopover(), button: button)
        let signal = Signal()
        item.trackAlert { signal.pending }
        XCTAssertEqual(item.iconSymbolName, "waveform.circle.fill")
        signal.pending = true
        XCTAssertTrue(waitOnMain { item.iconSymbolName == "exclamationmark.triangle.fill" }, "icon swapped")
        signal.pending = false
        XCTAssertTrue(waitOnMain { item.iconSymbolName == "waveform.circle.fill" }, "icon restored")
        XCTAssertEqual(button.image?.accessibilityDescription, "VoiceBar")
    }

    /// Runs the main run loop until `condition` holds or 2 s pass; nothing keeps polling after it returns.
    private func waitOnMain(_ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(2)
        while !condition(), Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        return condition()
    }

    /// A transient popover closes on the mouse-down outside it, and a click on the status item is outside it: that
    /// same click must not open it again.
    func testTheClickThatClosedThePopoverDoesNotReopenIt() {
        let popover = FakePopover()
        let button = NSButton()
        let item = controller(popover, button: button)
        _ = button.accessibilityPerformPress()
        mouse = true
        popover.dismiss()
        now += 0.05
        item.togglePopover(nil)
        XCTAssertFalse(item.isPopoverShown)
        XCTAssertEqual(popover.shows, 1)
        now += 1
        item.togglePopover(nil)
        XCTAssertTrue(item.isPopoverShown, "a later click opens it")
    }

    /// #223 r1 (RXF3): Escape stamped the outside-click guard too, so a prompt click on the item after Escape was
    /// dropped. Only the outside mouse-down that closed it can be the same click.
    func testAClickRightAfterEscapeReopensThePopover() {
        let popover = FakePopover()
        let button = NSButton()
        let item = controller(popover, button: button)
        _ = button.accessibilityPerformPress()
        popover.dismiss(.other)
        now += 0.05
        mouse = true
        item.togglePopover(nil)
        XCTAssertTrue(item.isPopoverShown)
        XCTAssertEqual(popover.shows, 2)
    }

    /// Closing it by clicking the item, or through "Open Settings…", is not an outside click either.
    func testAClickRightAfterAnIntendedCloseReopensThePopover() {
        let popover = FakePopover()
        popover.window = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: true)
        let button = NSButton()
        let item = controller(popover, button: button)
        mouse = true
        item.togglePopover(nil)
        item.togglePopover(nil)
        XCTAssertFalse(item.isPopoverShown)
        now += 0.05
        item.togglePopover(nil)
        XCTAssertTrue(item.isPopoverShown, "after a close by the item itself")
        item.closeIfPresenting(popover.window)
        now += 0.05
        item.togglePopover(nil)
        XCTAssertTrue(item.isPopoverShown, "after Open Settings… closed it")
    }

    /// The real popover classifies its close from the event it closes inside: only an unrequested mouse-down is an
    /// outside click. Escape (a key event), a requested close and no event at all are not.
    func testThePopoverReportsOnlyAnUnrequestedMouseDownAsAnOutsideClick() {
        for event: NSEvent.EventType in [.leftMouseDown, .rightMouseDown, .otherMouseDown] {
            XCTAssertEqual(MenuBarPopoverPresenter.closeCause(requested: false, during: event), .outsideClick)
            XCTAssertEqual(MenuBarPopoverPresenter.closeCause(requested: true, during: event), .other)
        }
        for event: NSEvent.EventType? in [.keyDown, .leftMouseUp, nil] {
            XCTAssertEqual(MenuBarPopoverPresenter.closeCause(requested: false, during: event), .other)
        }
    }

    func testAnAccessibilityPressRightAfterAnOutsideCloseStillOpens() {
        let popover = FakePopover()
        let button = NSButton()
        let item = controller(popover, button: button)
        _ = button.accessibilityPerformPress()
        popover.dismiss()
        now += 0.05
        mouse = false
        _ = button.accessibilityPerformPress()
        XCTAssertTrue(item.isPopoverShown)
    }

    /// "Open Settings…" / "Run setup…" close the popover they were clicked in, through the popover itself so the
    /// next press opens it again.
    func testClosingFromTheMenuBarClosesOnlyItsOwnPopover() {
        let popover = FakePopover()
        popover.window = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: true)
        let other = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: true)
        let button = NSButton()
        let item = controller(popover, button: button)
        _ = button.accessibilityPerformPress()
        XCTAssertTrue(item.popoverWindow === popover.window)
        item.closeIfPresenting(other)
        XCTAssertTrue(item.isPopoverShown)
        item.closeIfPresenting(popover.window)
        XCTAssertFalse(item.isPopoverShown)
        XCTAssertNil(item.popoverWindow)
        _ = button.accessibilityPerformPress()
        XCTAssertTrue(item.isPopoverShown)
    }
}
