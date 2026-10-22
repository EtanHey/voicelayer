import AppKit
import SwiftUI
@testable import VoiceBarUI
import XCTest

@MainActor
final class Tip2PausedTooltipTests: XCTestCase {
    // Native probes observe the real shell's lifetime without relying on private
    // SwiftUI tooltip implementation details; the panel stays offscreen and non-key.
    func testPauseAndResumeKeepMountedWingViewsAndNativeTooltipRegistration() throws {
        let state = Playback()
        let host = PillHostingView(rootView: Fixture(playback: state))
        host.frame = NSRect(x: 0, y: 0, width: 700, height: 300)
        let panel = FloatingPillPanel(content: host)
        defer { panel.close() }
        panel.setFrameOrigin(NSPoint(x: -100_000, y: -100_000))
        panel.orderBack(nil)

        func mounted(pauseLabel: String) throws -> [NSView] {
            let ready = expectation(for: NSPredicate { [self] _, _ in
                host.layoutSubtreeIfNeeded()
                let views = descendants(host)
                return ["pause": pauseLabel, "next": "Next read", "shell": "Shell continuity"].allSatisfy { id, label in
                    views.contains { $0.identifier?.rawValue == id && $0.toolTip == label }
                }
            }, evaluatedWith: nil)
            wait(for: [ready], timeout: 3)
            host.layoutSubtreeIfNeeded()
            return try ["pause", "next", "shell"].map { id in
                try XCTUnwrap(descendants(host).first { $0.identifier?.rawValue == id })
            }
        }

        let playing = try mounted(pauseLabel: "Pause speech")
        XCTAssertEqual(playing.map(\.toolTip), ["Pause speech", "Next read", "Shell continuity"])
        state.paused = true
        let paused = try mounted(pauseLabel: "Resume speech")
        for (before, after) in zip(playing, paused) {
            XCTAssertTrue(before === after, "Pause must preserve mounted wing identity: \(before.identifier!)")
        }
        XCTAssertEqual(paused.map(\.toolTip), ["Resume speech", "Next read", "Shell continuity"])
        state.paused = false
        let resumed = try mounted(pauseLabel: "Pause speech")
        for (before, after) in zip(playing, resumed) {
            XCTAssertTrue(before === after, "Resume must preserve mounted wing identity")
        }
        XCTAssertEqual(resumed.map(\.toolTip), ["Pause speech", "Next read", "Shell continuity"])
        XCTAssertTrue(panel.allowsToolTipsWhenApplicationIsInactive)
        XCTAssertFalse(panel.isKeyWindow)
    }

    func testRealStopHostSurvivesPauseAndResume() throws {
        let state = VoiceState()
        state.isConnected = true
        state.isCollapsed = false
        state.handleEvent(["type": "state", "state": "speaking", "text": "Tooltip identity", "playback_id": "tip2", "generation": 1])
        let host = PillHostingView(rootView: BarView(
            state: state, commandRouter: BarViewClickabilityTests.SpyCommandRouter(),
            onOpenSettings: {}, onOpenHistory: {}
        ).environment(\.playbackStopHostProbe, AnyView(TooltipProbe(id: "real-stop", text: "Stop speaking"))))
        host.frame = NSRect(x: 0, y: 0, width: 700, height: 300)
        let panel = FloatingPillPanel(content: host)
        defer { panel.close() }
        panel.setFrameOrigin(NSPoint(x: -100_000, y: -100_000))
        panel.orderBack(nil)
        func stopHost() throws -> NSView {
            let ready = expectation(for: NSPredicate { _, _ in
                host.layoutSubtreeIfNeeded()
                return self.descendants(host).contains { $0.toolTip == "Stop speaking" }
            }, evaluatedWith: nil)
            wait(for: [ready], timeout: 3)
            return try XCTUnwrap(descendants(host).first { $0.toolTip == "Stop speaking" })
        }
        state.handleEvent(["type": "playback_state", "state": "paused", "offset_ms": 0, "playback_id": "tip2", "generation": 2])
        XCTAssertTrue(state.isPlaybackPaused)
        let paused = try stopHost()
        state.handleEvent(["type": "playback_state", "state": "resumed", "offset_ms": 0, "playback_id": "tip2", "generation": 3])
        XCTAssertFalse(state.isPlaybackPaused)
        // Drain the actual expanded layout before pausing again.
        let expanded = expectation(for: NSPredicate { _, _ in
            host.layoutSubtreeIfNeeded()
            return host.fittingSize.height > 100
        }, evaluatedWith: nil)
        wait(for: [expanded], timeout: 3)
        state.handleEvent(["type": "playback_state", "state": "paused", "offset_ms": 0, "playback_id": "tip2", "generation": 4])
        let pausedAgain = try stopHost()
        XCTAssertTrue(paused === pausedAgain, "The real compact Stop host must survive resume and pause")
    }

    func testPlaybackWingUsesOneBranchAcrossPauseCollapse() throws {
        let package = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: package.appendingPathComponent("Sources/VoiceBarUI/BarView.swift"), encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "private var notchLeadingContent"))
        let end = try XCTUnwrap(source.range(of: "private var playbackPauseControl"))
        let leading = source[start.upperBound..<end.lowerBound]
        XCTAssertTrue(leading.contains("case .compactStatus, .teleprompter:"),
                      "Playback controls must share a SwiftUI branch through pause collapse")
    }

    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }

    private final class Playback: ObservableObject {
        @Published var paused = false
    }

    private struct Fixture: View {
        @ObservedObject var playback: Playback
        var body: some View {
            VoiceBarNotchView(presentation: .resolve(
                hasTeleprompter: !playback.paused,
                isRecording: false,
                hasCompactStatus: true,
                compactStatusLeadingWingWidth: 90,
                teleprompterLeadingWingWidth: 90,
                isHovered: false,
                isKeyboardFocused: false
            )) {
                HStack {
                    TooltipProbe(id: "pause", text: playback.paused ? "Resume speech" : "Pause speech")
                    TooltipProbe(id: "next", text: "Next read")
                }
            } trailingContent: {
                TooltipProbe(id: "shell", text: "Shell continuity")
            } lowerContent: {
                Text("Speech text")
            }
        }
    }

    private struct TooltipProbe: NSViewRepresentable {
        let id: String
        let text: String
        func makeNSView(context: Context) -> NSView {
            let view = NSView(frame: NSRect(x: 0, y: 0, width: 20, height: 20))
            view.identifier = NSUserInterfaceItemIdentifier(id)
            view.toolTip = text
            return view
        }
        func updateNSView(_ view: NSView, context: Context) {
            view.toolTip = text
        }
    }
}
