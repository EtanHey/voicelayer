import AppKit
import OffscreenTestSupport
import SwiftUI
@testable import VoiceBarUI
import XCTest

/// Lane A RED->GREEN probe. The SAME file compiles on base (849483ae) and on the lane head; only the tiny shim
/// (LaneAProbeShim.swift, one per tree) names each tree's dismissal type. Events are posted to THIS test process's
/// own queue (NSApp.postEvent), so the local monitors run exactly as in the app; nothing reaches the screen.
@MainActor
final class LaneARedProbeTests: XCTestCase {
    /// Pumps this process's event queue the way NSApplication.run does: local monitors run inside
    /// `NSApplication.sendEvent`, which a test process never calls on its own.
    private func drain(_ seconds: TimeInterval = 0.2) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            guard let event = NSApp.nextEvent(matching: .any, until: Date().addingTimeInterval(0.02),
                                              inMode: .default, dequeue: true) else { continue }
            NSApp.sendEvent(event)
        }
    }

    private func window(_ style: NSWindow.StyleMask) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 40, height: 40),
                              styleMask: style, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        VLOrderTestWindow(window)
        return window
    }

    /// Etan: History closes on a click on VoiceBar's own Settings window.
    func testProbeAClickOnVoiceBarsOwnSettingsWindowClosesHistory() throws {
        _ = NSApplication.shared
        var closes = 0
        let dismissal = LaneAProbeShim.dismissal { closes += 1 }
        let settings = window([.titled])
        defer { settings.close(); LaneAProbeShim.stop(dismissal) }
        LaneAProbeShim.start(dismissal)
        let down = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown, location: NSPoint(x: 10, y: 10), modifierFlags: [], timestamp: 0,
            windowNumber: settings.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        NSApp.postEvent(down, atStart: false)
        drain()
        XCTAssertEqual(closes, 1, "a mouse-down in VoiceBar's Settings window must close History")
    }

    /// NATIVE-U4: Esc delivered to VoiceBar (here, with the Settings window as the target) must close History.
    func testProbeEscapeDeliveredToVoiceBarClosesHistory() throws {
        _ = NSApplication.shared
        var closes = 0
        let dismissal = LaneAProbeShim.dismissal { closes += 1 }
        let settings = window([.titled])
        defer { settings.close(); LaneAProbeShim.stop(dismissal) }
        LaneAProbeShim.start(dismissal)
        let escape = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: settings.windowNumber,
            context: nil, characters: "\u{1B}", charactersIgnoringModifiers: "\u{1B}", isARepeat: false, keyCode: 53))
        NSApp.postEvent(escape, atStart: false)
        drain()
        XCTAssertEqual(closes, 1, "Esc reaching VoiceBar must close History")
    }

    /// Etan, 2.4: "collapsed 6, expanded 8, scrolls to 20" and "one spring, no multi-stage".
    func testProbeRowsAndOneSpring() {
        XCTAssertEqual(NotchHistoryMorph.visibleRows, 6, "collapsed 6")
        XCTAssertEqual(NotchHistoryMorph.maximumRows, 8, "expanded 8")
        XCTAssertEqual(LaneAProbeShim.recentEntryLimit(), 20, "scrolls to 20")
        XCTAssertEqual(NotchHistoryMorph.openResponse, NotchHistoryMorph.closeResponse, "one spring")
        XCTAssertEqual(NotchHistoryMorph.openDampingFraction, NotchHistoryMorph.closeDampingFraction, "one spring")
        XCTAssertEqual(NotchHistoryMorph.rowsOpacity(progress: 0.2), 0.2, accuracy: 1e-9, "no delayed fade stage")
        XCTAssertEqual(NotchHistoryMorph.rowsBlur(progress: 0.5), 0, "no blur stage")
    }

    /// The version line never truncates "ahead of release".
    func testProbeVersionFooterNeverTruncates() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/VoiceBarUI/SettingsNavigationShell.swift")
        let shell = try String(contentsOf: root, encoding: .utf8)
        let footer = String(shell[shell.range(of: "struct SettingsVersionFooter")!.lowerBound...].prefix(2500))
        XCTAssertFalse(footer.contains(".truncationMode(.tail)"), "the footer cuts 'Ahead of release' with …")
    }

    // MARK: Drag UP closes History (the real BarView in the real panel; base-compatible API only)

    private final class Router: BarCommandRouting {
        func handlePrimaryTap() {}
        func handleCancel() {}
        func handleStop() {}
        func handleReplay() {}
        func handleRetranscribeHistoryEntry(recordingPath _: String) {}
    }

    private func send(_ type: NSEvent.EventType, at point: NSPoint, to panel: NSWindow) throws {
        panel.sendEvent(try XCTUnwrap(NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: panel.windowNumber, context: nil, eventNumber: 1, clickCount: 1,
            pressure: type == .leftMouseUp ? 0 : 1)))
    }

    func testProbeDraggingTheOpenHistoryBodyUpClosesIt() throws {
        let state = VoiceState(
            recentTranscriptionsLoader: { [] }, recentTranscriptionsSaver: { _ in },
            recentTranscriptionEntriesLoader: { [] }, recentTranscriptionEntriesSaver: { _ in },
            transcriptionVocabularyLoader: { [] }, transcriptionVocabularyAliasLoader: { [] },
            keepsExpandedInDevState: false)
        state.isConnected = true
        state.isCollapsed = false
        state.isHovering = true
        state.recentTranscriptionEntries = (0 ..< 12).map {
            RecentTranscriptionEntry(text: "Synthetic row \($0)", recordingPath: "/synthetic/\($0).wav",
                                     createdAt: Date().addingTimeInterval(Double(-60 * $0)))
        }
        let model = VoiceBarNotchPresentationModel()
        let configuration = VoiceBarNotchInteractionConfiguration(leadingControlCount: 2, trailingControlCountFromCore: 2)
        func layout() -> VoiceBarPanelLayout {
            VoiceBarPanelLayout.make(presentation: model.presentation, interactionConfiguration: configuration,
                                     canvasGeometry: VoiceBarNotchMorphCanvasLayout.resolve(for: model.presentation).canvasGeometry)
        }
        let host = PillHostingView(rootView: BarView(state: state, commandRouter: Router(), onOpenSettings: {},
                                                     onOpenHistory: {}, presentationModel: model, includesPanelOutsets: true))
        host.activeHitTestProvider = { _ in true }
        host.renderedSurfaceHitTestProvider = { _ in true }
        let panel = FloatingPillPanel(content: host)
        panel.isPillDragEnabled = false
        panel.setFrameOrigin(NSPoint(x: -100_000, y: -100_000))
        panel.orderBack(nil)
        defer { panel.isReleasedWhenClosed = false; panel.orderOut(nil); panel.close() }
        model.setHovered(true)
        func resize() {
            panel.setContentSize(layout().panelSize)
            host.frame = NSRect(origin: .zero, size: layout().panelSize)
            host.layoutSubtreeIfNeeded()
        }
        resize()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        let launcher = layout()
        let rects = VoiceBarNotchHitRegion(geometry: launcher.presentation.geometry, configuration: configuration).rects
            .map { $0.offsetBy(dx: launcher.visibleContentRect.minX, dy: launcher.visibleContentRect.minY) }
        let history = NSPoint(x: rects[2].midX, y: rects[2].midY)
        try send(.leftMouseDown, at: history, to: panel)
        try send(.leftMouseUp, at: history, to: panel)
        var deadline = Date().addingTimeInterval(3)
        while !model.isHistoryPanelOpen, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        XCTAssertTrue(model.isHistoryPanelOpen)
        resize()
        RunLoop.main.run(until: Date().addingTimeInterval(1.0))
        let height = host.bounds.height
        let start = NSPoint(x: rects[0].union(rects[3]).midX, y: height - 17 - 200)
        try send(.leftMouseDown, at: start, to: panel)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        for step in 1 ... 12 {
            try send(.leftMouseDragged, at: NSPoint(x: start.x, y: start.y + 15 * CGFloat(step)), to: panel)
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        try send(.leftMouseUp, at: NSPoint(x: start.x, y: start.y + 180), to: panel)
        deadline = Date().addingTimeInterval(3)
        while model.isHistoryPanelOpen, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        XCTAssertFalse(model.isHistoryPanelOpen, "pushing the open panel's rows up must close History")
    }
}
