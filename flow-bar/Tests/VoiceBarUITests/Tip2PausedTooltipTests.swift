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
                return ["pause": pauseLabel, "next": "Next read", "stop": "Stop speaking"].allSatisfy { id, label in
                    views.contains { $0.identifier?.rawValue == id && $0.toolTip == label }
                }
            }, evaluatedWith: nil)
            wait(for: [ready], timeout: 3)
            host.layoutSubtreeIfNeeded()
            return try ["pause", "next", "stop"].map { id in
                try XCTUnwrap(descendants(host).first { $0.identifier?.rawValue == id })
            }
        }

        let playing = try mounted(pauseLabel: "Pause speech")
        XCTAssertEqual(playing.map(\.toolTip), ["Pause speech", "Next read", "Stop speaking"])
        state.paused = true
        let paused = try mounted(pauseLabel: "Resume speech")
        for (before, after) in zip(playing, paused) {
            XCTAssertTrue(before === after, "Pause must preserve mounted wing identity: \(before.identifier!)")
        }
        XCTAssertEqual(paused.map(\.toolTip), ["Resume speech", "Next read", "Stop speaking"])
        state.paused = false
        let resumed = try mounted(pauseLabel: "Pause speech")
        for (before, after) in zip(playing, resumed) {
            XCTAssertTrue(before === after, "Resume must preserve mounted wing identity")
        }
        XCTAssertEqual(resumed.map(\.toolTip), ["Pause speech", "Next read", "Stop speaking"])
        XCTAssertTrue(panel.allowsToolTipsWhenApplicationIsInactive)
        XCTAssertFalse(panel.isKeyWindow)
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
                TooltipProbe(id: "stop", text: "Stop speaking")
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
