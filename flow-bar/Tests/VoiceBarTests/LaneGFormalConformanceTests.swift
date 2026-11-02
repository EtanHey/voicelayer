@testable import VoiceBar
@testable import VoiceBarUI
import XCTest

/// Optional TLC corpus tests; no installed app, windows, event taps or audio.
@MainActor
final class LaneGFormalConformanceTests: XCTestCase {
    struct NotchCase: Decodable {
        struct Input: Decodable {
            let mode, status, note: String
            let history, teleprompter, engaged, collapsed, preview: Bool
        }
        struct Expected: Decodable {
            let shell, text: String
            let band, wing, historyInline: Bool
        }
        let input: Input
        let expected: Expected
    }
    private func text(_ category: String) -> String {
        switch category {
        case "none": ""
        case "short": "Busy"
        case "long": String(repeating: "Synthetic diagnostic with retained audio. ", count: 5).trimmingCharacters(in: .whitespaces)
        case "select": "Select text\nfirst"
        case "preview": "Hold to talk"
        default: category
        }
    }
    func testTLCNotchProjection() throws {
        guard let path = ProcessInfo.processInfo.environment["VOICEBAR_NOTCH_TLC_CASES"] else {
            throw XCTSkip("Run formal/notch-presentation/conformance.sh to supply TLC states")
        }
        let cases = try JSONDecoder().decode([NotchCase].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        XCTAssertGreaterThan(cases.count, 100)
        let resident = VoiceBarNotchPresentationModel()
        for row in cases {
            let mode = try XCTUnwrap(VoiceMode(rawValue: row.input.mode))
            let status = mode == .error ? VoiceBarPresentation.errorStatusText(text(row.input.status)) :
                text(mode == .idle && row.input.status == "none" && row.input.preview ? "preview" : row.input.status)
            let note: String? = switch row.input.note {
            case "busy": "Busy \(row.input.mode). Selection not read"
            case "quit": "Finish voice work or cancel the update, then quit again."
            case "rejection": "Already queued"
            default: nil
            }
            var input = VoiceBarNotchOperationalInput(mode: mode,
                hasTeleprompterText: row.input.teleprompter,
                confirmationText: row.input.status == "none" ? nil : status,
                hotkeyPhase: row.input.preview ? .pressing : .idle,
                statusText: status, isHovered: row.input.engaged, isCollapsed: row.input.collapsed, transientNote: note)
            input.isHistoryPanelOpen = row.input.history
            let p = VoiceBarPresentation.notchPresentation(from: input)
            let context = "\(row.input)"
            XCTAssertEqual(String(describing: p.visualState), row.expected.shell, context)
            let lowerBase: CGFloat = p.visualState == .teleprompter ? 196 : p.visualState == .history ? 360 : 0
            XCTAssertEqual(p.geometry.lowerSurfaceHeight > lowerBase, row.expected.band, context)
            XCTAssertEqual(p.feedback?.opensHistory == true, row.expected.historyInline, context)
            if row.expected.text != "none" {
                let visibleText = p.feedback?.statusText ?? (p.visualState == .compactStatus ? status : "")
                XCTAssertEqual(visibleText, text(row.expected.text), context)
            }
            let wing = p.visualState == .compactStatus && [.idle, .error].contains(mode)
                && !(p.feedback?.wingText ?? status).isEmpty
            XCTAssertEqual(wing, row.expected.wing, context)
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
            XCTAssertEqual(resident.presentation, p, context)
        }
        print("Replayed \(cases.count) TLC notch projection cases through real VoiceBarPresentation")
    }
    func testTLCNativeAdmissionCounterexample() throws {
        guard ProcessInfo.processInfo.environment["VOICEBAR_NOTCH_TLC_CASES"] != nil else {
            throw XCTSkip("Historical current-code replay is opt-in; it must not ratchet the bug")
        }
        for action in ["hold", "tap", "record", "click", "escape"] {
            let state = VoiceState(recentTranscriptionsLoader: { [] }, recentTranscriptionsSaver: { _ in },
                recentTranscriptionEntriesLoader: { [] }, recentTranscriptionEntriesSaver: { _ in },
                transcriptionVocabularyLoader: { [] }, transcriptionVocabularyAliasLoader: { [] })
            state.mode = .transcribing
            state.isConnected = true
            var commands: [String] = []
            state.sendCommand = { commands.append($0["cmd"] as? String ?? "") }
            let router = VoiceBarCommandRouter(voiceState: state)
            switch action {
            case "hold": router.handleHotkeyHoldStart()
            case "tap": router.handleHotkeySingleTap()
            case "record": state.record(pressToTalk: true)
            case "click": router.handleCancel()
            default: router.handleEscape()
            }
            XCTAssertEqual(commands, action == "record" ? [] : ["cancel"], action)
            XCTAssertEqual(state.mode, action == "record" ? .transcribing : .idle, action)
        }
        print("Confirmed TLC native F5 cancellation, direct-record gate, click and Escape counterexamples")
    }
    func testTLCDeferredFinalSupersededByNewRecording() async throws {
        guard ProcessInfo.processInfo.environment["VOICEBAR_NOTCH_TLC_CASES"] != nil else {
            throw XCTSkip("Historical current-code counterexample replay is opt-in")
        }
        for newRecording in [false, true] {
            let state = VoiceState(recentTranscriptionsLoader: { [] }, recentTranscriptionsSaver: { _ in },
                recentTranscriptionEntriesLoader: { [] }, recentTranscriptionEntriesSaver: { _ in },
                transcriptionVocabularyLoader: { [] }, transcriptionVocabularyAliasLoader: { [] })
            state.controlLayerEventWriter = { _, _ in }
            state.frontmostAppProvider = { nil }
            state.minimumTranscribingDisplayDuration = 0.01
            state.handleEvent(["type": "state", "state": "transcribing"])
            state.handleEvent(["type": "transcription", "text": "Synthetic final A"])
            if newRecording { state.handleEvent(["type": "state", "state": "recording", "bar_owned": false]) }
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertEqual(state.recentTranscriptionEntries.map(\.text), newRecording ? [] : ["Synthetic final A"])
        }
        print("Confirmed TLC deferred-final loss on a new recording event; control retains A")
    }
}
