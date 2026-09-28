import AppKit
import SwiftUI
@testable import VoiceBarUI
import XCTest

/// "Open Dictionary…" (and later `voicebar://settings/<tab>`) must switch the tab of a Settings window that
/// is already open. The app swaps the hosting controller's root view, and SwiftUI keeps `@State` across that
/// swap, so `initialTab` alone would leave the window on whatever tab it showed before.
@MainActor
final class SettingsTabRequestTests: XCTestCase {
    func testATabRequestSwitchesAnOpenSettingsWindow() throws {
        let host = NSHostingView(rootView: settingsView(tabRequest: nil))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 620),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        window.orderFront(nil)
        defer {
            window.orderOut(nil)
            window.contentView = nil
        }
        let table = try XCTUnwrap(waitForTable(in: host))
        let general = try XCTUnwrap(SettingsTab.allCases.firstIndex(of: .general))
        let dictionary = try XCTUnwrap(SettingsTab.allCases.firstIndex(of: .dictionary))
        XCTAssertTrue(settle { table.selectedRow == general })

        host.rootView = settingsView(tabRequest: SettingsTabRequest(tab: .dictionary, id: 1))
        XCTAssertTrue(settle { table.selectedRow == dictionary }, "the request must switch the open window")

        // The user moves on; an unrelated root-view refresh with the same request must not yank them back.
        let history = try XCTUnwrap(SettingsTab.allCases.firstIndex(of: .history))
        table.selectRowIndexes([history], byExtendingSelection: false)
        XCTAssertTrue(settle { table.selectedRow == history })
        host.rootView = settingsView(tabRequest: SettingsTabRequest(tab: .dictionary, id: 1))
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(table.selectedRow, history)

        // A fresh request for the same tab fires again.
        host.rootView = settingsView(tabRequest: SettingsTabRequest(tab: .dictionary, id: 2))
        XCTAssertTrue(settle { table.selectedRow == dictionary })
    }

    /// D2 "Change…": the request lands on General with Microphone priority scrolled into view.
    func testAMicrophonePriorityFocusScrollsGeneralToThePriorityList() throws {
        func scrolledOffset(_ request: SettingsTabRequest?) throws -> CGFloat {
            let host = NSHostingView(rootView: settingsView(tabRequest: request))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 420),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = host
            window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
            window.orderFront(nil)
            defer {
                window.orderOut(nil)
                window.contentView = nil
            }
            var scrollView: NSScrollView?
            _ = settle {
                scrollView = tallestScrollView(in: host)
                return scrollView != nil
            }
            let form = try XCTUnwrap(scrollView)
            _ = settle(timeout: 2) { form.contentView.bounds.origin.y > 1 }
            return form.contentView.bounds.origin.y
        }

        let unfocused = try scrolledOffset(SettingsTabRequest(tab: .general, id: 1))
        let focused = try scrolledOffset(SettingsTabRequest(tab: .general, focus: .microphonePriority, id: 1))

        XCTAssertLessThanOrEqual(unfocused, 1, "a plain General request opens at the top")
        XCTAssertGreaterThan(focused, 100, "Change… scrolls down to Microphone priority")
    }

    private func tallestScrollView(in view: NSView) -> NSScrollView? {
        var best: NSScrollView?
        func visit(_ view: NSView) {
            if let scroll = view as? NSScrollView,
               let height = scroll.documentView?.frame.height,
               height > scroll.contentView.bounds.height,
               height > (best?.documentView?.frame.height ?? 0) {
                best = scroll
            }
            view.subviews.forEach(visit)
        }
        visit(view)
        return best
    }

    private func settingsView(tabRequest: SettingsTabRequest?) -> SettingsView {
        SettingsView(
            hotkeyEnabled: true,
            missingPermissions: [],
            availableDevices: { [] },
            selectedDeviceID: { nil },
            modelsStatus: { .loading },
            onRefreshModelsStatus: {},
            vocabularyPreview: { STTVocabularyPreview(updatedAt: nil, entries: []) },
            vocabularyRevision: { 0 },
            initialTab: .general,
            tabRequest: tabRequest
        )
    }

    private func settle(timeout: TimeInterval = 5, until condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        return condition()
    }

    private func waitForTable(in view: NSView) -> NSTableView? {
        var table: NSTableView?
        _ = settle { table = firstTable(in: view)
            return table != nil
        }
        return table
    }

    private func firstTable(in view: NSView) -> NSTableView? {
        if let table = view as? NSTableView { return table }
        for subview in view.subviews {
            if let table = firstTable(in: subview) { return table }
        }
        return nil
    }
}
