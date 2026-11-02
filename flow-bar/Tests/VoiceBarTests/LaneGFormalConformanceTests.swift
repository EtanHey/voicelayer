@testable import VoiceBar
@testable import VoiceBarUI
import AppKit
import CryptoKit
import XCTest

/// Runs by default. Expected failures are strict, explicit baseline debt, never skipped corpora.
@MainActor
final class LaneGFormalConformanceTests: XCTestCase {
    private let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    struct Pin: Decodable { let sha256: String }
    struct Contract: Decodable { let notchPolicy, pipelinePolicy, cancelIdField: String; let captureIds: [String: Int] }
    struct Frame: Decodable {
        struct Input: Decodable {
            let mode, status, note: String
            let history, teleprompter, engaged, collapsed, preview, details, updateBusy: Bool
            let lines: Int
        }
        struct Expected: Decodable { let shell, text, wingText: String; let band, visible, transient, historyInline: Bool }
        let policy: String; let input: Input; let expected: Expected
    }
    struct NotchCorpus: Decodable {
        struct Lifecycle: Decodable { let policy: String; let events: [String]; let noteVisible: Bool }
        let modelSHA256: String; let rows: [Frame]; let lifecycle: [Lifecycle]
    }
    struct PipelineCorpus: Decodable {
        struct Step: Decodable { let event, target: String }
        struct Case: Decodable { let policy, kind: String; let command, take: String?; let trace: [Step]?; let delivered: [String]? }
        let modelSHA256: String; let native: [Case]
    }
    private func decode<T: Decodable>(_ type: T.Type, _ path: String) throws -> T {
        let data = try Data(contentsOf: root.appendingPathComponent(path))
        let components = path.split(separator: "/")
        if components.count == 3, components.last == "corpus.json" {
            let pin = try JSONDecoder().decode(Pin.self, from: Data(contentsOf: root.appendingPathComponent("formal/\(components[1])/results/corpus.json")))
            XCTAssertEqual(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), pin.sha256, "Corpus checksum mismatch")
        }
        return try JSONDecoder().decode(type, from: data)
    }
    private func corpusPath(_ model: String) -> String {
        let generated = ".build.noindex/\(model)/corpus.json"
        return FileManager.default.fileExists(atPath: root.appendingPathComponent(generated).path) ? generated : "formal/\(model)/corpus.json"
    }
    private func verifyModel(_ hash: String, path: String) throws {
        let bytes = try Data(contentsOf: root.appendingPathComponent(path))
        XCTAssertEqual(SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(), hash, "Regenerate the TLC corpus after a spec edit")
    }
    private func copy(_ kind: String, lines: Int) -> String {
        let first: String = switch kind {
        case "none": ""
        case "short": "Busy"
        case "long": "Synthetic diagnostic retained."
        case "select": "Select text\nfirst"
        case "preview": "Hold to talk"
        default: kind
        }
        return first.isEmpty || kind == "select" || kind == "preview" || !["short","long"].contains(kind)
            ? first : ([first] + Array(repeating: "Synthetic line", count: lines - 1)).joined(separator: "\n")
    }
    private func note(_ input: Frame.Input) -> String? {
        let first: String = switch input.note { case "busy": "Busy"; case "quit": "Quit refused"; case "rejection": "Selection not read"; default: "" }
        return first.isEmpty ? nil : ([first] + Array(repeating: "Synthetic line", count: input.lines - 1)).joined(separator: "\n")
    }
    private func input(_ row: Frame) throws -> VoiceBarNotchOperationalInput {
        let mode = try XCTUnwrap(VoiceMode(rawValue: row.input.mode))
        let raw = copy(row.input.status, lines: row.input.lines)
        let status = mode == .error ? VoiceBarPresentation.errorStatusText(raw) :
            (mode == .transcribing ? "Loading speech model" : mode == .speaking ? "Speaking…" :
                (mode == .idle && row.input.status == "none" && row.input.preview ? copy("preview", lines: 1) : raw))
        var result = VoiceBarNotchOperationalInput(mode: mode, hasTeleprompterText: row.input.teleprompter,
            confirmationText: row.input.status == "none" ? nil : status, hotkeyPhase: row.input.preview ? .pressing : .idle,
            statusText: status, isHovered: row.input.engaged, isCollapsed: row.input.collapsed, transientNote: note(row.input))
        result.isHistoryPanelOpen = row.input.history
        // Adaptation point (Lane A): the busy-selection note is marked explicitly, as VoiceState does through
        // `selectionFeedbackNoteOffersHistory`, rather than recognised by its copy.
        result.transientNoteOffersHistory = row.input.note == "busy"
        return result
    }
    private func source(_ path: String) throws -> String { try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8) }
    private func between(_ text: String, _ start: String, _ end: String) throws -> String {
        let lo = try XCTUnwrap(text.range(of: start)?.upperBound, start)
        let hi = try XCTUnwrap(text.range(of: end, range: lo..<text.endIndex)?.lowerBound, end)
        return String(text[lo..<hi])
    }
    /// Read routing from the real renderer, rather than reproducing a mode allowlist in the test.
    private func wingModes() throws -> Set<String> {
        let text = try source("flow-bar/Sources/VoiceBarUI/BarView.swift")
        let body = try between(text, "private var notchCompactStatusContent:", "private var notchSpeakingTrailingContent:")
        let regex = try NSRegularExpression(pattern: "(?s)case\\s+([^:]+):(.+?)(?=\\n\\s*case|\\z)")
        var result = Set<String>()
        for match in regex.matches(in: body, range: NSRange(body.startIndex..., in: body)) {
            let labels = String(body[try XCTUnwrap(Range(match.range(at: 1), in: body))])
            let content = String(body[try XCTUnwrap(Range(match.range(at: 2), in: body))])
            if content.contains("statusLabel") || content.contains("compactStatusLabel") {
                result.formUnion(labels.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ".", with: "") })
            }
        }
        XCTAssertFalse(result.isEmpty, "Could not observe real compact-status routing")
        return result
    }
    private func check(_ errors: [String], family: String, expectedFailure: Bool) {
        let assertion = { XCTAssertTrue(errors.isEmpty, "\(family): \(errors.count) divergences; \(errors.prefix(3))") }
        if expectedFailure { XCTExpectFailure("Baseline gap \(family); set runtime-contract.json policy to fixed when the implementing lane lands", failingBlock: assertion) }
        else { assertion() }
    }
    func testBothNotchCorporaAndIndependentProductionLedger() throws {
        let corpus = try decode(NotchCorpus.self, corpusPath("notch-presentation"))
        let contract = try decode(Contract.self, "formal/runtime-contract.json")
        try verifyModel(corpus.modelSHA256, path: "formal/notch-presentation/NotchPresentation.tla")
        XCTAssertEqual(Set(corpus.rows.map(\.policy)), ["Current", "Fixed"])
        for policy in ["Current", "Fixed"] {
            let frames = corpus.rows.filter { $0.policy == policy }
            XCTAssertEqual(Set(frames.map { $0.input.mode }), ["idle","recording","transcribing","speaking","error","disconnected"])
            XCTAssertEqual(Set(frames.map { $0.input.status }), ["none","short","long","select"])
            XCTAssertEqual(Set(frames.map { $0.input.note }), ["none","busy","quit","rejection"])
            XCTAssertEqual(Set(frames.map { $0.input.lines }), [1,2,3])
            XCTAssertEqual(Set(frames.map { $0.input.details }), [false,true])
        }
        let routed = try wingModes()
        let renderer = try source("flow-bar/Sources/VoiceBarUI/VoiceBarNotchFeedback.swift")
        let noteBranch = try between(renderer, "if let note = feedback.noteText", "if let status = feedback.statusText")
        let noteHistoryWired = noteBranch.contains("onOpenHistory")
        let label = try XCTUnwrap(renderer.range(of: "private var label: some View")).lowerBound
        let fullTextLabel = String(renderer[label...])
        var errors = Dictionary(uniqueKeysWithValues: ["Current", "FixedText", "N1", "N2", "N3", "N4", "N5", "WingBounds", "Resident"].map { ($0, [String]()) })
        var heights: [Int: CGFloat] = [:]
        let resident = VoiceBarNotchPresentationModel()
        for row in corpus.rows {
            let input = try input(row)
            let p = VoiceBarPresentation.notchPresentation(from: input)
            let base = VoiceBarNotchContract.geometry(for: p.visualState).lowerSurfaceHeight
            let hasBand = p.geometry.lowerSurfaceHeight > base
            let candidateWing = p.feedback?.wingText ?? ""
            // Adaptation point (Lane A): BarView labels the compact-status wing through `wingLabel(for:)`, which is
            // empty while any notice shows (N1), including a plain short note that needs no feedback band.
            let visibleWing = p.visualState == .compactStatus && routed.contains(row.input.mode) ? p.wingLabel(for: input.statusText) : ""
            let actualText = p.feedback?.statusText.flatMap { $0.isEmpty ? nil : $0 } ?? (visibleWing.isEmpty ? "" : visibleWing)
            let expectedText = row.expected.text == "none" ? "" : copy(row.expected.text, lines: row.input.lines)
            let actualNote = p.feedback?.noteText ?? (p.transientNoteRect != nil ? input.transientNote : nil)
            let expectedNote = row.expected.transient ? input.transientNote : nil
            let needsBusy = row.expected.transient && row.input.note == "busy"
            let busyInline = p.feedback?.opensHistory == true && (p.feedback?.noteText == nil || noteHistoryWired)
            let inlineHistory = (needsBusy ? busyInline : p.feedback?.opensHistory == true)
            let tag = "\(row.policy)/\(row.input.mode)/\(row.input.status)/\(row.input.note)/\(row.input.lines)"
            resident.setHovered(input.isHovered)
            resident.setHistoryPanelOpen(input.isHistoryPanelOpen)
            resident.updateOperationalEnvelope(hasTeleprompter: p.visualState == .teleprompter,
                isRecording: input.mode == .recording, hasCompactStatus: p.visualState == .compactStatus,
                compactStatusLeadingWingWidth: p.geometry.leadingWingWidth, compactStatusTrailingWingWidth: p.geometry.trailingWingWidth,
                recordingLeadingWingWidth: p.geometry.leadingWingWidth, recordingTrailingWingWidth: p.geometry.trailingWingWidth,
                teleprompterLeadingWingWidth: input.mode == .speaking ? p.geometry.leadingWingWidth : nil,
                keepsIdleExpanded: input.mode == .idle && !input.isCollapsed, transientNoteWidth: p.transientNoteWidth, feedback: p.feedback)
            if resident.presentation != p { errors["Resident"]!.append(tag) }
            if p.geometry.leadingWingWidth > p.geometry.coreWidth || p.geometry.trailingWingWidth > p.geometry.coreWidth { errors["WingBounds"]!.append(tag) }
            if row.policy == "Current" {
                if String(describing: p.visualState) != row.expected.shell || hasBand != row.expected.band || actualText != expectedText ||
                    visibleWing != (row.expected.wingText == "none" ? "" : copy(row.expected.wingText, lines: row.input.lines)) || actualNote != expectedNote || inlineHistory != row.expected.historyInline {
                    errors["Current"]!.append(tag)
                }
                continue
            }
            // These constraints use production measurements/text/actions, not Project(Fixed)'s booleans.
            let notice = hasBand || (!visibleWing.isEmpty && !(input.mode == .idle && row.input.status == "none" && row.input.preview && row.input.note == "none"))
            let width = p.feedback?.width ?? p.transientNoteRect?.width ?? 0
            if p.geometry.leadingWingWidth > p.geometry.coreWidth || p.geometry.trailingWingWidth > p.geometry.coreWidth ||
                (notice && (!candidateWing.isEmpty || !visibleWing.isEmpty || width > p.geometry.topWidth)) { errors["N1"]!.append(tag) }
            if input.mode == .transcribing && (hasBand || p.feedback?.statusText != nil || p.feedback?.noteText != nil || p.transientNoteRect != nil) { errors["N2"]!.append(tag) }
            if actualText != expectedText || actualNote != expectedNote { errors["FixedText"]!.append(tag) } // Includes forbidden extra text when expected is none.
            if [p.feedback?.statusText ?? "", p.feedback?.noteText ?? "", candidateWing, visibleWing].contains(where: { ["Error", "Details below"].contains($0) }) { errors["N4"]!.append(tag) }
            if ((p.feedback?.statusText != nil && input.mode == .error) || (hasBand && row.input.note == "busy")) && !inlineHistory { errors["N5"]!.append(tag) }
            if let f = p.feedback {
                let requiredStatus = f.statusText.map { max(26, min(VoiceBarNotchFeedback.maximumTextHeight, VoiceBarNotchFeedback.textHeight($0, width: VoiceBarNotchFeedback.messageWidth(f.width, opensHistory: f.opensHistory))) + 10) } ?? 0
                let requiredNote = f.noteText.map { max(26, min(VoiceBarNotchFeedback.maximumTextHeight, VoiceBarNotchFeedback.textHeight($0, width: f.width - 32)) + 10) } ?? 0
                if f.statusHeight < requiredStatus || f.noteHeight < requiredNote || p.geometry.lowerSurfaceHeight - base < f.height { errors["N3"]!.append(tag) }
                if input.mode == .error && row.input.status == "short" && row.input.note == "none" && !row.input.history && !row.input.teleprompter { heights[row.input.lines] = f.height }
            }
        }
        if !fullTextLabel.contains(".lineLimit(nil)") || fullTextLabel.contains(".truncationMode") { errors["N3"]!.append("Full feedback label can truncate") }
        for line in 2...3 {
            let previous = try XCTUnwrap(heights[line - 1]); let current = try XCTUnwrap(heights[line])
            if current <= previous { errors["N3"]!.append("Line class \(line) did not grow down") }
        }
        check(errors["Current"]!, family: "Current projection (including absent text)", expectedFailure: contract.notchPolicy == "fixed")
        for family in ["FixedText", "N1", "N2", "N4", "N5"] { check(errors[family]!, family: family, expectedFailure: contract.notchPolicy == "current") }
        check(errors["Resident"]!, family: "Resident model agrees with real resolver", expectedFailure: false)
        check(errors["WingBounds"]!, family: "N1 numeric wing bounds in EVERY mode and BOTH corpora", expectedFailure: false)
        check(errors["N3"]!, family: "N3 real text geometry and untruncated renderer", expectedFailure: false)
        print("Replayed BOTH notch corpora: \(corpus.rows.count) frames; production ledger evaluated independently")
    }
    private func state() -> VoiceState {
        let state = VoiceState(recentTranscriptionsLoader: { [] }, recentTranscriptionsSaver: { _ in },
            recentTranscriptionEntriesLoader: { [] }, recentTranscriptionEntriesSaver: { _ in },
            transcriptionVocabularyLoader: { [] }, transcriptionVocabularyAliasLoader: { [] })
        state.controlLayerEventWriter = { _, _ in }; state.frontmostAppProvider = { nil }; state.isConnected = true
        return state
    }
    func testBothCauseEndingGraphEdgesAgainstRealVoiceState() throws {
        let corpus = try decode(NotchCorpus.self, corpusPath("notch-presentation"))
        let contract = try decode(Contract.self, "formal/runtime-contract.json")
        XCTAssertEqual(Set(corpus.lifecycle.map(\.policy)), ["Current", "Fixed"])
        for row in corpus.lifecycle {
            XCTAssertEqual(row.events, ["recording", "quit-refusal", "idle"])
            let state = state()
            for event in row.events {
                switch event { case "recording": state.mode = .recording; case "quit-refusal": state.reportQuitRefusal(); case "idle": state.mode = .idle; default: XCTFail("Unknown TLC event") }
            }
            check((state.selectionFeedbackNote != nil) == row.noteVisible ? [] : [row.policy], family: "\(row.policy) NoteHasCause", expectedFailure: row.policy.lowercased() != contract.notchPolicy)
        }
    }
    func testBothPipelineGraphPathsAgainstNativeRouterAndDelivery() async throws {
        let corpus = try decode(PipelineCorpus.self, corpusPath("record-while-processing"))
        let contract = try decode(Contract.self, "formal/runtime-contract.json")
        try verifyModel(corpus.modelSHA256, path: "formal/record-while-processing/RecordWhileProcessing.tla")
        XCTAssertEqual(Set(corpus.native.map(\.policy)), ["Current", "Fixed"])
        for policy in ["Current", "Fixed"] {
            XCTAssertEqual(Set(corpus.native.filter { $0.policy == policy }.map(\.kind)), ["F5","click","Escape","delivery"])
        }
        var errors: [String: [String]] = ["Current": [], "Fixed": []]
        for row in corpus.native {
            let state = state(); var commands: [[String: Any]] = []
            state.sendCommand = { commands.append($0) }
            if row.kind == "delivery" {
                state.minimumTranscribingDisplayDuration = 0.01
                for step in try XCTUnwrap(row.trace) {
                    let id = contract.captureIds[step.target] ?? 0
                    switch step.event {
                    case "F5", "socket": state.handleEvent(["type": "state", "state": "recording", "bar_owned": false, contract.cancelIdField: id])
                    case "decode": state.handleEvent(["type": "state", "state": "transcribing", contract.cancelIdField: id])
                    case "result": state.handleEvent(["type": "transcription", "text": "Synthetic final \(step.target)", contract.cancelIdField: id])
                    default: break
                    }
                }
                try await Task.sleep(for: .milliseconds(100))
                if Set(state.recentTranscriptionEntries.map(\.text)) != Set(try XCTUnwrap(row.delivered).map { "Synthetic final \($0)" }) { errors[row.policy]!.append("delivery graph") }
            } else {
                state.handleEvent(["type": "state", "state": "transcribing", contract.cancelIdField: try XCTUnwrap(contract.captureIds["A"])])
                let router = VoiceBarCommandRouter(voiceState: state)
                switch row.kind { case "F5": router.handleHotkeyHoldStart(); case "click": router.handleCancel(); case "Escape": router.handleEscape(); default: XCTFail("Unknown graph action") }
                let expected = try XCTUnwrap(row.command)
                if commands.compactMap({ $0["cmd"] as? String }) != (expected == "none" ? [] : [expected]) { errors[row.policy]!.append(row.kind) }
                if row.policy == "Fixed", expected == "cancel", commands.last?[contract.cancelIdField] as? Int != contract.captureIds[try XCTUnwrap(row.take)] { errors[row.policy]!.append("\(row.kind) missing take id") }
            }
        }
        for policy in ["Current", "Fixed"] { check(errors[policy]!, family: "\(policy) native graph paths", expectedFailure: policy.lowercased() != contract.pipelinePolicy) }
        print("Replayed BOTH pipeline native corpora: \(corpus.native.count) graph-derived paths")
    }
}
