@testable import VoiceBarUI
import XCTest

/// Replays every reachable state of formal/notch-presentation's **Fixed** policy (TLC's own state graph, not
/// hand-picked examples) through the real `VoiceBarPresentation`, feedback resolver and resident
/// `VoiceBarNotchPresentationModel`. Run `bash formal/notch-presentation/conformance.sh`; without the corpus
/// the test skips. Adapted from Lane G's historical Current replay (LaneGFormalConformanceTests), which pinned
/// the bugs this policy removes.
@MainActor
final class NotchPresentationConformanceTests: XCTestCase {
    struct NotchCase: Decodable {
        struct Input: Decodable {
            let mode, status, note: String
            let history, teleprompter, engaged, collapsed, preview: Bool
        }
        struct Expected: Decodable {
            let shell, text: String
            let visible, band, wing, historyInline, busyHistoryInline, transient: Bool
        }
        let input: Input
        let expected: Expected
    }

    private func text(_ category: String) -> String {
        switch category {
        case "none": ""
        case "short": "Busy"
        case "long": String(repeating: "Synthetic diagnostic with retained audio. ", count: 5)
            .trimmingCharacters(in: .whitespaces)
        case "select": "Select text\nfirst"
        case "preview": "Hold to talk"
        default: category
        }
    }

    func testTLCFixedNotchProjection() throws {
        guard let path = ProcessInfo.processInfo.environment["VOICEBAR_NOTCH_TLC_CASES"] else {
            throw XCTSkip("Run formal/notch-presentation/conformance.sh to supply the Fixed TLC states")
        }
        let cases = try JSONDecoder().decode([NotchCase].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        XCTAssertGreaterThan(cases.count, 100)
        let resident = VoiceBarNotchPresentationModel()
        var noticesChecked = 0
        for row in cases {
            let mode = try XCTUnwrap(VoiceMode(rawValue: row.input.mode))
            let phase: HotkeyPhase = row.input.preview ? .pressing : .idle
            let status = mode == .error ? VoiceBarPresentation.errorStatusText(text(row.input.status)) :
                text(mode == .idle && row.input.status == "none" && row.input.preview ? "preview" : row.input.status)
            // The app's own note copy, so the busy-selection classifier is exercised for real.
            let note: String? = switch row.input.note {
            case "busy": VoiceBarPresentation.selectionBusyNote(isRequested: true, mode: mode, hotkeyPhase: phase)
                ?? "Busy. Selection not read"
            case "quit": "Finish voice work or cancel the update, then quit again."
            case "rejection": "Already queued"
            default: nil
            }
            var input = VoiceBarNotchOperationalInput(mode: mode,
                hasTeleprompterText: row.input.teleprompter,
                confirmationText: row.input.status == "none" ? nil : status,
                hotkeyPhase: phase, statusText: status, isHovered: row.input.engaged,
                isCollapsed: row.input.collapsed, transientNote: note)
            input.isHistoryPanelOpen = row.input.history
            let p = VoiceBarPresentation.notchPresentation(from: input)
            let context = "\(row.input) -> \(row.expected)"
            XCTAssertEqual(String(describing: p.visualState), row.expected.shell, context)
            let lowerBase: CGFloat = p.visualState == .teleprompter ? 196 : p.visualState == .history ? 360 : 0
            XCTAssertEqual(p.geometry.lowerSurfaceHeight > lowerBase, row.expected.band, "band: \(context)")
            XCTAssertEqual(p.transientNoteRect != nil, row.expected.transient, "transient: \(context)")
            XCTAssertEqual(p.feedback?.opensHistory == true, row.expected.historyInline, "history: \(context)")
            XCTAssertEqual(p.feedback?.noteOpensHistory == true, row.expected.busyHistoryInline, "busy: \(context)")
            // A notice's text is the full copy in the tab; an operational hint is the wing's own label.
            // "preview" is the F5 hint, an operational label rather than a notice (README).
            if row.expected.visible, !["none", "preview"].contains(row.expected.text) {
                noticesChecked += 1
                XCTAssertEqual(p.feedback?.statusText, text(row.expected.text), "notice text: \(context)")
            } else if row.expected.wing {
                XCTAssertEqual(p.wingLabel(for: status), text(row.expected.text), "hint text: \(context)")
            }
            let wing = p.visualState == .compactStatus && [.idle, .error].contains(mode)
                && !p.wingLabel(for: status).isEmpty
            XCTAssertEqual(wing, row.expected.wing, "wing: \(context)")
            // N1: a visible notice is the compact tab, never wider than the notch allows.
            if row.expected.visible, let feedback = p.feedback {
                XCTAssertLessThanOrEqual(feedback.width,
                    max(p.geometry.coreWidth, VoiceBarNotchContract.noteMinimumWidth) + 0.001, context)
            }
            resident.setHovered(input.isHovered)
            resident.setHistoryPanelOpen(input.isHistoryPanelOpen)
            resident.updateOperationalEnvelope(hasTeleprompter: p.visualState == .teleprompter,
                isRecording: mode == .recording, hasCompactStatus: p.visualState == .compactStatus,
                compactStatusLeadingWingWidth: p.geometry.leadingWingWidth,
                compactStatusTrailingWingWidth: p.geometry.trailingWingWidth,
                recordingLeadingWingWidth: p.geometry.leadingWingWidth,
                recordingTrailingWingWidth: p.geometry.trailingWingWidth,
                teleprompterLeadingWingWidth: mode == .speaking ? p.geometry.leadingWingWidth : nil,
                keepsIdleExpanded: mode == .idle && !input.isCollapsed,
                transientNoteWidth: p.transientNoteWidth, feedback: p.feedback)
            XCTAssertEqual(resident.presentation, p, "resident: \(context)")
        }
        XCTAssertGreaterThan(noticesChecked, 0)
        print("Replayed \(cases.count) Fixed TLC notch projection cases (\(noticesChecked) notices) "
            + "through the real VoiceBarPresentation")
    }
}
