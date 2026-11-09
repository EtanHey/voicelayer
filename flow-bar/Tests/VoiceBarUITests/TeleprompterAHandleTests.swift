import AppKit
import SwiftUI
@testable import VoiceBarUI
import XCTest

/// U5 follow-up guards: the live notch follows the Teleprompter A handle (formal/teleprompter-a-handle).
@MainActor
final class TeleprompterAHandleTests: XCTestCase {
    func testOnlyTheHandleStretchesPastThreeOrEightLines() {
        XCTAssertEqual(TeleprompterA.handleOvershoot(startLines: 5, translation: 30), 0)
        let past = TeleprompterA.handleOvershoot(startLines: 8, translation: 300)
        XCTAssertGreaterThan(past, 0)
        XCTAssertLessThan(past, TeleprompterA.lineHeight)
        let before = TeleprompterA.handleOvershoot(startLines: 3, translation: -300)
        XCTAssertLessThan(before, 0)
        XCTAssertGreaterThan(before, -TeleprompterA.lineHeight)
    }

    func testSurfaceHeightFollowsTheSettledLines() {
        // T8 (Etan QA 2026-11-09): no footer row and tight gaps; 91 pt of chrome plus 24 pt per line.
        XCTAssertEqual(VoiceBarNotchContract.teleprompterLowerSurfaceHeight(lines: 3), 163)
        XCTAssertEqual(VoiceBarNotchContract.teleprompterLowerSurfaceHeight(lines: 8), 283)
        XCTAssertEqual(VoiceBarNotchContract.teleprompterLowerSurfaceHeight(lines: 12), 283)
        XCTAssertEqual(VoiceBarNotchContract.geometry(for: .teleprompter).lowerSurfaceHeight, 163)
        let resolve = { (lines: Int) in
            VoiceBarNotchPresentation.resolve(hasTeleprompter: true, isRecording: false, hasCompactStatus: false,
                                              teleprompterLines: lines, isHovered: false, isKeyboardFocused: false)
        }
        XCTAssertEqual(resolve(3).geometry.lowerSurfaceHeight, 163)
        XCTAssertEqual(resolve(5).geometry.lowerSurfaceHeight, 211)
        XCTAssertEqual(resolve(8).geometry.lowerSurfaceHeight, 283)
        // Lines never leak into another surface.
        let history = VoiceBarNotchPresentation.resolve(hasTeleprompter: false, isRecording: false, hasCompactStatus: false,
                                                        hasHistoryPanel: true, teleprompterLines: 8,
                                                        isHovered: false, isKeyboardFocused: false)
        XCTAssertEqual(history.geometry.lowerSurfaceHeight,
                       VoiceBarNotchPresentation.resolve(hasTeleprompter: false, isRecording: false, hasCompactStatus: false,
                                                         hasHistoryPanel: true, isHovered: false, isKeyboardFocused: false)
                        .geometry.lowerSurfaceHeight)
    }

    /// The window always holds eight lines, so a handle drag never resizes it under the pointer.
    func testTheTeleprompterWindowNeverResizesWithTheHandle() {
        let heights = [3, 5, 8].map { lines -> CGFloat in
            let presentation = VoiceBarNotchPresentation.resolve(hasTeleprompter: true, isRecording: false,
                                                                 hasCompactStatus: false, teleprompterLines: lines,
                                                                 isHovered: false, isKeyboardFocused: false)
            return VoiceBarNotchMorphCanvasLayout.resolve(for: presentation).canvasGeometry.totalHeight
        }
        XCTAssertEqual(Set(heights).count, 1, "\(heights)")
    }

    func testPresentationModelTakesClampedLinesAtOnce() {
        let model = VoiceBarNotchPresentationModel()
        model.updateOperationalEnvelope(hasTeleprompter: true, isRecording: false, hasCompactStatus: false)
        model.setTeleprompterLines(6)
        XCTAssertEqual(model.teleprompterLines, 6)
        XCTAssertEqual(model.presentation.geometry.lowerSurfaceHeight, 235, "the hit region takes the lines synchronously")
        model.setTeleprompterLines(40)
        XCTAssertEqual(model.teleprompterLines, 8)
    }

    func testVoiceStateLinesDriveThePresentationInput() {
        let state = VoiceState()
        state.handleEvent(["type": "state", "state": "speaking", "text": "Handle", "playback_id": "h", "generation": 1])
        XCTAssertEqual(state.teleprompterVisibleLines, 3)
        state.teleprompterVisibleLines = 7
        var input = VoiceBarNotchOperationalInput(mode: .speaking, hasTeleprompterText: true, readQueueLeadingSlotCount: 1)
        input.teleprompterLines = state.teleprompterVisibleLines
        XCTAssertEqual(VoiceBarPresentation.notchPresentation(from: input).geometry.lowerSurfaceHeight, 259)
    }

    /// T7 (Etan QA 2026-11-09) reverses 2.3 U5: the red Stop sits in the eye row again, as its terminal control.
    func testLowerRowCarriesTheStopAndTheHandleIsKeyboardOnlyFocusable() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let bar = try String(contentsOf: root.appendingPathComponent("Sources/VoiceBarUI/BarView.swift"), encoding: .utf8)
        let lower = try XCTUnwrap(bar.components(separatedBy: "private var notchTeleprompterControls").dropFirst().first)
            .components(separatedBy: "// MARK: - Error state")[0]
        XCTAssertTrue(lower.contains("playbackStopButton"), "the teleprompter's lower row carries the live Stop")
        let view = try String(contentsOf: root.appendingPathComponent("Sources/VoiceBarUI/TeleprompterAView.swift"),
                              encoding: .utf8)
        XCTAssertTrue(view.contains(".focusable(interactions: .activate)"))
        XCTAssertFalse(view.contains(".focusable()"), "a click on the handle must not make the panel key")
    }

    // MARK: - Rendered pointer-hold ownership (review R1 on #738; the reviewer's probe shape)

    private struct Mounted {
        let host: NSHostingView<AnyView>
        let window: NSWindow
        let handle: NSPoint
    }

    private func mount(_ view: TeleprompterAHeightHandle) throws -> Mounted {
        let host = NSHostingView(rootView: AnyView(view))
        host.frame = NSRect(x: 0, y: 0, width: 440, height: 140)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.orderBack(nil)
        addTeardownBlock { window.orderOut(nil); window.contentView = nil; window.close() }
        drain(host)
        func descendants(_ view: NSView) -> [NSView] { view.subviews + view.subviews.flatMap(descendants) }
        let tooltip = try XCTUnwrap(descendants(host).first { $0.toolTip == "Drag to show more or fewer lines" })
        return Mounted(host: host, window: window,
                       handle: tooltip.convert(NSPoint(x: tooltip.bounds.midX, y: tooltip.bounds.midY), to: nil))
    }

    private func drain(_ host: NSView) {
        RunLoop.main.run(until: Date().addingTimeInterval(0.25))
        host.layoutSubtreeIfNeeded()
    }

    private func send(_ type: NSEvent.EventType, _ point: NSPoint, _ number: Int, in mounted: Mounted) throws {
        mounted.window.sendEvent(try XCTUnwrap(NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: mounted.window.windowNumber, context: nil, eventNumber: number, clickCount: 1, pressure: 1)))
        drain(mounted.host)
    }

    private func handleView(_ holds: @escaping (Bool) -> Void) -> TeleprompterAHeightHandle {
        TeleprompterAHeightHandle(visibleLines: 3, onVisibleLinesChange: { _ in }, onHandleDrag: holds)
    }

    func testNormalReleaseLetsGoOfTheHoldOnce() throws {
        let model = VoiceBarNotchPresentationModel()
        var holds: [Bool] = []
        let mounted = try mount(handleView { holds.append($0); model.setTeleprompterHandlePullActive($0) })
        try send(.leftMouseDown, mounted.handle, 1, in: mounted)
        try send(.leftMouseDragged, NSPoint(x: mounted.handle.x, y: mounted.handle.y - 3), 2, in: mounted)
        XCTAssertTrue(model.isPointerHeldByPull)
        try send(.leftMouseUp, NSPoint(x: mounted.handle.x, y: mounted.handle.y - 3), 3, in: mounted)
        XCTAssertEqual(holds, [true, false])
        XCTAssertFalse(model.isPointerHeldByPull)
    }

    /// RED before the fix: the handle went away mid-drag, onEnded never came and the hold stayed (the 8-line reserve
    /// then swallowed clicks meant for the app underneath).
    func testHandleRemovedMidDragReleasesItsHold() throws {
        let model = VoiceBarNotchPresentationModel()
        var holds: [Bool] = []
        let mounted = try mount(handleView { holds.append($0); model.setTeleprompterHandlePullActive($0) })
        try send(.leftMouseDown, mounted.handle, 1, in: mounted)
        try send(.leftMouseDragged, NSPoint(x: mounted.handle.x, y: mounted.handle.y - 3), 2, in: mounted)
        XCTAssertEqual(holds, [true])
        mounted.host.rootView = AnyView(Text("Handle removed."))
        drain(mounted.host)
        XCTAssertEqual(holds, [true, false], "the handle's disappearance releases its hold")
        XCTAssertFalse(model.isPointerHeldByPull)
        try send(.leftMouseUp, NSPoint(x: mounted.handle.x, y: mounted.handle.y - 3), 3, in: mounted)
        XCTAssertEqual(holds, [true, false], "never a second release")
    }

    func testTeleprompterUnmountedMidDragReleasesItsHold() throws {
        let model = VoiceBarNotchPresentationModel()
        var holds: [Bool] = []
        let mounted = try mount(handleView { holds.append($0); model.setTeleprompterHandlePullActive($0) })
        try send(.leftMouseDown, mounted.handle, 1, in: mounted)
        try send(.leftMouseDragged, NSPoint(x: mounted.handle.x, y: mounted.handle.y - 3), 2, in: mounted)
        mounted.host.rootView = AnyView(EmptyView())
        drain(mounted.host)
        XCTAssertEqual(holds, [true, false])
        XCTAssertFalse(model.isPointerHeldByPull)
    }

    /// The handle releases only its own hold: History's pull keeps the pointer.
    func testHandleNeverReleasesAHistoryHold() throws {
        let model = VoiceBarNotchPresentationModel()
        model.setHistoryPullActive(true)
        let mounted = try mount(handleView { model.setTeleprompterHandlePullActive($0) })
        try send(.leftMouseDown, mounted.handle, 1, in: mounted)
        try send(.leftMouseDragged, NSPoint(x: mounted.handle.x, y: mounted.handle.y - 3), 2, in: mounted)
        mounted.host.rootView = AnyView(EmptyView())
        drain(mounted.host)
        XCTAssertFalse(model.isTeleprompterHandlePullActive)
        XCTAssertTrue(model.isHistoryPullActive)
        XCTAssertTrue(model.isPointerHeldByPull)
    }
}
