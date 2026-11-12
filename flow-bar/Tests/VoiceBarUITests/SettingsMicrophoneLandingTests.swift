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

    /// Round 2 (review F2): Etan's screenshot has a HEALTHY Setup, so Microphone priority is General's FIRST section
    /// and there is nothing above it to scroll. In the real drawer, at every height its grip allows (8 to 11 rows),
    /// "Change…" must still land the title fully below the fade, measured from the pane's top edge (where the fade
    /// starts) to the title's drawn top.
    func testInAHealthyDrawerTheFirstSectionTitleLandsBelowTheFadeAtEveryHeight() throws {
        let fade = NotchSettingsDrawerPresentation.scrollEdgeFade
        for rows in NotchSettingsDrawerPresentation.minimumRows ... NotchSettingsDrawerPresentation.maximumRows {
            let gap = try drawerTitleGap(rows: rows)
            XCTAssertGreaterThanOrEqual(gap, fade + 4, "\(rows) rows: the title clears the \(fade) pt fade (gap \(gap) pt)")
            XCTAssertEqual(gap, fade + SettingsScrollLanding.sectionGap, accuracy: 1.5, "\(rows) rows: fade + one gap")
        }
    }

    /// The window measured 20 pt on the M1 at 92d7ab5b too; the landing keeps it there (it no longer depends on the
    /// Form's header-row padding, which is what put the drawer's title in the fade on the M4).
    func testInTheWindowTheTitleLandsWhereItDid() throws {
        let gap = try titleGap(drawer: false, size: CGSize(width: 780, height: 420))
        XCTAssertEqual(gap, SettingsScrollLanding.windowLead, accuracy: 1.5, "gap \(gap) pt below the top")
    }

    private func settingsView(healthy: Bool, request: SettingsTabRequest?) -> SettingsView {
        // A broken Setup row sits above Microphone priority; healthy General has no Setup section at all.
        SettingsView(
            hotkeyEnabled: true, missingPermissions: healthy ? [] : [.accessibility], availableDevices: { [] },
            selectedDeviceID: { nil }, modelsStatus: { .loading }, onRefreshModelsStatus: {},
            vocabularyPreview: { STTVocabularyPreview(updatedAt: nil, entries: []) }, vocabularyRevision: { 0 },
            initialTab: .general, tabRequest: request
        )
    }

    /// The real notch drawer (tab bar, pane, fade) at `rows`, healthy General, opened by "Change…". Points from the
    /// pane's top edge to the title's top.
    private func drawerTitleGap(rows: Int) throws -> CGFloat {
        let request = SettingsTabRequest(tab: .general, focus: .microphonePriority, id: 1)
        let context = NotchSettingsDrawerContext(updates: nil, pane: { tab, request in
            AnyView(self.settingsView(healthy: true, request: request).notchDrawerPane(tab))
        })
        let size = CGSize(width: NotchHistoryMorph.bodyWidth,
                          height: NotchSettingsDrawerPresentation.lowerSurfaceHeight(rows: CGFloat(rows))
                              - NotchHistoryMorph.handleBandHeight)
        let drawer = NotchSettingsDrawer(selectedTab: .general, appearance: .dark, context: context, request: request,
                                         onSelectTab: { _ in })
        let (host, window) = show(AnyView(drawer), size: size, titled: false)
        defer { window.orderOut(nil); window.contentView = nil }
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))
        let title = try XCTUnwrap(frame(of: "Microphone priority", in: host), "\(rows) rows: the title's frame")
        let hostTop = window.convertToScreen(host.convert(host.bounds, to: nil)).maxY
        let paneTop = hostTop - NotchSettingsDrawerPresentation.topInset - NotchSettingsDrawerPresentation.tabBarHeight
        return paneTop - title.maxY
    }

    private func show(_ root: AnyView, size: CGSize, titled: Bool) -> (NSHostingView<AnyView>, NSWindow) {
        let host = NSHostingView(rootView: AnyView(root.frame(width: size.width, height: size.height)))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: titled ? [.titled] : [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        VLOrderTestWindow(window)
        return (host, window)
    }

    /// Points from the scroll view's visible top down to the top of the "Microphone priority" title, after "Change…".
    private func titleGap(drawer: Bool, size: CGSize) throws -> CGFloat {
        let view = settingsView(healthy: false,
                                request: SettingsTabRequest(tab: .general, focus: .microphonePriority, id: 1))
        let root: AnyView = drawer ? AnyView(view.notchDrawerPane(.general)) : AnyView(view)
        let (host, window) = show(root, size: size, titled: !drawer)
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
        if drawer, let path = ProcessInfo.processInfo.environment["VOICEBAR_LANDING_SHOT"], !path.isEmpty,
           let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            // Opt-in picture for the lane report. A dark backdrop stands in for the notch glass the M1 cannot draw.
            window.backgroundColor = NSColor(white: 0.16, alpha: 1)
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }
        // The drawer's fade is drawn on the pane, so its gap is measured from the pane's top (the host's top here);
        // the window's from its scroll view's visible top below the title bar.
        let hostRect = window.convertToScreen(host.convert(host.bounds, to: nil))
        let visible = window.convertToScreen(form.convert(form.bounds, to: nil))
        return (drawer ? hostRect.maxY : visible.maxY - form.contentInsets.top) - title.maxY
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
