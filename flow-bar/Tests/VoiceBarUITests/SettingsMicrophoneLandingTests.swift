import OffscreenTestSupport
import AppKit
import SwiftUI
@testable import VoiceBarUI
import XCTest

/// C9-N item 3 (Etan, 2026-11-12, on candidate 7: "why when I click the mic picker icon in the hovered notch does it
/// go to the right settings but the title is right where the fade is?"). At 92d7ab5b "Change…" scrolled the header
/// row to the top; on the M1 that left the title text exactly at the fade's lower edge (20.0 pt, no clearance), on
/// Etan's M4 inside it. It now lands the fade's height plus a section gap below the visible top in the drawer.
/// Measured on the real SettingsView, offscreen, from the title's accessibility frame (not from the landing code).
@MainActor
final class SettingsMicrophoneLandingTests: XCTestCase {
    private var restoreAccessibility: (() -> Void)?

    override func setUp() {
        super.setUp()
        // Offscreen SwiftUI builds its accessibility tree only for an AX client; enabled in this test process only.
        let app = NSApplication.shared
        let setter = NSSelectorFromString("setAccessibilityEnhancedUserInterface:")
        guard app.responds(to: setter) else { return }
        let was = app.value(forKey: "accessibilityEnhancedUserInterface") as? Bool ?? false
        typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
        let set = unsafeBitCast(app.method(for: setter), to: Setter.self)
        set(app, setter, true)
        restoreAccessibility = { set(app, setter, was) }
    }

    override func tearDown() {
        restoreAccessibility?()
        restoreAccessibility = nil
        super.tearDown()
    }

    func testInTheDrawerTheTitleLandsBelowTheTopFade() throws {
        let gap = try titleGap(drawer: true, size: CGSize(width: 420, height: 380))
        let fade = NotchSettingsDrawerPresentation.scrollEdgeFade
        XCTAssertGreaterThanOrEqual(gap, fade + 4, "the title is fully below the \(fade) pt fade (gap \(gap) pt)")
        XCTAssertEqual(gap, fade + SettingsScrollLanding.sectionGap, accuracy: 1.5, "fade + one section gap")
    }

    /// The window measured 20 pt on the M1 at 92d7ab5b too; the landing keeps it there (it no longer depends on the
    /// Form's header-row padding, which is what put the drawer's title in the fade on the M4).
    func testInTheWindowTheTitleLandsWhereItDid() throws {
        let gap = try titleGap(drawer: false, size: CGSize(width: 780, height: 420))
        XCTAssertEqual(gap, SettingsScrollLanding.windowLead, accuracy: 1.5, "gap \(gap) pt below the top")
    }

    /// Points from the scroll view's visible top down to the top of the "Microphone priority" title, after "Change…".
    private func titleGap(drawer: Bool, size: CGSize) throws -> CGFloat {
        // One broken Setup row sits above Microphone priority, so General scrolls (healthy General has no Setup).
        let view = SettingsView(
            hotkeyEnabled: true, missingPermissions: [.accessibility], availableDevices: { [] },
            selectedDeviceID: { nil }, modelsStatus: { .loading }, onRefreshModelsStatus: {},
            vocabularyPreview: { STTVocabularyPreview(updatedAt: nil, entries: []) }, vocabularyRevision: { 0 },
            initialTab: .general,
            tabRequest: SettingsTabRequest(tab: .general, focus: .microphonePriority, id: 1)
        )
        let root: AnyView = drawer ? AnyView(view.notchDrawerPane(.general)) : AnyView(view)
        let host = NSHostingView(rootView: root.frame(width: size.width, height: size.height))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: drawer ? [.borderless] : [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        VLOrderTestWindow(window)
        defer {
            window.orderOut(nil)
            window.contentView = nil
        }
        var scroll: NSScrollView?
        settle { scroll = tallestScrollView(in: host); return scroll != nil }
        let form = try XCTUnwrap(scroll, "General's form scroll view")
        settle(timeout: 2) { form.contentView.bounds.origin.y > 1 }
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        let title = try XCTUnwrap(frame(of: "Microphone priority", in: host), "the section title's frame")
        let visible = window.convertToScreen(form.convert(form.bounds, to: nil))
        let visibleTop = visible.maxY - form.contentInsets.top
        if drawer, let path = ProcessInfo.processInfo.environment["VOICEBAR_LANDING_SHOT"], !path.isEmpty,
           let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            // Opt-in picture for the lane report. A dark backdrop stands in for the notch glass the M1 cannot draw.
            window.backgroundColor = NSColor(white: 0.16, alpha: 1)
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }
        return visibleTop - title.maxY
    }

    private func frame(of label: String, in root: Any, depth: Int = 0) -> NSRect? {
        guard depth < 60, let object = root as? NSObject,
              object.responds(to: NSSelectorFromString("accessibilityRole")) else { return nil }
        let text = (object.value(forKey: "accessibilityLabel") as? String)
            ?? (object.value(forKey: "accessibilityValue") as? String)
        if text == label, let rect = (object.value(forKey: "accessibilityFrame") as? NSValue)?.rectValue,
           rect.height > 0 {
            return rect
        }
        for child in object.value(forKey: "accessibilityChildren") as? [Any] ?? [] {
            if let found = frame(of: label, in: child, depth: depth + 1) { return found }
        }
        return nil
    }

    private func tallestScrollView(in view: NSView) -> NSScrollView? {
        var best: NSScrollView?
        func visit(_ view: NSView) {
            if let scroll = view as? NSScrollView, let height = scroll.documentView?.frame.height,
               height > scroll.contentView.bounds.height, height > (best?.documentView?.frame.height ?? 0) {
                best = scroll
            }
            view.subviews.forEach(visit)
        }
        visit(view)
        return best
    }

    @discardableResult
    private func settle(timeout: TimeInterval = 5, until condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        return condition()
    }
}
