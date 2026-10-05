import AppKit
import SwiftUI
@testable import VoiceBar
@testable import VoiceBarUI
import XCTest

final class BlankSettingsSceneTests: XCTestCase {
    @MainActor
    private func startGuard(_ app: AppDelegate) {
        (app as NSApplicationDelegate).applicationWillFinishLaunching?(
            Notification(name: NSApplication.willFinishLaunchingNotification, object: NSApplication.shared)
        )
    }

    @MainActor
    private func sceneWindow(identifier: String = "com_apple_SwiftUI_Settings") -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 900, height: 450),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.identifier = NSUserInterfaceItemIdentifier(identifier)
        window.title = "VoiceBar Settings"
        window.contentViewController = NSHostingController(rootView: EmptyView())
        return window
    }

    @MainActor
    func testRestoredEmptySceneIsClosedDuringEarlyLaunch() {
        let app = AppDelegate()
        let window = sceneWindow()
        defer { window.close() }
        window.orderFront(nil)
        XCTAssertTrue(window.isVisible)
        startGuard(app)
        XCTAssertFalse(window.isVisible, "The restored SwiftUI EmptyView scene must never remain on screen")
    }

    @MainActor
    func testSceneThatAppearsAfterLaunchIsClosedSynchronously() {
        let app = AppDelegate()
        startGuard(app)
        let window = sceneWindow(identifier: "com_apple_SwiftUI_Settings-window-1")
        defer { window.close() }
        window.orderFront(nil)
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        XCTAssertFalse(window.isVisible)
    }

    @MainActor
    func testPlainReopenSuppressesSceneWithoutOpeningRealSettings() {
        let app = AppDelegate()
        let window = sceneWindow()
        defer { window.close() }
        window.orderFront(nil)
        let allowDefault = (app as NSApplicationDelegate).applicationShouldHandleReopen?(
            NSApplication.shared, hasVisibleWindows: true
        ) ?? true
        XCTAssertFalse(allowDefault)
        XCTAssertFalse(window.isVisible)
        XCTAssertNil(app.settingsWindowForTesting)
    }

    @MainActor
    func testSystemSettingsSelectorsOpenOwnedSettingsWindow() throws {
        let app = AppDelegate()
        startGuard(app)
        let previousDelegate = NSApplication.shared.delegate
        NSApplication.shared.delegate = app
        defer {
            app.settingsWindowForTesting?.close()
            NSApplication.shared.delegate = previousDelegate
        }
        for name in ["showSettingsWindow:", "showSettings:", "showPreferencesWindow:", "orderFrontPreferencesPanel:"] {
            let selector = NSSelectorFromString(name)
            guard app.responds(to: selector) else {
                XCTFail("Missing system Settings route: \(name)")
                continue
            }
            // NSApplication itself consumes the legacy Preferences action on modern macOS.
            // Test its explicit delegate route here; the nil-target path is covered separately.
            let target: Any? = name == "orderFrontPreferencesPanel:" ? app : nil
            let routed = NSApplication.shared.sendAction(selector, to: target, from: nil)
            XCTAssertTrue(routed, "Missing system Settings route: \(name)")
            let window = try XCTUnwrap(app.settingsWindowForTesting)
            XCTAssertTrue(window.isVisible)
            XCTAssertNotNil(window.contentViewController as? NSHostingController<SettingsView>)
            window.close()
        }
    }

    @MainActor
    func testLegacyPreferencesResponderChainDoesNotLeavePlaceholderWindow() {
        let app = AppDelegate()
        startGuard(app)
        let previousDelegate = NSApplication.shared.delegate
        NSApplication.shared.delegate = app
        defer {
            app.settingsWindowForTesting?.close()
            NSApplication.shared.delegate = previousDelegate
        }
        _ = NSApplication.shared.sendAction(NSSelectorFromString("orderFrontPreferencesPanel:"), to: nil, from: nil)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        XCTAssertFalse(NSApplication.shared.windows.contains {
            $0.isVisible && $0.identifier?.rawValue.hasPrefix("com_apple_SwiftUI_Settings") == true
        })
        if let window = app.settingsWindowForTesting {
            XCTAssertNotNil(window.contentViewController as? NSHostingController<SettingsView>)
        }
    }

    @MainActor
    func testLateIdentifierIsCaughtOnOcclusionChangeWithoutPollingUpdates() {
        let app = AppDelegate()
        startGuard(app)
        for name in [NSWindow.didUpdateNotification, NSApplication.didUpdateNotification] {
            let window = sceneWindow(identifier: "pending")
            defer { window.close() }
            window.orderFront(nil)
            XCTAssertTrue(window.isVisible)
            window.identifier = NSUserInterfaceItemIdentifier("com_apple_SwiftUI_Settings_window")
            let object: Any = name == NSWindow.didUpdateNotification ? window : NSApplication.shared
            NotificationCenter.default.post(name: name, object: object)
            XCTAssertTrue(window.isVisible, "Routine updates must not scan windows in a resident app")
            NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: window)
            XCTAssertFalse(window.isVisible)
            XCTAssertFalse(window.isRestorable)
        }
    }

    @MainActor
    func testPreviouslyClosedSceneCannotReappear() {
        let app = AppDelegate()
        startGuard(app)
        let window = sceneWindow()
        defer { window.close() }
        for _ in 0 ..< 2 {
            window.orderFront(nil)
            NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: window)
            XCTAssertFalse(window.isVisible)
        }
    }

    @MainActor
    func testOwnedSettingsIsExcludedEvenWithSceneIdentifier() throws {
        let app = AppDelegate()
        startGuard(app)
        app.openSettingsWindow()
        let window = try XCTUnwrap(app.settingsWindowForTesting)
        defer { window.close() }
        window.identifier = NSUserInterfaceItemIdentifier("com_apple_SwiftUI_Settings_owned")
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        XCTAssertTrue(window.isVisible)
    }

    @MainActor
    func testObserversDoNotRetainDelegateOrOutliveIt() throws {
        var app: AppDelegate? = AppDelegate()
        weak var weakApp = app
        try startGuard(XCTUnwrap(app))
        app = nil
        XCTAssertNil(weakApp)
        let window = sceneWindow()
        defer { window.close() }
        window.orderFront(nil)
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        XCTAssertTrue(window.isVisible)
    }

    @MainActor
    func testSameTitleUnrelatedWindowSurvivesGuard() {
        let app = AppDelegate()
        startGuard(app)
        let window = sceneWindow(identifier: "VoiceBar.SettingsWindow")
        defer { window.close() }
        window.orderFront(nil)
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        XCTAssertTrue(window.isVisible, "Only the SwiftUI identifier prefix identifies a stray scene")
    }
}
