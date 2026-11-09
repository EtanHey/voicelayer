import AppKit
import SwiftUI
@testable import VoiceBarUI
import XCTest

/// R0856-09/10 (Etan, 2026-11-02: "There's no tooltip, so how is someone supposed to know that this is paste?";
/// tooltips worked on some notch buttons and not on the mic/record button). Every button in the notch and its
/// History dropdown, in every state, must carry an accessibility label AND a native tooltip registered over the
/// button itself. Buttons are enumerated from the real accessibility tree of the mounted `BarView`, not from a
/// hand-kept list, so a new button without a tooltip fails here.
@MainActor
final class NotchIconButtonTooltipTests: XCTestCase {
    private final class Router: BarCommandRouting {
        func handlePrimaryTap() {}
        func handleCancel() {}
        func handleStop() {}
        func handleReplay() {}
        func handleRetranscribeHistoryEntry(recordingPath _: String) {}
    }

    private func state(_ configure: (VoiceState) -> Void) -> VoiceState {
        let state = VoiceState(recentTranscriptionsLoader: { [] }, recentTranscriptionsSaver: { _ in },
                               recentTranscriptionEntriesLoader: { [] }, recentTranscriptionEntriesSaver: { _ in },
                               transcriptionVocabularyLoader: { [] }, transcriptionVocabularyAliasLoader: { [] },
                               keepsExpandedInDevState: true)
        state.isConnected = true
        state.isCollapsed = false
        state.sendCommand = { _ in }
        configure(state)
        return state
    }

    private struct Mounted {
        /// Every focusable control SwiftUI mounted (one `KeyViewProxy` per control, at the control's own frame).
        /// SwiftUI builds no accessibility tree offscreen without an AX client, so the key loop is the
        /// enumeration; it needs no hand-kept list.
        let controls: [CGRect]
        /// Diagnostics: the hosting chain of each control, for a failure message.
        var paths: [String] = []
        let tooltips: [(text: String, frame: CGRect)]
    }

    private func mount(_ view: BarView) throws -> Mounted {
        let host = PillHostingView(rootView: view.environment(\.colorScheme, .dark))
        host.frame = NSRect(x: 0, y: 0, width: 760, height: 620)
        let panel = FloatingPillPanel(content: host)
        defer { panel.close() }
        panel.setFrameOrigin(NSPoint(x: -100_000, y: -100_000))
        panel.orderBack(nil)
        XCTAssertTrue(panel.allowsToolTipsWhenApplicationIsInactive, "VoiceBar is usually not the active app")
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))
        host.layoutSubtreeIfNeeded()
        var controls: [CGRect] = []
        var paths: [String] = []
        var tooltips: [(String, CGRect)] = []
        func walk(_ view: NSView) {
            let frame = view.convert(view.bounds, to: nil)
            if String(describing: type(of: view)).contains("KeyViewProxy"), !view.isHiddenOrHasHiddenAncestor,
               frame.width > 0, frame.height > 0 {
                controls.append(frame)
                paths.append(sequence(first: view, next: \.superview).prefix(6)
                    .map { String(String(describing: type(of: $0)).prefix(60)) }.joined(separator: " < "))
            }
            if let tip = view as? PillControlTooltip.TooltipView, let text = tip.toolTip, !text.isEmpty {
                tooltips.append((text, frame))
            }
            view.subviews.forEach(walk)
        }
        walk(host)
        return Mounted(controls: controls, paths: paths, tooltips: tooltips)
    }

    /// Every icon control has a native tooltip over it; `textButtons` controls are labelled by their own visible
    /// text and need none.
    private func assertEveryControlHasATooltip(_ name: String, _ mounted: Mounted, expecting expected: [String],
                                               textButtons: Int = 0, disabled: Set<String> = [],
                                               file: StaticString = #filePath,
                                               line: UInt = #line) {
        let texts = mounted.tooltips.map(\.text)
        for label in expected {
            XCTAssertTrue(texts.contains(label), "\(name): no tooltip \"\(label)\"; found \(texts)", file: file, line: line)
        }
        let bare = mounted.controls.filter { control in
            !mounted.tooltips.contains { control.insetBy(dx: -1, dy: -1).contains(CGPoint(x: $0.frame.midX, y: $0.frame.midY)) }
        }
        XCTAssertEqual(bare.count, textButtons,
                       "\(name): tooltips at \(mounted.tooltips.map { "\($0.text)@\($0.frame)" }); controls without a tooltip at \(bare.map { frame in "\(frame) \(mounted.controls.firstIndex(of: frame).map { mounted.paths[$0] } ?? "")" }); tooltips \(texts)", file: file, line: line)
        XCTAssertGreaterThanOrEqual(mounted.controls.count, expected.count, name, file: file, line: line)
        // A disabled control leaves the key loop but keeps its tooltip (it says what the control would do).
        for tip in mounted.tooltips where !disabled.contains(tip.text) {
            XCTAssertTrue(mounted.controls.contains { $0.insetBy(dx: -1, dy: -1).contains(CGPoint(x: tip.frame.midX, y: tip.frame.midY)) },
                          "\(name): tooltip \(tip.text) is not over a control", file: file, line: line)
        }
    }

    private let rows = [
        RecentTranscriptionEntry(text: "Synthetic first row for the tooltip test.", recordingPath: "/synthetic/a.wav",
                                 createdAt: Date().addingTimeInterval(-60)),
        RecentTranscriptionEntry(text: "Another synthetic row.", recordingPath: "/synthetic/b.wav",
                                 createdAt: Date().addingTimeInterval(-7200)),
        RecentTranscriptionEntry(text: NotchIconButtonTooltipTests.longRow, recordingPath: "/synthetic/c.wav",
                                 createdAt: Date().addingTimeInterval(-9000)),
    ]
    private static let longRow = "A synthetic dictation long enough that its one line cannot show every word in the notch."

    private func bar(_ state: VoiceState) -> BarView {
        BarView(state: state, commandRouter: Router(), onOpenSettings: {}, onOpenHistory: {})
    }

    func testIdleLauncherButtons() throws {
        let s = state { $0.isHovering = true }
        assertEveryControlHasATooltip("idle", try mount(bar(s)),
                                     // 2.3 U2: the mic's tooltip names its shortcut (3-wings mock); the chevron joins it.
                                     expecting: ["Start dictation (F5)", "Choose microphone", "History", "Settings"])
    }

    /// The dropdown open: the wing buttons keep their tooltips and every row action (Copy, Paste,
    /// Transcribe again) has one too (R0856-09).
    func testHistoryDropdownButtons() throws {
        let s = state { state in
            state.isHovering = true
            state.recentTranscriptionEntries = rows
        }
        let mounted = try mount(bar(s).presentingHistoryForTesting().forcingHistoryHover(0))
        // 2.3 lane U4: no footer. Each row's text is its own open button, labelled by that text; a row too long for
        // its line carries its whole text as a tooltip (V12).
        assertEveryControlHasATooltip("history", mounted, expecting: [
            // 2.3 U2 (mic tooltip + chevron) × U4 (row actions, the long row's clipped-text tooltip).
            "Start dictation (F5)", "Choose microphone", "Close history", "Settings",
            "Copy", "Paste into the app you were using", "Transcribe again", Self.longRow,
        ], textButtons: 2)
    }

    func testRecordingButtons() throws {
        let s = state { $0.handleEvent(["type": "state", "state": "recording"]) }
        assertEveryControlHasATooltip("recording", try mount(bar(s)),
                                     expecting: ["Stop recording", "Cancel recording"])
    }

    func testTranscribingAndErrorButtons() throws {
        let transcribing = state { $0.handleEvent(["type": "state", "state": "transcribing"]) }
        assertEveryControlHasATooltip("transcribing", try mount(bar(transcribing)),
                                     // 2.3 U2: no third control while transcribing; History and Settings stay live.
                                     expecting: ["History", "Settings"])
        let error = state { $0.handleEvent(["type": "error", "message": "Synthetic diagnostic for the tooltip test."]) }
        assertEveryControlHasATooltip("error", try mount(bar(error)),
                                     expecting: ["Synthetic diagnostic for the tooltip test.", "Dismiss error",
                                                 VoiceBarNotchFeedback.historyActionTitle])
    }

    func testSpeakingButtons() throws {
        let s = state {
            $0.handleEvent(["type": "state", "state": "speaking", "text": "Synthetic teleprompter text.",
                            "playback_id": "tooltips", "generation": 1])
        }
        // U5: each Teleprompter A word is a text-labelled "Jump to:" button, not an icon-only control.
        // T1/T6 (Etan QA 2026-11-09): speed, Back, Pause, Forward beside each other; nothing is queued, so Back and
        // Forward are disabled.
        assertEveryControlHasATooltip("speaking", try mount(bar(s)),
                                     expecting: ["Stop speaking", "Drag to show more or fewer lines", "Playback speed",
                                                 "Previous read", "Pause speech", "Next read"],
                                     textButtons: 3, disabled: ["Previous read", "Next read"])
    }
}
