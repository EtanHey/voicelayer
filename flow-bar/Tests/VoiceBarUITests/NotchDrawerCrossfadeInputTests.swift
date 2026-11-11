import AppKit
import SwiftUI
@testable import VoiceBarUI
import XCTest

/// C6 L2 round 2 (Codex review of #876, P1): `NotchDrawerCrossfade` kept the outgoing keyed subtree hit-testable
/// while it faded out, so a click 10–106 ms after a tab or threshold switch fired the OLD pane's action wherever
/// the new pane had no control. The outgoing content must never receive input during its removal (including a
/// rapid reversal and the one update before the mirrored key catches up); the incoming content stays live.
///
/// The real `NotchDrawerCrossfade` with both production transitions, in an offscreen nonactivating panel, clicked
/// through `NSWindow.sendEvent` at an old-only control's centre while the fade runs.
@MainActor
final class NotchDrawerCrossfadeInputTests: XCTestCase {
    private var panels: [NSPanel] = []

    override func tearDown() {
        MainActor.assumeIsolated {
            for panel in panels {
                panel.isReleasedWhenClosed = false
                panel.orderOut(nil)
                panel.close()
            }
            panels.removeAll()
        }
        super.tearDown()
    }

    /// Which pane is shown, and what each pane draws at the two spots.
    @Observable final class Switch {
        var key = "A"
    }

    final class Log {
        var actions: [String] = []
    }

    private static let size = CGSize(width: 300, height: 120)
    /// Window-space (bottom-up) centres of the left and right halves.
    private static let left = NSPoint(x: 75, y: 60)
    private static let right = NSPoint(x: 225, y: 60)

    private struct Pane: View {
        let key: String
        let log: Log
        /// Panes that draw a button: "A" on the left, "B" on the right, "N" on the left (the incoming-button
        /// control case). Every other key draws nothing interactive.
        var body: some View {
            HStack(spacing: 0) {
                slot(active: key == "A" || key == "N")
                slot(active: key == "B")
            }
            .frame(width: NotchDrawerCrossfadeInputTests.size.width, height: NotchDrawerCrossfadeInputTests.size.height)
        }

        @ViewBuilder
        private func slot(active: Bool) -> some View {
            if active {
                Button { log.actions.append(key) } label: {
                    Color.gray.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .buttonStyle(.plain)
            } else {
                Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private struct Root: View {
        let state: Switch
        let log: Log
        let animation: Animation
        let transition: AnyTransition

        var body: some View {
            NotchDrawerCrossfade(key: state.key, animation: animation, transition: transition) { key in
                Pane(key: key, log: log)
            }
            .frame(width: NotchDrawerCrossfadeInputTests.size.width, height: NotchDrawerCrossfadeInputTests.size.height)
        }
    }

    private func makePanel(_ root: some View) -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: -20000, y: -20000, width: Self.size.width, height: Self.size.height),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: root)
        host.frame = NSRect(origin: .zero, size: Self.size)
        panel.contentView = host
        panel.orderBack(nil) // offscreen; never front, key or active (OffscreenSuitePolicyTests)
        panels.append(panel)
        drain(0.15)
        return panel
    }

    private func drain(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    /// Switches the pane and lets SwiftUI apply it (an offscreen window has no display link pacing its updates, so
    /// the test asks for the pass instead of guessing how long one takes). Clicks before this pass hit the pane
    /// that is still current on screen, fully opaque, which is not a mid-fade click.
    private func show(_ key: String, _ state: Switch, in panel: NSWindow) {
        state.key = key
        for _ in 0 ..< 3 {
            drain(0.001)
            panel.contentView?.layoutSubtreeIfNeeded()
            panel.displayIfNeeded()
        }
    }

    private func click(_ point: NSPoint, in panel: NSWindow) throws {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            panel.sendEvent(try XCTUnwrap(NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: panel.windowNumber, context: nil, eventNumber: 1, clickCount: 1,
                pressure: type == .leftMouseUp ? 0 : 1
            )))
        }
    }

    private var transitions: [(String, Animation, AnyTransition)] {
        [
            ("threshold", NotchDrawerMotion.easeOut(NotchDrawerMotion.contentInDuration),
             NotchDrawerMotion.contentTransition(reduceMotion: false)),
            ("tab", NotchDrawerMotion.easeOut(NotchDrawerMotion.tabInDuration),
             NotchDrawerMotion.tabTransition(reduceMotion: false)),
            ("threshold reduced motion", NotchDrawerMotion.easeOut(NotchDrawerMotion.contentInDuration),
             NotchDrawerMotion.contentTransition(reduceMotion: true)),
        ]
    }

    /// Clicks the spot at several moments through the whole fade, starting in the same turn as the key change.
    private func clicks(at point: NSPoint, in panel: NSWindow, offsets: [TimeInterval] = [0.01, 0.03, 0.06, 0.1, 0.16]) throws {
        var elapsed: TimeInterval = 0
        for offset in offsets {
            if offset > elapsed { drain(offset - elapsed); elapsed = offset }
            try click(point, in: panel)
        }
    }

    func testTheOutgoingPaneNeverTakesAClickDuringEitherFade() throws {
        for (name, animation, transition) in transitions {
            let state = Switch(), log = Log()
            let panel = makePanel(Root(state: state, log: log, animation: animation, transition: transition))
            try click(Self.left, in: panel)
            XCTAssertEqual(log.actions, ["A"], "\(name): the resting pane takes its click")
            log.actions.removeAll()

            show("C", state, in: panel) // nothing interactive where A's button was
            try clicks(at: Self.left, in: panel)
            XCTAssertEqual(log.actions, [], "\(name): a click on the fading pane's control fired its old action")
        }
    }

    func testTheIncomingPaneTakesItsClicksAtOnce() throws {
        for (name, animation, transition) in transitions {
            let state = Switch(), log = Log()
            state.key = "C"
            let panel = makePanel(Root(state: state, log: log, animation: animation, transition: transition))
            try click(Self.right, in: panel) // a fresh panel's first click only makes it key
            XCTAssertEqual(log.actions, [])
            show("N", state, in: panel) // a button on the left, arriving
            try clicks(at: Self.left, in: panel, offsets: [0.05, 0.07, 0.1, 0.14])
            XCTAssertEqual(log.actions, Array(repeating: "N", count: 4), "\(name): the incoming pane is live mid-fade")
        }
    }

    /// A → B → A inside one fade, then A → B → C: whichever pane is on its way out never takes a click, and the pane
    /// switched back to is live again.
    func testRapidReversalsNeverReachTheLeavingPane() throws {
        for (name, animation, transition) in transitions {
            let state = Switch(), log = Log()
            let panel = makePanel(Root(state: state, log: log, animation: animation, transition: transition))

            show("B", state, in: panel)
            drain(0.03)
            show("A", state, in: panel) // back before B finished arriving: B leaves, A is current again
            try clicks(at: Self.right, in: panel, offsets: [0.01, 0.02, 0.04, 0.08])
            XCTAssertEqual(log.actions, [], "\(name): the reversed-away pane B took a click")
            drain(0.4)
            try click(Self.left, in: panel)
            XCTAssertEqual(log.actions, ["A"], "\(name): the pane switched back to is live")
            log.actions.removeAll()

            show("B", state, in: panel)
            drain(0.03)
            show("C", state, in: panel)
            try clicks(at: Self.right, in: panel, offsets: [0.01, 0.02, 0.04, 0.08])
            try clicks(at: Self.left, in: panel, offsets: [0.01, 0.02])
            XCTAssertEqual(log.actions, [], "\(name): a pane leaving mid-arrival, or the one before it, took a click")
        }
    }
}
