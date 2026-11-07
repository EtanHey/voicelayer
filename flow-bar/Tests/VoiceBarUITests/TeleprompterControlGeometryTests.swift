import AppKit
import OffscreenTestSupport
import ObjectiveC
import SwiftUI
@testable import VoiceBarUI
import XCTest

/// Measures production controls, rather than a second copy of their HStack.
@MainActor
final class TeleprompterControlGeometryTests: XCTestCase {
    private final class Router: BarCommandRouting {
        var actions: [String] = []
        func handlePrimaryTap() { actions.append("primary") }
        func handleCancel() { actions.append("cancel") }
        func handleStop() { actions.append("stop") }
        func handleReplay() { actions.append("replay") }
        func handleRetranscribeHistoryEntry(recordingPath: String) { actions.append("retranscribe") }
    }

    private final class Haptics: NSObject, NSHapticFeedbackPerformer {
        var count = 0
        func perform(_ pattern: NSHapticFeedbackManager.FeedbackPattern,
                     performanceTime: NSHapticFeedbackManager.PerformanceTime) { count += 1 }
    }

    func testReplayAndEyeKeepTheirXAndSpeakingTerminalSlotIsInert() throws {
        XCTAssertTrue(VLOffscreenPolicyInstalled())
        let app = NSApplication.shared
        let setter = NSSelectorFromString("setAccessibilityEnhancedUserInterface:")
        XCTAssertTrue(app.responds(to: setter), "Offscreen SwiftUI AX must be available")
        guard app.responds(to: setter) else { return }
        // Enables AX in this test process only; no AX client, system setting or live app is touched.
        let wasEnhanced = app.value(forKey: "accessibilityEnhancedUserInterface") as? Bool ?? false
        typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
        let setEnhanced = unsafeBitCast(app.method(for: setter), to: Setter.self)
        setEnhanced(app, setter, true)
        defer { setEnhanced(app, setter, wasEnhanced) }
        // Every real control starts its action with a haptic. Count that entry even when
        // dismissRetainedTeleprompter would itself no-op in speaking, and avoid hardware feedback.
        let haptics = Haptics()
        let getter = try XCTUnwrap(class_getClassMethod(NSHapticFeedbackManager.self,
            #selector(getter: NSHapticFeedbackManager.defaultPerformer)))
        let replacement = imp_implementationWithBlock({ (_: AnyObject) -> AnyObject in haptics } as @convention(block) (AnyObject) -> AnyObject)
        let original = method_setImplementation(getter, replacement)
        defer { method_setImplementation(getter, original); imp_removeBlock(replacement) }
        for reduceMotion in [false, true] {
            let state = VoiceState(
                recentTranscriptionsLoader: { [] }, recentTranscriptionsSaver: { _ in },
                recentTranscriptionEntriesLoader: { [] }, recentTranscriptionEntriesSaver: { _ in },
                playbackAmplitudeClock: { 100 }, keepsExpandedInDevState: false
            )
            var commands: [[String: Any]] = []
            state.sendCommand = { commands.append($0) }
            state.isConnected = true
            state.isCollapsed = false
            let speaking: [String: Any] = [
                "type": "state", "state": "speaking", "text": "Synthetic geometry fixture.",
                "request_id": "geo0-read", "playback_id": "geo0-player", "generation": 1
            ]
            state.handleEvent(speaking)
            let router = Router()
            let presentation = VoiceBarNotchPresentationModel()
            presentation.updateOperationalEnvelope(hasTeleprompter: true, isRecording: false, hasCompactStatus: false)
            let host = NSHostingView(rootView:
                BarView(state: state, commandRouter: router, onOpenSettings: {}, onOpenHistory: {},
                        presentationModel: presentation, includesPanelOutsets: true)
                    .environment(\.colorScheme, .dark)
                    .environment(\.visualRenderTime, 0)
            )
            host.frame = CGRect(origin: .zero, size: host.fittingSize)
            let window = NSPanel(contentRect: host.frame, styleMask: [.borderless, .nonactivatingPanel],
                                 backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            VLOrderCompositorTestWindow(window)
            defer { window.contentView = nil; window.close() }
            settle(host)
            // The system environment is read-only. Drive its production presentation-model input
            // after onAppear without changing the user's accessibility preferences.
            presentation.setReducedMotion(reduceMotion)
            settle(host)
            XCTAssertEqual(presentation.isReducedMotionEnabled, reduceMotion)

            let replay = try frame("Replay", in: host)
            let eye = try frame("Hide teleprompter", in: host)
            let terminal = eye.offsetBy(dx: eye.width + 10, dy: 0)
            let accessibility = elements(host)
            XCTAssertFalse(accessibility.contains { $0.label == "Dismiss teleprompter" })
            XCTAssertFalse(accessibility.contains { $0.children.isEmpty && localFrame($0, in: host).intersects(terminal) },
                           "The reserved terminal slot must expose no AX element")
            XCTAssertNotNil(try button("Stop speaking", in: host), "Stop stays in the wing")
            try image(host, name: "speaking", reduceMotion: reduceMotion)

            let beforeCommands = commands.count
            let beforeHaptics = haptics.count
            try click(terminal, in: host)
            XCTAssertEqual(haptics.count, beforeHaptics, "The invisible control must receive no hit")
            XCTAssertTrue(router.actions.isEmpty, "The placeholder must not route a hit")
            XCTAssertEqual(commands.count, beforeCommands)
            XCTAssertEqual(state.mode, .speaking)
            XCTAssertFalse(state.isTeleprompterDismissed)

            // Positive control: the same offscreen event path really reaches a neighbouring button.
            try click(eye, in: host)
            XCTAssertEqual(haptics.count, beforeHaptics + 1, "The local hit probe must enter real button actions")
            XCTAssertTrue(state.isTeleprompterDismissed, "The local hit probe must reach real controls")
            state.showTeleprompter()
            state.handleEvent(["type": "state", "state": "idle", "source": "playback"])
            settle(host)
            XCTAssertTrue(state.isTeleprompterReadback)
            let readbackReplay = try frame("Replay", in: host)
            let readbackEye = try frame("Hide teleprompter", in: host)
            let dismiss = try frame("Dismiss teleprompter", in: host)
            XCTAssertEqual(replay.minX, readbackReplay.minX, accuracy: 0.5, "Replay, Reduce Motion=\(reduceMotion)")
            XCTAssertEqual(eye.minX, readbackEye.minX, accuracy: 0.5, "Eye, Reduce Motion=\(reduceMotion)")
            XCTAssertEqual(terminal.width, dismiss.width, accuracy: 0.5)
            XCTAssertEqual(terminal.height, dismiss.height, accuracy: 0.5)
            try image(host, name: "readback", reduceMotion: reduceMotion)
            print("GEO0 reduceMotion=\(reduceMotion) Replay.x=\(replay.minX)->\(readbackReplay.minX) "
                  + "Eye.x=\(eye.minX)->\(readbackEye.minX) terminal=\(dismiss.size)")

            // Reverse edge: replaying must not move either target back again.
            var replaying = speaking
            replaying["request_id"] = "geo0-replay"
            replaying["playback_id"] = "geo0-replayed-player"
            replaying["generation"] = 2
            state.handleEvent(replaying)
            settle(host)
            XCTAssertEqual(state.mode, .speaking)
            XCTAssertFalse(state.isTeleprompterReadback)
            XCTAssertEqual(try frame("Replay", in: host).minX, readbackReplay.minX, accuracy: 0.5)
            XCTAssertEqual(try frame("Hide teleprompter", in: host).minX, readbackEye.minX, accuracy: 0.5)
        }
    }

    // SwiftUI AccessibilityNode implements the AX selectors without declaring NSAccessibilityProtocol.
    private struct AX {
        let object: NSObject
        var label: String? { object.value(forKey: "accessibilityLabel") as? String }
        var role: String? { object.value(forKey: "accessibilityRole") as? String }
        var frame: CGRect { (object.value(forKey: "accessibilityFrame") as? NSValue)?.rectValue ?? .zero }
        var children: [Any] { object.value(forKey: "accessibilityChildren") as? [Any] ?? [] }
    }

    private func elements(_ root: Any, depth: Int = 0) -> [AX] {
        guard depth < 30, let object = root as? NSObject,
              object.responds(to: NSSelectorFromString("accessibilityRole")) else { return [] }
        let node = AX(object: object)
        return [node] + node.children.flatMap { elements($0, depth: depth + 1) }
    }

    private func button(_ label: String, in host: NSView) throws -> AX {
        try XCTUnwrap(elements(host).first { $0.role == NSAccessibility.Role.button.rawValue && $0.label == label },
                      "Missing real BarView button: \(label); AX: \(elements(host).map { "\($0.role ?? "nil"):\($0.label ?? "nil")" })")
    }

    private func localFrame(_ element: AX, in host: NSView) -> CGRect {
        host.convert(host.window!.convertFromScreen(element.frame), from: nil)
    }

    private func frame(_ label: String, in host: NSView) throws -> CGRect {
        let rect = localFrame(try button(label, in: host), in: host)
        XCTAssertGreaterThan(rect.width, 0)
        XCTAssertGreaterThan(rect.height, 0)
        return rect
    }

    private func settle(_ host: NSView) {
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.7))
        host.layoutSubtreeIfNeeded()
    }

    /// Dispatches only to our offscreen panel. Never posts globally or moves the pointer.
    private func click(_ rect: CGRect, in host: NSView) throws {
        let window = try XCTUnwrap(host.window)
        let point = host.convert(CGPoint(x: rect.midX, y: rect.midY), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            window.sendEvent(event)
        }
        settle(host)
    }

    private func image(_ host: NSView, name: String, reduceMotion: Bool) throws {
        guard !reduceMotion, let output = ProcessInfo.processInfo.environment["GEO0_OUTPUT"] else { return }
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            .write(to: URL(fileURLWithPath: output).appendingPathComponent(name + ".png"))
    }
}
