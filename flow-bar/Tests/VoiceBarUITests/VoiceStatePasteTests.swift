import AppKit
@testable import VoiceBarUI
import XCTest

final class VoiceStatePasteTests: XCTestCase {
    private static let guardedTerminals: Set<String> = [
        "com.cmuxterm.app", "com.apple.Terminal", "com.googlecode.iterm2",
        "com.mitchellh.ghostty", "net.kovidgoyal.kitty", "com.github.wez.wezterm", "org.alacritty",
    ]

    func testGuardedTerminalTypingReceivesPIDAndDeclinesWithoutManualFallback() {
        for bundle in Self.guardedTerminals.sorted() {
            for source in ["auto", "settings_history"] {
                for result in [GuardedTypingResult.focusChanged, .failed] {
                    let harness = TerminalDelayHarness(bundle: bundle)
                    var receivedPIDs: [pid_t] = []
                    harness.state.guardedTextTypingHandler = { text, pid in
                        XCTAssertEqual(text, TerminalDelayHarness.delivered)
                        receivedPIDs.append(pid)
                        return result
                    }
                    harness.begin(source: source)
                    harness.activateThenMoveFocus(to: .unchanged)
                    harness.deliver()
                    XCTAssertEqual(receivedPIDs, [51515], "\(bundle), \(source)")
                    XCTAssertEqual(harness.typed, [], "A declined guarded post must never retry manually")
                    XCTAssertEqual(harness.outcomes.count, 1)
                    if result == .focusChanged {
                        XCTAssertEqual(harness.outcomes, ["notInserted"])
                        if source == "auto" { XCTAssertEqual(harness.state.latestDictationInsertionStatus, .notInserted) }
                        XCTAssertTrue(harness.state.confirmationText?.contains("In History") == true)
                    } else {
                        XCTAssertTrue(harness.state.confirmationText?.contains("Paste failed") == true)
                    }
                    harness.assertRetainedWithoutSideEffects(bundle)
                }
            }
        }
    }

    /// MICDROP2: the partial transcript still pastes, and the pill then says why it is short.
    func testMicDisconnectNoticeOutlastsThePastedTranscript() {
        let harness = TerminalDelayHarness(bundle: "com.cmuxterm.app")
        harness.state.record()
        harness.state.handleEvent([
            "type": "mic_disconnected", "at_ms": 42400, "reason": "device-removed",
            "message": "Mic disconnected at 0:42",
        ])
        XCTAssertEqual(harness.state.confirmationText, MicDisconnectFeedback.pill(atMs: 42400))
        harness.begin(source: "auto")
        harness.activateThenMoveFocus(to: .unchanged)
        harness.deliver()
        XCTAssertEqual(harness.typed, [TerminalDelayHarness.delivered], "the partial transcript is still delivered")
        XCTAssertEqual(harness.state.confirmationText, "Mic lost\nat 0:42")
        XCTAssertTrue(TwoLineStatusFeedback.contains(harness.state.confirmationText))

        // Consumed once: the next dictation's paste shows its own words.
        harness.state.handleEvent(["type": "state", "state": "recording", "bar_owned": true])
        XCTAssertNil(harness.state.pendingMicDisconnectNotice)
    }

    func testOtherManualTerminalRoutesNeverReceiveAPID() {
        for source in ["context_menu_latest", "context_menu_history", "menu_bar", "bar_history", "local_control", "unknown"] {
            let harness = TerminalDelayHarness(bundle: "com.cmuxterm.app")
            harness.begin(source: source)
            harness.activateThenMoveFocus(to: .unchanged)
            harness.deliver()
            harness.assertOneTypedDelivery(source)
        }
    }

    func testAllTerminalsRejectAutomaticAndHistoryDeliveryWhenFocusChangesDuringDelay() {
        XCTAssertEqual(Self.guardedTerminals, TerminalPasteTargets.bundleIdentifiers)
        for bundle in Self.guardedTerminals.sorted() {
            for source in ["auto", "settings_history"] {
                for focus in TerminalDelayHarness.Focus.allCases where focus != .unchanged {
                    let harness = TerminalDelayHarness(bundle: bundle)
                    let context = "\(bundle), \(source), \(focus)"
                    harness.begin(source: source)
                    harness.activateThenMoveFocus(to: focus)
                    harness.deliver()

                    XCTAssertEqual(harness.typed, [], context)
                    XCTAssertEqual(harness.outcomes, ["notInserted"], context)
                    if source == "auto" {
                        XCTAssertEqual(harness.state.latestDictationInsertionStatus, .notInserted, context)
                    }
                    XCTAssertTrue(harness.state.confirmationText?.contains("Not pasted") == true, context)
                    XCTAssertTrue(harness.state.confirmationText?.contains("In History") == true, context)
                    harness.assertRetainedWithoutSideEffects(context)
                }
            }
        }
    }

    func testAllTerminalsKeepFocusedAutomaticAndHistoryDeliveryUnchanged() {
        for bundle in Self.guardedTerminals.sorted() {
            for source in ["auto", "settings_history"] {
                let harness = TerminalDelayHarness(bundle: bundle)
                let context = "\(bundle), \(source)"
                harness.begin(source: source)
                harness.activateThenMoveFocus(to: .unchanged)
                harness.deliver()
                harness.assertOneTypedDelivery(context)
                if source == "auto" {
                    XCTAssertEqual(harness.state.latestDictationInsertionStatus, .unverified, context)
                }
            }
        }
    }

    func testAllTerminalsKeepShiftF5DeliveryAfterAnyDeliveryDelayFocusChange() {
        for bundle in Self.guardedTerminals.sorted() {
            for focus in TerminalDelayHarness.Focus.allCases {
                let harness = TerminalDelayHarness(bundle: bundle)
                let context = "\(bundle), shift_f5, \(focus)"
                harness.begin(source: "shift_f5")
                harness.activateThenMoveFocus(to: focus)
                harness.deliver()
                harness.assertOneTypedDelivery(context)
            }
        }
    }

    /// Uses the real delivery scheduler seam; never posts native keys or touches a real clipboard.
    private final class TerminalDelayHarness {
        enum Focus: CaseIterable { case unchanged, sameBundleNewPID, otherApp, unavailable }
        static let raw = "ADD שלום 👩‍💻\nsecond line\n"
        static let delivered = "ADD שלום 👩‍💻\nsecond line"
        let state = VoiceState(
            recentTranscriptionsLoader: { [] }, recentTranscriptionsSaver: { _ in },
            recentTranscriptionEntriesLoader: { [] }, recentTranscriptionEntriesSaver: { _ in }
        )
        let target: FakeRunningApplication
        var front: NSRunningApplication?
        var scheduled: [() -> Void] = []
        var activated: [pid_t] = []
        var typed: [String] = []
        var keystrokes: [[SynthesizedKeystroke]] = []
        var outcomes: [String] = []
        var axAttempts = 0
        var clipboardWrites: [String] = []
        var clipboard = "COPIED BEFORE DICTATION"
        var guardedPIDs: [pid_t] = []
        var source = ""

        init(bundle: String) {
            target = FakeRunningApplication(bundleIdentifier: bundle, processIdentifier: 51515)
            front = target
            state.sendCommand = { _ in }
            state.minimumTranscribingDisplayDuration = 0
            state.pasteConfirmationDelay = 0.25
            state.frontmostAppProvider = { [unowned self] in front }
            state.targetAppActivator = { [unowned self] in activated.append($0.processIdentifier) }
            state.pasteScheduler = { [unowned self] _, work in scheduled.append(work) }
            state.focusedTargetEligibilityProvider = { XCTFail("Terminals must not gain an AX eligibility probe"); return nil }
            state.asyncDictationInsertionHandlerProvider = { [unowned self] in
                { [unowned self] _, _ in axAttempts += 1; return false }
            }
            state.textTypingHandler = { [unowned self] in
                typed.append($0)
                keystrokes.append(SynthesizedTyping.keystrokes(for: $0))
                return true
            }
            state.guardedTextTypingHandler = { [unowned self] text, pid in
                guardedPIDs.append(pid)
                return state.textTypingHandler(text) ? .posted : .failed
            }
            state.pasteboardWriter = { [unowned self] in clipboardWrites.append($0); clipboard = $0 }
            state.pasteboardStringProvider = { [unowned self] in clipboard }
            state.simulatedPasteHandler = { XCTFail("No Cmd+V fallback"); return false }
            state.diagnosticLogger = { [unowned self] event, details in
                if event == "paste_confirmation", let outcome = details["outcome"] { outcomes.append(outcome) }
            }
        }

        func begin(source: String) {
            self.source = source
            if source == "auto" { state.record() }
            state.handleEvent(["type": "transcription", "text": Self.raw])
            if source == "settings_history" { state.captureSettingsHistoryPasteTarget() }
            if source != "auto" { state.repasteLastTranscript(source: source) }
            XCTAssertEqual(typed, [])
            XCTAssertEqual(outcomes, [])
        }

        func activateThenMoveFocus(to focus: Focus) {
            XCTAssertEqual(scheduled.count, 1)
            guard !scheduled.isEmpty else { return }
            scheduled.removeFirst()()
            XCTAssertEqual(activated, [51515])
            XCTAssertEqual(scheduled.count, 1, "Delivery must still be pending after activation")
            XCTAssertEqual(typed, [])
            switch focus {
            case .unchanged: break
            case .sameBundleNewPID: front = FakeRunningApplication(bundleIdentifier: target.bundleIdentifier, processIdentifier: 62626)
            case .otherApp: front = FakeRunningApplication(bundleIdentifier: "com.example.Other", processIdentifier: 73737)
            case .unavailable: front = nil
            }
        }

        func deliver() {
            guard !scheduled.isEmpty else { XCTFail("Missing delivery callback"); return }
            scheduled.removeFirst()()
        }

        func assertRetainedWithoutSideEffects(_ context: String) {
            XCTAssertEqual(axAttempts, 0, context)
            XCTAssertEqual(clipboardWrites, [], context)
            XCTAssertEqual(clipboard, "COPIED BEFORE DICTATION", context)
            XCTAssertTrue(scheduled.isEmpty, "No duplicate or retry: \(context)")
            // The existing transcription event boundary trims outer whitespace, before delivery.
            XCTAssertEqual(state.transcript, Self.delivered, context)
            XCTAssertEqual(state.latestReusableTranscript, Self.delivered, context)
            XCTAssertEqual(state.recentTranscriptions, [Self.delivered], context)
            XCTAssertEqual(state.recentTranscriptionEntries.map(\.text), [Self.delivered], context)
        }

        func assertOneTypedDelivery(_ context: String) {
            XCTAssertEqual(guardedPIDs, ["auto", "settings_history"].contains(source) ? [51515] : [], context)
            XCTAssertEqual(typed, [Self.delivered], context)
            XCTAssertEqual(keystrokes, [[.text("ADD שלום 👩‍💻"), .newline, .text("second line")]], context)
            XCTAssertEqual(outcomes, ["unverified"], context)
            XCTAssertEqual(state.confirmationText, Self.delivered, context)
            assertRetainedWithoutSideEffects(context)
        }
    }

    private func deliveryState(bundleIdentifier: String) -> VoiceState {
        let state = VoiceState()
        let editor = FakeRunningApplication(bundleIdentifier: bundleIdentifier, processIdentifier: 51515)
        state.sendCommand = { _ in }
        state.minimumTranscribingDisplayDuration = 0
        state.pasteConfirmationDelay = 0
        state.frontmostAppProvider = { editor }
        state.targetAppActivator = { _ in }
        state.pasteScheduler = { _, work in work() }
        return state
    }

    func testSettingsHistoryAXDeclineNeedsEditableSameElementEligibility() {
        let text = "ADD שלום 👩‍💻\nsecond line"
        for reason in ["editable", "file_list", "readonly", "secure", "unknown", "wrong_pid", "focus_changed"] {
            for hasAXHandler in [true, false] {
                let state = deliveryState(bundleIdentifier: "com.apple.finder")
                var focused = true
                var typed: [String] = []
                state.focusedTargetEligibilityProvider = {
                    guard reason != "unknown" else { return nil }
                    return DictationFocusedTargetEligibility(
                        processIdentifier: reason == "wrong_pid" ? 62626 : 51515,
                        role: reason == "file_list" ? "AXOutline" : "AXTextField",
                        isEditable: reason != "readonly", isSecure: reason == "secure",
                        matchesCurrentFocus: { focused }
                    )
                }
                state.asyncDictationInsertionHandlerProvider = {
                    guard hasAXHandler else { return nil }
                    return { _, _ in
                        if reason == "focus_changed" { focused = false }
                        return false // No setter and no completion.
                    }
                }
                if !hasAXHandler && reason == "focus_changed" { focused = false }
                state.textTypingHandler = { typed.append($0); return true }
                state.pasteboardWriter = { _ in XCTFail("Do not touch clipboard: \(reason)") }
                state.handleEvent(["type": "transcription", "text": text])
                state.captureSettingsHistoryPasteTarget()
                state.repasteTranscript(text, source: "settings_history")
                XCTAssertEqual(typed, reason == "editable" ? [text] : [], "\(reason), AX: \(hasAXHandler)")
                XCTAssertEqual(state.latestReusableTranscript, text, reason)
                if reason != "editable" {
                    XCTAssertTrue(state.confirmationText?.contains("Not pasted") == true, reason)
                    XCTAssertTrue(state.confirmationText?.contains("In History") == true, reason)
                }
            }
        }
    }

    func testOtherExplicitEntryPointsRetainUnknownFocusWhileShiftF5IsUnchanged() {
        let text = "ADD שלום 👩‍💻\nsecond line"
        for source in ["context_menu_latest", "context_menu_history", "menu_bar", "bar_history", "local_control", "unknown", "shift_f5"] {
            let state = deliveryState(bundleIdentifier: "com.example.Editor")
            var typed: [String] = []
            state.focusedTargetEligibilityProvider = {
                if source == "shift_f5" { XCTFail("Shift+F5 must not probe eligibility") }
                return nil
            }
            state.textTypingHandler = { typed.append($0); return true }
            state.pasteboardWriter = { _ in XCTFail("Keep clipboard") }
            state.repasteTranscript(text, source: source)
            XCTAssertEqual(typed, source == "shift_f5" ? [text] : [], source)
        }
    }

    func testExplicitDeliveryRejectsPIDChangeDuringDelayAndKeepsAllWords() {
        for source in ["settings_history", "context_menu_history"] {
            let state = deliveryState(bundleIdentifier: "com.example.Editor")
            let text = "ADD שלום 👩‍💻\nsecond line"
            var queued: [() -> Void] = []
            state.pasteScheduler = { _, work in queued.append(work) }
            state.focusedTargetEligibilityProvider = {
                DictationFocusedTargetEligibility(processIdentifier: 51515, role: "AXTextField",
                                                   isEditable: true, isSecure: false, matchesCurrentFocus: { true })
            }
            state.asyncDictationInsertionHandlerProvider = { { _, _ in false } }
            state.textTypingHandler = { _ in XCTFail("Changed PID must not receive text"); return false }
            state.pasteboardWriter = { _ in XCTFail("Keep clipboard") }
            state.handleEvent(["type": "transcription", "text": text])
            state.repasteTranscript(text, source: source)
            queued.removeFirst()()
            state.frontmostAppProvider = { FakeRunningApplication(bundleIdentifier: "com.example.Editor", processIdentifier: 62626) }
            queued.removeFirst()()
            XCTAssertEqual(state.latestReusableTranscript, text)
            XCTAssertTrue(state.confirmationText?.contains("Not pasted") == true, source)
        }
    }

    func testKnownRichHostsAndEveryTerminalBypassNewEligibilityForAllDeliveryPlans() {
        let text = "ADD שלום 👩‍💻\nsecond line"
        for bundle in TerminalPasteTargets.bundleIdentifiers.union(["com.t3tools.t3code", "net.imput.helium"]) {
            let state = deliveryState(bundleIdentifier: bundle)
            var typed: [String] = []
            state.focusedTargetEligibilityProvider = { XCTFail("Preserve known host: \(bundle)"); return nil }
            state.textTypingHandler = { typed.append($0); return true }
            state.pasteboardWriter = { _ in XCTFail("Keep clipboard: \(bundle)") }
            state.record()
            state.handleEvent(["type": "transcription", "text": text])
            state.repasteTranscript(text, source: "settings_history")
            state.repasteLastTranscript(source: "shift_f5")
            state.repasteTranscript(text, source: "context_menu_history")
            XCTAssertEqual(typed, [text, text, text, text], bundle)
            XCTAssertEqual(state.latestReusableTranscript, text, bundle)
            if TerminalPasteTargets.isTerminal(bundle) { XCTAssertEqual(state.confirmationText, text, bundle) }
        }
    }

    func testAutomaticMissStillRetainsEvenWithEditableEligibility() {
        let state = deliveryState(bundleIdentifier: "com.example.Editor")
        state.focusedTargetEligibilityProvider = {
            DictationFocusedTargetEligibility(processIdentifier: 51515, role: "AXTextField",
                                               isEditable: true, isSecure: false, matchesCurrentFocus: { true })
        }
        state.asyncDictationInsertionHandlerProvider = { { _, _ in false } }
        state.textTypingHandler = { _ in XCTFail("Auto miss is not a manual request"); return false }
        state.record()
        state.handleEvent(["type": "transcription", "text": "retain complete text"])
        XCTAssertEqual(state.latestDictationInsertionStatus, .notInserted)
        XCTAssertEqual(state.latestReusableTranscript, "retain complete text")
    }

    func testSettingsHistoryPossibleWriteNeverFallsThroughEvenWithEditableEligibility() {
        for result: DictationInsertionResult in [.notApplied, .appliedUnverified, .partiallyApplied, .verified] {
            for started in [true, false] {
                let state = deliveryState(bundleIdentifier: "com.example.Editor")
                var attempts = 0
                state.focusedTargetEligibilityProvider = {
                    DictationFocusedTargetEligibility(processIdentifier: 51515, role: "AXTextField",
                                                       isEditable: true, isSecure: false, matchesCurrentFocus: { true })
                }
                state.asyncDictationInsertionHandlerProvider = { { _, completion in
                    attempts += 1
                    completion(result)
                    return started
                } }
                state.textTypingHandler = { _ in XCTFail("Completion consumes the attempt: \(result)"); return false }
                state.pasteboardWriter = { _ in XCTFail("Keep clipboard") }
                state.repasteTranscript("preserve all words", source: "settings_history")
                XCTAssertEqual(attempts, 1)
            }
        }
    }

    func testFinderDeliveryRetainsTranscriptAndSelectionAfterRecordStartInT3() {
        let state = deliveryState(bundleIdentifier: "com.t3tools.t3code")
        let finder = FakeRunningApplication(bundleIdentifier: "com.apple.finder", processIdentifier: 62626)
        let text = "Okay, yeah, it went to the cursor for some reason, let me go somewhere else."
        let selectedFile = "disposable-fixture-file"
        var selection = selectedFile
        state.asyncDictationInsertionHandlerProvider = { { _, _ in false } }
        state.focusedTargetEligibilityProvider = {
            DictationFocusedTargetEligibility(processIdentifier: 62626, role: "AXOutline",
                                               isEditable: false, isSecure: false, matchesCurrentFocus: { true })
        }
        state.textTypingHandler = { _ in selection = "changed"; XCTFail("Do not navigate Finder"); return true }
        state.pasteboardWriter = { _ in XCTFail("Keep clipboard") }
        state.record()
        state.frontmostAppProvider = { finder }
        state.handleEvent(["type": "transcription", "text": text])
        XCTAssertEqual(selection, selectedFile)
        XCTAssertEqual(state.latestDictationInsertionStatus, .notInserted)
        XCTAssertEqual(state.latestReusableTranscript, text)
        XCTAssertTrue(state.confirmationText?.contains("In History") == true)
    }

    func testShiftF5T3MultilineRecoveryKeepsExistingTypedDelivery() {
        let state = deliveryState(bundleIdentifier: "com.t3tools.t3code")
        let text = "ship it @main\nnext\n/plan"
        var typed: [String] = []
        state.asyncDictationInsertionHandlerProvider = { XCTFail("Shift+F5 must keep its typed route"); return nil }
        state.textTypingHandler = { typed.append($0); return true }
        state.pasteboardWriter = { _ in XCTFail("Shift+F5 must preserve the clipboard") }
        state.repasteTranscript(text, source: "shift_f5")
        XCTAssertEqual(typed, [text])
        XCTAssertTrue(state.confirmationText?.contains("Unverified") == true)
        // Host menu consumption is NOT_PROVEN here; the booked native script checks it.
    }

    func testAutomaticT3AndHeliumDeliveryUsesTheShiftF5TypedPlanWithoutAXOrClipboard() {
        let text = "ADD שלום 👩‍💻\nsecond line\nship it @main\n/plan"
        for bundle in ["com.t3tools.t3code", "net.imput.helium"] {
            let state = deliveryState(bundleIdentifier: bundle)
            var axAttempts = 0
            var typed: [String] = []
            var plans: [[SynthesizedKeystroke]] = []
            state.asyncDictationInsertionHandlerProvider = { { _, _ in axAttempts += 1; return false } }
            state.textTypingHandler = {
                typed.append($0)
                plans.append(SynthesizedTyping.keystrokes(for: $0))
                return true
            }
            state.pasteboardWriter = { _ in XCTFail("Known rich hosts must never write the clipboard") }
            state.record()
            state.handleEvent(["type": "transcription", "text": text])
            XCTAssertEqual(state.latestDictationInsertionStatus, .unverified, bundle)
            state.repasteLastTranscript(source: "shift_f5")
            XCTAssertEqual(typed, [text, text], "One auto delivery and one explicit recovery, no fallback duplicate: \(bundle)")
            let expected = SynthesizedTyping.keystrokes(for: text)
            XCTAssertEqual(plans, [expected, expected], bundle)
            XCTAssertEqual(expected.filter { $0 == .newline }.count, 3)
            XCTAssertEqual(axAttempts, 0, "Both fresh and captured AX handlers must be bypassed: \(bundle)")
            XCTAssertEqual(state.latestReusableTranscript, text, bundle)
        }
    }

    func testSettingsHistoryT3AndHeliumUsesOneTypedDeliveryWithoutAXOrClipboard() {
        let text = "ADD שלום 👩‍💻\nsecond line\nship it @main\n/plan"
        for bundle in ["com.t3tools.t3code", "net.imput.helium"] {
            for capturesTarget in [true, false] {
                let state = deliveryState(bundleIdentifier: bundle)
                let context = "\(bundle), captured target: \(capturesTarget)"
                var axAttempts = 0
                var typed: [String] = []
                var clipboardWrites: [String] = []
                state.asyncDictationInsertionHandlerProvider = {
                    { _, completion in
                        axAttempts += 1
                        // The live rich-host adapter starts and completes .notApplied.
                        completion(.notApplied)
                        return true
                    }
                }
                state.textTypingHandler = { typed.append($0); return true }
                state.pasteboardWriter = { clipboardWrites.append($0) }
                state.simulatedPasteHandler = { XCTFail("History must type without Cmd+V: \(context)"); return false }
                if capturesTarget { state.captureSettingsHistoryPasteTarget() }

                state.repasteTranscript(text, source: "settings_history")

                XCTAssertEqual(typed, [text], "Exactly one delivery, no fallback duplicate: \(context)")
                XCTAssertEqual(axAttempts, 0, "Bypass both captured and fresh AX: \(context)")
                XCTAssertEqual(clipboardWrites, [], context)
                XCTAssertTrue(state.confirmationText?.contains("Unverified") == true, context)
            }
        }
    }

    func testT3AndHeliumOtherRepasteEntryPointsKeepTypedDeliveryWithoutAXOrClipboard() {
        let text = "ADD שלום 👩‍💻\nsecond line"
        let latestSources = ["shift_f5", "context_menu_latest", "menu_bar", "local_control"]
        let historySources = ["context_menu_history", "bar_history", "unknown"]
        for bundle in ["com.t3tools.t3code", "net.imput.helium"] {
            for source in latestSources + historySources {
                let state = deliveryState(bundleIdentifier: bundle)
                var typed: [String] = []
                state.asyncDictationInsertionHandlerProvider = { { _, completion in
                    XCTFail("Re-paste must bypass AX: \(bundle), \(source)")
                    completion(.notApplied)
                    return true
                } }
                state.textTypingHandler = { typed.append($0); return true }
                state.pasteboardWriter = { _ in XCTFail("Keep the clipboard: \(bundle), \(source)") }
                state.handleEvent(["type": "transcription", "text": text])
                if latestSources.contains(source) {
                    state.repasteLastTranscript(source: source)
                } else {
                    state.repasteTranscript(text, source: source)
                }
                XCTAssertEqual(typed, [text], "\(bundle), \(source)")
                XCTAssertEqual(state.latestReusableTranscript, text)
                XCTAssertTrue(state.confirmationText?.contains("Unverified") == true)
            }
        }
    }

    func testFocusChangeDuringDeliveryDelayPostsNoTextAndRetainsTranscript() {
        let state = deliveryState(bundleIdentifier: "com.t3tools.t3code")
        var queued: [() -> Void] = []
        state.pasteScheduler = { _, work in queued.append(work) }
        state.asyncDictationInsertionHandlerProvider = { { _, _ in XCTFail("Do not dispatch after PID change"); return false } }
        state.textTypingHandler = { _ in XCTFail("Do not type after PID change"); return false }
        state.record()
        state.handleEvent(["type": "transcription", "text": "retain all words"])
        queued.removeFirst()()
        state.frontmostAppProvider = { FakeRunningApplication(bundleIdentifier: "com.t3tools.t3code", processIdentifier: 62626) }
        queued.removeFirst()()
        XCTAssertEqual(state.latestDictationInsertionStatus, .notInserted)
        XCTAssertEqual(state.latestReusableTranscript, "retain all words")
    }

    func testWatchdogTimeoutAfterStartedWriteIsUnverifiedNotFailed() {
        let state = deliveryState(bundleIdentifier: "com.example.Editor")
        state.axInsertionCompletionTimeout = 0.01
        var complete: ((DictationInsertionResult) -> Void)?
        state.asyncDictationInsertionHandlerProvider = { { _, completion in complete = completion; return true } }
        state.textTypingHandler = { _ in XCTFail("Never retry a timed-out write"); return false }
        state.record()
        state.handleEvent(["type": "transcription", "text": "full retained transcript"])
        let timedOut = expectation(description: "Started write times out without declaring failure")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            XCTAssertEqual(state.latestDictationInsertionStatus, .unverified)
            complete?(.verified)
            XCTAssertEqual(state.latestDictationInsertionStatus, .unverified)
            XCTAssertEqual(state.latestReusableTranscript, "full retained transcript")
            timedOut.fulfill()
        }
        wait(for: [timedOut], timeout: 1)
    }

    func testAppliedUnverifiedAXDoesNotClaimInsertedAtCursorOrRetryWholeTranscript() {
        for result: DictationInsertionResult in [.appliedUnverified, .partiallyApplied, .notApplied] {
            let state = deliveryState(bundleIdentifier: "com.example.Editor")
            var attempts = 0
            state.asyncDictationInsertionHandlerProvider = {
                { _, completion in attempts += 1; completion(result); return false }
            }
            state.textTypingHandler = { _ in XCTFail("No duplicate fallback after completion"); return false }
            state.pasteboardWriter = { _ in XCTFail("Keep the raw clipboard") }
            state.record()
            state.handleEvent(["type": "transcription", "text": "ADD שלום 👩‍💻\nsecond line"])
            XCTAssertEqual(attempts, 1)
            XCTAssertEqual(state.latestDictationInsertionStatus, result == .notApplied ? .notInserted : .unverified)
            XCTAssertEqual(state.latestReusableTranscript, "ADD שלום 👩‍💻\nsecond line")
            XCTAssertTrue(state.confirmationText?.contains("History") == true)
        }
    }

    func testLegacyAXCompletionDoesNotClaimVerifiedCursor() {
        let state = deliveryState(bundleIdentifier: "com.example.Editor")
        state.dictationInsertionHandlerProvider = { { _ in true } }
        state.record()
        state.handleEvent(["type": "transcription", "text": "ADD שלום 👩‍💻\nsecond line"])
        XCTAssertEqual(state.latestDictationInsertionStatus, .unverified)
        XCTAssertEqual(state.latestReusableTranscript, "ADD שלום 👩‍💻\nsecond line")
    }

    func testAutoPasteUnknownEditorRetainsTranscriptWithoutTyping() {
        let state = deliveryState(bundleIdentifier: "com.example.UnknownEditor")
        state.dictationInsertionHandlerProvider = { nil }
        state.asyncDictationInsertionHandlerProvider = { nil }
        var typed: [String] = []
        state.textTypingHandler = { typed.append($0); return true }
        state.pasteboardWriter = { _ in XCTFail("Delivery must preserve the clipboard") }
        state.record()
        state.handleEvent(["type": "transcription", "text": "ADD שלום 👩‍💻\nsecond line"])
        XCTAssertEqual(typed, [])
        XCTAssertEqual(state.latestDictationInsertionStatus, .notInserted)
        XCTAssertEqual(state.latestReusableTranscript, "ADD שלום 👩‍💻\nsecond line")
    }

    private static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
    private static let autoGeneratedType = NSPasteboard.PasteboardType("org.nspasteboard.AutoGeneratedType")

    final class FakeRunningApplication: NSRunningApplication, @unchecked Sendable {
        private let fakeBundleIdentifier: String?
        private let fakeProcessIdentifier: pid_t

        init(bundleIdentifier: String?, processIdentifier: pid_t) {
            fakeBundleIdentifier = bundleIdentifier
            fakeProcessIdentifier = processIdentifier
            super.init()
        }

        override var bundleIdentifier: String? {
            fakeBundleIdentifier
        }

        override var processIdentifier: pid_t {
            fakeProcessIdentifier
        }
    }

    func testLoadsPersistedRecentTranscriptionsOnInit() {
        let state = VoiceState(
            recentTranscriptionsLoader: {
                [
                    "persisted latest",
                    "persisted older",
                ]
            },
            recentTranscriptionEntriesLoader: { [] },
            recentTranscriptionEntriesSaver: { _ in },
            transcriptionVocabularyLoader: {
                ["VoiceLayer", "Wispr Flow"]
            },
            transcriptionVocabularyAliasLoader: {
                [STTVocabularyAliasPreview(from: "sample agent", to: "sampleAgent")]
            }
        )

        XCTAssertEqual(state.recentTranscriptions, [
            "persisted latest",
            "persisted older",
        ])
        XCTAssertEqual(state.transcriptionVocabularyTerms, ["VoiceLayer", "Wispr Flow"])
        XCTAssertEqual(state.transcriptionVocabularyAliases, [
            STTVocabularyAliasPreview(from: "sample agent", to: "sampleAgent"),
        ])
    }

    func testFinalTranscriptionPersistsRecentTranscriptions() {
        var savedSnapshots: [[String]] = []
        let state = VoiceState(
            recentTranscriptionsLoader: { [] },
            recentTranscriptionsSaver: { savedSnapshots.append($0) },
            recentTranscriptionEntriesLoader: { [] },
            recentTranscriptionEntriesSaver: { _ in }
        )

        state.handleEvent([
            "type": "transcription",
            "text": "persist this transcript",
        ])

        XCTAssertEqual(savedSnapshots.last, ["persist this transcript"])
    }

    func testFinalTranscriptionHistoryAccessoryRequestsPanelLayoutRefresh() {
        let state = VoiceState(
            recentTranscriptionsLoader: { [] },
            recentTranscriptionsSaver: { _ in },
            recentTranscriptionEntriesLoader: { [] },
            recentTranscriptionEntriesSaver: { _ in },
            transcriptionVocabularyLoader: { [] },
            transcriptionVocabularyAliasLoader: { [] }
        )

        assertVoiceStateEventTriggersPanelLayoutRefresh(
            [
                "type": "transcription",
                "text": "new idle history item",
            ],
            state: state
        )
    }

    func testFinalTranscriptionVocabularyAccessoryRequestsPanelLayoutRefresh() {
        var vocabularyTerms: [String] = []
        var vocabularyAliases: [STTVocabularyAliasPreview] = []
        let state = VoiceState(
            recentTranscriptionsLoader: { ["already visible history"] },
            recentTranscriptionsSaver: { _ in },
            recentTranscriptionEntriesLoader: { [] },
            recentTranscriptionEntriesSaver: { _ in },
            transcriptionVocabularyLoader: { vocabularyTerms },
            transcriptionVocabularyAliasLoader: { vocabularyAliases }
        )
        vocabularyTerms = ["VoiceLayer"]
        vocabularyAliases = [STTVocabularyAliasPreview(from: "sample agent", to: "sampleAgent")]

        assertVoiceStateEventTriggersPanelLayoutRefresh(
            [
                "type": "transcription",
                "text": "refresh vocabulary",
            ],
            state: state
        )
    }

    func testRecordLeavesModeIdleUntilDaemonStateArrives() {
        let state = VoiceState()
        var sentCommand: [String: Any]?
        var modeObservedInsideSend: VoiceMode?
        var callbackModes: [VoiceMode] = []

        state.sendCommand = { command in
            sentCommand = command
            modeObservedInsideSend = state.mode
        }
        state.onModeChange = { mode in
            callbackModes.append(mode)
        }

        state.record()

        XCTAssertEqual(state.mode, .idle)
        XCTAssertEqual(sentCommand?["cmd"] as? String, "record")
        XCTAssertNotNil(sentCommand?["id"] as? String)
        XCTAssertEqual(modeObservedInsideSend, .idle)
        XCTAssertTrue(callbackModes.isEmpty)
    }

    func testSnoozeMovesVoiceStateToDisconnected() {
        let state = VoiceState()

        state.snooze()

        XCTAssertEqual(state.mode, .disconnected)
    }

    func testUnsnoozeReturnsVoiceStateToIdle() {
        let state = VoiceState()
        state.setConnectionStatus(true)
        state.snooze()

        state.unsnooze()

        XCTAssertEqual(state.mode, .idle)
    }

    func testUnsnoozeClearsPasteFlowEnvelopeAndRequestsPanelRelayout() async {
        let state = VoiceState()
        state.snooze()
        XCTAssertTrue(state.keepsPasteFlowEnvelope)
        var relayoutCount = 0
        state.onPanelLayoutChange = {
            relayoutCount += 1
        }

        state.unsnooze()
        try? await Task.sleep(for: .milliseconds(30))

        XCTAssertFalse(state.keepsPasteFlowEnvelope)
        XCTAssertGreaterThanOrEqual(relayoutCount, 1)
    }

    func testModalInteractionSuppressesIdleCollapseAndRestoresExpandedState() async {
        let state = VoiceState()
        state.idleCollapseDelay = 0.01
        state.mode = .idle

        state.beginModalInteraction()
        state.setHovering(false)
        try? await Task.sleep(for: .milliseconds(30))

        XCTAssertFalse(state.isCollapsed)

        state.isCollapsed = true
        state.endModalInteraction()

        XCTAssertFalse(state.isCollapsed)
    }

    func testSnoozeClearsActiveRecordingAudioLevel() throws {
        let state = VoiceState()
        state.handleEvent([
            "type": "state",
            "state": "recording",
            "mode": "vad",
        ])
        state.setLocalRecordingLevel(0.5)
        _ = try XCTUnwrap(state.audioLevel)

        state.snooze()

        XCTAssertEqual(state.mode, .disconnected)
        XCTAssertNil(state.audioLevel)
    }

    func testLocalRecordingLevelOverridesSocketLevelWhileRecording() {
        let state = VoiceState()

        state.handleEvent([
            "type": "state",
            "state": "recording",
            "mode": "vad",
        ])
        state.handleEvent([
            "type": "audio_level",
            "rms": 0.15,
        ])

        state.setLocalRecordingLevel(0.72)

        XCTAssertEqual(try XCTUnwrap(state.audioLevel), 0.72, accuracy: 0.001)
    }

    func testLocalRecordingLevelIgnoredOutsideRecordingMode() {
        let state = VoiceState()
        state.handleEvent([
            "type": "audio_level",
            "rms": 0.24,
        ])

        state.setLocalRecordingLevel(0.72)

        XCTAssertEqual(try XCTUnwrap(state.audioLevel), 0.24, accuracy: 0.001)
    }

    func testStopClearsLocalRecordingLevel() {
        let state = VoiceState()

        state.handleEvent([
            "type": "state",
            "state": "recording",
            "mode": "vad",
        ])
        state.setLocalRecordingLevel(0.72)

        state.cancel()

        XCTAssertNil(state.audioLevel)
    }

    func testCancelDuringRecordingClearsIndicatorToIdleWhenConnected() {
        let state = VoiceState()
        state.setConnectionStatus(true)
        state.handleEvent([
            "type": "state",
            "state": "recording",
            "mode": "vad",
        ])

        state.cancel()

        XCTAssertEqual(state.mode, .idle)
        XCTAssertNil(state.audioLevel)
        XCTAssertFalse(state.speechDetected)
    }

    func testBarInitiatedTranscribingIgnoresStaleIdleUntilTranscriptionArrives() {
        let state = VoiceState()

        state.record()
        state.handleEvent([
            "type": "state",
            "state": "transcribing",
        ])

        state.handleEvent([
            "type": "state",
            "state": "idle",
        ])

        XCTAssertEqual(state.mode, .transcribing)
    }

    func testBarInitiatedTranscribingAcceptsRecordingIdleForSuppressedResult() async {
        let state = VoiceState()
        state.transcriptionTimeout = .milliseconds(20)
        state.recordingIdleFinalTranscriptGrace = .milliseconds(20)

        state.record()
        state.handleEvent([
            "type": "state",
            "state": "transcribing",
        ])

        state.handleEvent([
            "type": "state",
            "state": "idle",
            "source": "recording",
        ])

        try? await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(state.mode, .idle)
        XCTAssertNil(state.errorMessage)
    }

    func testRecordingIdleWithoutFinalTranscriptionDoesNotAutoPasteNextTranscript() async {
        let state = VoiceState()
        state.sendCommand = { _ in }
        state.recordingIdleFinalTranscriptGrace = .milliseconds(20)

        var pastedTexts: [String] = []
        state.pasteHandler = { text in
            pastedTexts.append(text)
            return true
        }

        state.record()
        state.handleEvent([
            "type": "state",
            "state": "transcribing",
        ])
        state.handleEvent([
            "type": "state",
            "state": "idle",
            "source": "recording",
        ])

        try? await Task.sleep(for: .milliseconds(100))

        state.handleEvent([
            "type": "transcription",
            "text": "unrelated later transcript",
        ])

        XCTAssertEqual(pastedTexts, [])
    }

    func testRecordingIdleCleanupClearsPasteIntentEvenIfModeChanges() async {
        let state = VoiceState()
        state.sendCommand = { _ in }
        state.recordingIdleFinalTranscriptGrace = .milliseconds(20)

        var pastedTexts: [String] = []
        state.pasteHandler = { text in
            pastedTexts.append(text)
            return true
        }

        state.record()
        state.handleEvent([
            "type": "state",
            "state": "transcribing",
        ])
        state.handleEvent([
            "type": "state",
            "state": "idle",
            "source": "recording",
        ])
        state.handleEvent([
            "type": "state",
            "state": "speaking",
            "text": "follow-up prompt",
        ])

        try? await Task.sleep(for: .milliseconds(100))

        state.handleEvent([
            "type": "transcription",
            "text": "unrelated later transcript",
        ])

        XCTAssertEqual(pastedTexts, [])
    }

    func testRecordingIdleBeforeFinalTranscriptionStillAutoPastes() {
        let state = VoiceState()
        state.sendCommand = { _ in }
        state.pasteConfirmationDelay = 0

        var pastedTexts: [String] = []
        state.pasteHandler = { text in
            pastedTexts.append(text)
            return true
        }

        state.record()
        state.handleEvent([
            "type": "state",
            "state": "transcribing",
        ])
        state.handleEvent([
            "type": "state",
            "state": "idle",
            "source": "recording",
        ])
        state.handleEvent([
            "type": "transcription",
            "text": "final text after recording idle",
        ])

        XCTAssertEqual(pastedTexts, ["final text after recording idle"])
    }

    func testLateRecordingStateAfterRecordStartTimeoutStillAutoPastes() async {
        let state = VoiceState()
        state.setConnectionStatus(true)
        state.recordStartAckTimeout = .milliseconds(20)
        state.minimumTranscribingDisplayDuration = 0
        state.sendCommand = { _ in }

        var pastedTexts: [String] = []
        state.pasteHandler = { text in
            pastedTexts.append(text)
            return true
        }

        state.record(pressToTalk: true)
        do { let settled = await settle { state.mode == .error }
            XCTAssertTrue(settled)
        }

        XCTAssertEqual(state.mode, .error)
        XCTAssertNil(state.pendingIntent)

        state.handleEvent([
            "type": "state",
            "state": "recording",
            "mode": "ptt",
            "bar_owned": true,
        ])
        state.handleEvent([
            "type": "state",
            "state": "transcribing",
        ])
        state.handleEvent([
            "type": "transcription",
            "text": "late successful dictation",
        ])

        XCTAssertEqual(pastedTexts, ["late successful dictation"])
    }

    func testExpiredLateRecordStartRecoveryDoesNotAutoPasteUnrelatedRecording() async {
        let state = VoiceState()
        state.setConnectionStatus(true)
        state.recordStartAckTimeout = .milliseconds(20)
        state.recordStartLateRecoveryWindow = .milliseconds(20)
        state.minimumTranscribingDisplayDuration = 0
        state.sendCommand = { _ in }

        var pastedTexts: [String] = []
        state.pasteHandler = { text in
            pastedTexts.append(text)
            return true
        }

        state.record(pressToTalk: true)
        do { let settled = await settle { state.mode == .error }
            XCTAssertTrue(settled)
        }

        state.handleEvent([
            "type": "state",
            "state": "recording",
            "mode": "ptt",
        ])
        state.handleEvent([
            "type": "state",
            "state": "transcribing",
        ])
        state.handleEvent([
            "type": "transcription",
            "text": "unrelated later dictation",
        ])

        XCTAssertEqual(pastedTexts, [])
    }

    // MARK: - Remote MCP captures must never be claimed by F5 late-record-start recovery

    //
    // AIDEV-NOTE: Live repro 2026-07-26 12:55:30. A remote MCP capture started while
    // canRecoverLateRecordStart was open. VoiceState.handleEvent's "recording" case saw no
    // pendingIntent and claimed it as a dropped-ack F5 press (barInitiatedRecording = true),
    // so the caller's 466-char answer was auto-pasted into the frontmost app (Preview) instead
    // of being returned to the blocked caller. The 10s window is a RACE: a capture starting
    // inside it is hijacked, outside it works — which is why the symptom was intermittent.

    func testRemoteCaptureInsideLateRecoveryWindowIsNotClaimedAsBarRecording() async {
        let state = VoiceState()
        state.setConnectionStatus(true)
        state.recordStartAckTimeout = .milliseconds(20)
        state.recordStartLateRecoveryWindow = .seconds(10)
        state.minimumTranscribingDisplayDuration = 0
        state.sendCommand = { _ in }

        var pastedTexts: [String] = []
        state.pasteHandler = { text in
            pastedTexts.append(text)
            return true
        }

        // Arm the late-recovery window exactly as a dropped F5 ack would.
        state.record(pressToTalk: true)
        do { let settled = await settle { state.mode == .error }
            XCTAssertTrue(settled)
        }

        // A voice_ask capture now starts INSIDE that window.
        state.handleEvent([
            "type": "state",
            "state": "recording",
            "mode": "vad",
            "silence_mode": "thoughtful",
            "bar_owned": false,
        ])

        XCTAssertFalse(
            state.barInitiatedRecordingForTesting,
            "A remote MCP capture must never be claimed as a bar/F5 recording"
        )

        state.handleEvent(["type": "state", "state": "transcribing"])
        state.handleEvent([
            "type": "transcription",
            "text": "the answer that belongs to the remote caller",
        ])

        XCTAssertEqual(
            pastedTexts, [],
            "A remote-owned transcript must go back to its caller, never auto-paste to the frontmost app"
        )
    }

    func testGenuineF5WithDroppedAckInsideWindowStillRecovers() async {
        // Regression guard for the pre-existing late-recovery feature, not proof of this fix.
        let state = VoiceState()
        state.setConnectionStatus(true)
        state.recordStartAckTimeout = .milliseconds(20)
        state.recordStartLateRecoveryWindow = .seconds(10)
        state.minimumTranscribingDisplayDuration = 0
        state.sendCommand = { _ in }

        var pastedTexts: [String] = []
        state.pasteHandler = { text in
            pastedTexts.append(text)
            return true
        }

        state.record(pressToTalk: true)
        do { let settled = await settle { state.mode == .error }
            XCTAssertTrue(settled)
        }

        state.handleEvent([
            "type": "state",
            "state": "recording",
            "mode": "ptt",
            "bar_owned": true,
        ])

        XCTAssertTrue(
            state.barInitiatedRecordingForTesting,
            "A genuine F5 recording with a dropped ack must still be recovered"
        )

        state.handleEvent(["type": "state", "state": "transcribing"])
        state.handleEvent([
            "type": "transcription",
            "text": "late successful dictation",
        ])

        XCTAssertEqual(pastedTexts, ["late successful dictation"])
    }

    func testRemoteOwnedTranscriptNeverAutoPastesEvenIfBarRecordingWasClaimed() async {
        // Belt and braces: even if classification goes wrong upstream, a remote-owned capture
        // must not auto-paste. Here a genuine bar recording is claimed first, then a remote MCP
        // capture supersedes it before the transcript lands.
        let state = VoiceState()
        state.setConnectionStatus(true)
        state.recordStartAckTimeout = .milliseconds(20)
        state.recordStartLateRecoveryWindow = .seconds(10)
        state.minimumTranscribingDisplayDuration = 0
        state.sendCommand = { _ in }

        var pastedTexts: [String] = []
        state.pasteHandler = { text in
            pastedTexts.append(text)
            return true
        }

        state.record(pressToTalk: true)
        do { let settled = await settle { state.mode == .error }
            XCTAssertTrue(settled)
        }

        // The current daemon explicitly marks genuine bar captures.
        state.handleEvent([
            "type": "state",
            "state": "recording",
            "mode": "ptt",
            "bar_owned": true,
        ])
        XCTAssertTrue(state.barInitiatedRecordingForTesting)

        // A remote MCP capture then takes over the line.
        state.handleEvent([
            "type": "state",
            "state": "recording",
            "mode": "vad",
            "silence_mode": "thoughtful",
            "bar_owned": false,
        ])
        state.handleEvent(["type": "state", "state": "transcribing"])
        state.handleEvent([
            "type": "transcription",
            "text": "remote answer that must not be pasted",
        ])

        XCTAssertEqual(
            pastedTexts, [],
            "Once a capture is known to be remote-owned, its transcript must never auto-paste"
        )
    }

    func testUnmarkedRecordingAfterSourceLessIdleAndLocalPttDoesNotLeakRemoteTranscript() {
        let state = makeRemoteOwnedRecordingState()
        var pastedTexts: [String] = []
        state.pasteHandler = { text in
            pastedTexts.append(text)
            return true
        }

        // An ambiguous idle can belong to another client while the remote capture remains active.
        state.handleEvent(["type": "state", "state": "idle"])
        XCTAssertTrue(state.remoteOwnedRecordingForTesting)

        // The local PTT request preserves the possible remote transcript in the shadow gate.
        state.record(pressToTalk: true)

        // Unknown ownership is not authoritative evidence that the local request won the race.
        state.handleEvent([
            "type": "state",
            "state": "recording",
            "mode": "ptt",
        ])
        state.handleEvent(["type": "state", "state": "transcribing"])
        state.handleEvent([
            "type": "transcription",
            "text": "the remote caller's answer",
        ])

        XCTAssertEqual(
            pastedTexts,
            [],
            "An unmarked event must not clear the shadow and leak the in-flight remote transcript"
        )
    }

    func testUnmarkedRecordingMidCaptureDoesNotClearRemoteOwnership() {
        let state = makeRemoteOwnedRecordingState()

        // A state re-broadcast without ownership provenance must not disown the active capture.
        state.handleEvent([
            "type": "state",
            "state": "recording",
            "mode": "vad",
        ])

        XCTAssertTrue(
            state.remoteOwnedRecordingForTesting,
            "An unmarked mid-capture event must leave known remote ownership untouched"
        )
    }

    func testUnmarkedRecordingFailsClosedAndDoesNotAutoPaste() {
        let state = VoiceState()
        state.setConnectionStatus(true)
        state.minimumTranscribingDisplayDuration = 0
        state.pasteConfirmationDelay = 0
        state.sendCommand = { _ in }
        var pastedTexts: [String] = []
        state.pasteHandler = { text in
            pastedTexts.append(text)
            return true
        }

        state.record(pressToTalk: true)
        state.handleEvent([
            "type": "state",
            "state": "recording",
            "mode": "ptt",
        ])

        XCTAssertFalse(
            state.barInitiatedRecordingForTesting,
            "Absent ownership provenance must not confirm a local bar capture"
        )

        state.handleEvent(["type": "state", "state": "transcribing"])
        state.handleEvent([
            "type": "transcription",
            "text": "unknown-owner transcript",
        ])

        XCTAssertEqual(
            pastedTexts,
            [],
            "Unknown provenance must fail closed instead of auto-pasting"
        )
    }

    func testRemoteOwnershipTermDirectlyBlocksAutoPaste() {
        // Mutation guard: deleting only `!remoteOwnedRecording` from `shouldAutoPaste`
        // must make this test fail even while the superseded-shadow term remains.
        let state = VoiceState()
        state.setConnectionStatus(true)
        state.minimumTranscribingDisplayDuration = 0
        state.pasteConfirmationDelay = 0
        state.sendCommand = { _ in }
        var pastedTexts: [String] = []
        state.pasteHandler = { text in
            pastedTexts.append(text)
            return true
        }

        state.record(pressToTalk: true)
        XCTAssertTrue(state.barInitiatedRecordingForTesting)
        state.remoteOwnedRecordingForTesting = true

        state.handleEvent(["type": "state", "state": "transcribing"])
        state.handleEvent([
            "type": "transcription",
            "text": "inconsistently classified remote transcript",
        ])

        XCTAssertEqual(
            pastedTexts,
            [],
            "Known remote ownership must independently block ordinary auto-paste"
        )
    }

    func testStaleRemoteGateDoesNotSwallowNextPttPasteAfterNoSpeechIdle() {
        let state = makeRemoteOwnedRecordingState()

        state.handleEvent([
            "type": "state",
            "state": "idle",
            "source": "recording",
        ])

        XCTAssertFalse(
            state.remoteOwnedRecordingForTesting,
            "A no-speech recording idle must end remote capture ownership"
        )
        assertNextPttPastes(state, text: "my own dictation")
    }

    func testRecordingIdleBeforeRemoteFinalThenLocalPttDoesNotPasteRemoteTranscript() {
        let state = makeRemoteOwnedRecordingState()
        var pastedTexts: [String] = []
        state.pasteHandler = { text in
            pastedTexts.append(text)
            return true
        }

        state.handleEvent(["type": "state", "state": "transcribing"])
        state.handleEvent([
            "type": "state",
            "state": "idle",
            "source": "recording",
        ])

        XCTAssertFalse(
            state.remoteOwnedRecordingForTesting,
            "Recording idle ends live ownership while the final transcript remains possible"
        )
        XCTAssertTrue(
            state.supersededRemoteTranscriptPendingForTesting,
            "Recording idle must preserve the possible remote final transcript in the shadow"
        )

        state.record(pressToTalk: true)
        state.handleEvent([
            "type": "transcription",
            "text": "the remote caller's answer",
        ])

        XCTAssertEqual(
            pastedTexts,
            [],
            "A local PTT in the recording-idle grace must not paste the remote final transcript"
        )
        XCTAssertFalse(
            state.supersededRemoteTranscriptPendingForTesting,
            "Final transcript delivery must clear the superseded remote shadow"
        )
    }

    func testSourceLessIdleThenLocalPttDoesNotPasteStillActiveRemoteTranscript() {
        let state = makeRemoteOwnedRecordingState()
        var pastedTexts: [String] = []
        state.pasteHandler = { text in
            pastedTexts.append(text)
            return true
        }

        // Another client can emit an ambiguous idle while the authoritative remote capture
        // remains active. The optimistic local PTT must not turn its late transcript into paste.
        state.handleEvent(["type": "state", "state": "idle"])
        XCTAssertTrue(state.remoteOwnedRecordingForTesting)
        state.record(pressToTalk: true)
        state.handleEvent([
            "type": "transcription",
            "text": "remote transcript that wins the race with the reject ack",
        ])

        XCTAssertEqual(
            pastedTexts,
            [],
            "A local record attempt must not unguard an earlier remote capture's transcript"
        )
    }

    func testSnoozeClearsRemoteOwnershipBeforeNextPttPaste() {
        let state = makeRemoteOwnedRecordingState()

        state.snooze()

        XCTAssertFalse(
            state.remoteOwnedRecordingForTesting,
            "Snoozing must end remote capture ownership"
        )
        state.unsnooze()
        assertNextPttPastes(state, text: "dictation after snooze")
    }

    func testSafetyTimeoutClearsStaleRemoteOwnership() async {
        let state = VoiceState()
        state.setConnectionStatus(true)
        state.barInitiatedSafetyTimeout = .milliseconds(20)
        state.sendCommand = { _ in }

        // Seed the exact inconsistent state that the timeout is responsible for containing:
        // a stale remote gate followed by a locally initiated capture.
        state.record(pressToTalk: true)
        state.remoteOwnedRecordingForTesting = true
        XCTAssertTrue(state.remoteOwnedRecordingForTesting)
        do { let settled = await settle { !state.remoteOwnedRecordingForTesting }
            XCTAssertTrue(settled)
        }

        XCTAssertFalse(
            state.remoteOwnedRecordingForTesting,
            "The local-record safety timeout must not leave a remote gate stale"
        )
    }

    func testErrorExitClearsRemoteOwnershipBeforeNextPttPaste() {
        let state = makeRemoteOwnedRecordingState()

        state.handleEvent([
            "type": "error",
            "message": "capture failed",
            "show_during_bar_recording": true,
        ])

        XCTAssertFalse(
            state.remoteOwnedRecordingForTesting,
            "An error that ends the active capture must clear remote ownership"
        )
        assertNextPttPastes(state, text: "dictation after error")
    }

    func testDisconnectClearsRemoteOwnershipBeforeNextPttPaste() {
        let state = makeRemoteOwnedRecordingState()

        state.setConnectionStatus(false)

        XCTAssertFalse(
            state.remoteOwnedRecordingForTesting,
            "Disconnecting must end remote capture ownership"
        )
        state.setConnectionStatus(true)
        assertNextPttPastes(state, text: "dictation after reconnect")
    }

    func testFailedTranscriptionClearsRemoteOwnershipBeforeNextPttPaste() async {
        let state = makeRemoteOwnedRecordingState()
        state.transcriptionTimeout = .milliseconds(20)

        state.handleEvent(["type": "state", "state": "transcribing"])
        do { let settled = await settle { state.mode == .error }
            XCTAssertTrue(settled)
        }

        XCTAssertEqual(state.mode, .error)
        XCTAssertFalse(
            state.remoteOwnedRecordingForTesting,
            "A failed transcription must end remote capture ownership"
        )
        assertNextPttPastes(state, text: "dictation after transcription failure")
    }

    func testRejectedRecordAckClearsRemoteOwnershipBeforeNextPttPaste() throws {
        let state = VoiceState()
        state.setConnectionStatus(true)
        state.minimumTranscribingDisplayDuration = 0
        state.pasteConfirmationDelay = 0
        var recordCommand: [String: Any]?
        state.sendCommand = { command in
            if command["cmd"] as? String == "record" {
                recordCommand = command
            }
        }

        state.record(pressToTalk: true)
        state.remoteOwnedRecordingForTesting = true
        XCTAssertTrue(state.remoteOwnedRecordingForTesting)
        let recordID = try XCTUnwrap(recordCommand?["id"] as? String)
        state.handleEvent([
            "type": "ack",
            "command": "record",
            "outcome": "reject",
            "id": recordID,
            "reason": "busy",
        ])

        XCTAssertFalse(
            state.remoteOwnedRecordingForTesting,
            "A rejected local record must not preserve a stale remote gate"
        )
        assertNextPttPastes(state, text: "dictation after rejected record")
    }

    func testRemoteOwnedTranscriptCannotUsePendingRecoveredPastePath() {
        let state = makeRemoteOwnedRecordingState()
        var pastedTexts: [String] = []
        state.pasteHandler = { text in
            pastedTexts.append(text)
            return true
        }

        state.retranscribeLastCapture()
        state.handleEvent([
            "type": "transcription",
            "text": "remote answer, not a recovered local dictation",
        ])

        XCTAssertEqual(
            pastedTexts,
            [],
            "Remote ownership must gate recovered-transcription paste as well as ordinary auto-paste"
        )
    }

    func testAcceptedRetranscriptionClearsSupersededRemoteShadowAfterReconnect() throws {
        let state = makeRemoteOwnedRecordingState()
        state.setConnectionStatus(false)
        state.setConnectionStatus(true)
        var retranscribeCommand: [String: Any]?
        var pastedTexts: [String] = []
        state.sendCommand = { command in
            if command["cmd"] as? String == "retranscribe_last" {
                retranscribeCommand = command
            }
        }
        state.pasteHandler = { text in
            pastedTexts.append(text)
            return true
        }

        state.retranscribeLastCapture()
        let retranscribeID = try XCTUnwrap(retranscribeCommand?["id"] as? String)
        state.handleEvent(["type": "state", "state": "transcribing"])
        state.handleEvent([
            "type": "ack",
            "command": "retranscribe_last",
            "outcome": "accept",
            "id": retranscribeID,
        ])
        state.handleEvent([
            "type": "transcription",
            "text": "accepted recovered dictation",
        ])

        XCTAssertEqual(
            pastedTexts,
            ["accepted recovered dictation"],
            "Daemon acceptance resolves an old remote shadow and must not consume the first retry"
        )
    }

    func testAcceptedRetranscriptionClearsStaleRemoteOwnership() throws {
        let state = makeRemoteOwnedRecordingState()
        state.handleEvent(["type": "state", "state": "idle"])
        XCTAssertTrue(state.remoteOwnedRecordingForTesting)
        var retranscribeCommand: [String: Any]?
        var pastedTexts: [String] = []
        state.sendCommand = { command in
            if command["cmd"] as? String == "retranscribe_last" {
                retranscribeCommand = command
            }
        }
        state.pasteHandler = { text in
            pastedTexts.append(text)
            return true
        }

        state.retranscribeLastCapture()
        let retranscribeID = try XCTUnwrap(retranscribeCommand?["id"] as? String)
        state.handleEvent(["type": "state", "state": "transcribing"])
        state.handleEvent([
            "type": "ack",
            "command": "retranscribe_last",
            "outcome": "accept",
            "id": retranscribeID,
        ])
        state.handleEvent([
            "type": "transcription",
            "text": "accepted retranscription after stale ownership",
        ])

        XCTAssertEqual(
            pastedTexts,
            ["accepted retranscription after stale ownership"],
            "Daemon acceptance is authoritative that an older remote capture is no longer active"
        )
    }

    private func makeRemoteOwnedRecordingState(
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> VoiceState {
        let state = VoiceState()
        state.setConnectionStatus(true)
        state.minimumTranscribingDisplayDuration = 0
        state.pasteConfirmationDelay = 0
        state.sendCommand = { _ in }
        state.handleEvent([
            "type": "state",
            "state": "recording",
            "mode": "vad",
            "silence_mode": "thoughtful",
            "bar_owned": false,
        ])
        XCTAssertTrue(
            state.remoteOwnedRecordingForTesting,
            "The test precondition requires a remote-owned active capture",
            file: file,
            line: line
        )
        return state
    }

    private func assertNextPttPastes(
        _ state: VoiceState,
        text: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        var pastedTexts: [String] = []
        state.pasteHandler = { pastedText in
            pastedTexts.append(pastedText)
            return true
        }

        state.record(pressToTalk: true)
        state.handleEvent([
            "type": "state",
            "state": "recording",
            "mode": "ptt",
            "bar_owned": true,
        ])
        state.handleEvent(["type": "state", "state": "transcribing"])
        state.handleEvent([
            "type": "transcription",
            "text": text,
        ])

        XCTAssertEqual(
            pastedTexts,
            [text],
            "A terminal remote-capture path must not swallow the next local dictation",
            file: file,
            line: line
        )
    }

    func testFastFinalTranscriptionKeepsBlueStateUntilPendingRecordingIdleCanApply() async {
        let state = VoiceState()
        state.sendCommand = { _ in }
        state.minimumTranscribingDisplayDuration = 0.12
        state.pasteConfirmationDelay = 0

        var pastedTexts: [String] = []
        state.pasteHandler = { text in
            pastedTexts.append(text)
            return true
        }

        state.record()
        state.handleEvent([
            "type": "state",
            "state": "transcribing",
        ])
        state.handleEvent([
            "type": "transcription",
            "text": "fast final transcript",
        ])
        state.handleEvent([
            "type": "state",
            "state": "idle",
            "source": "recording",
        ])

        XCTAssertEqual(state.mode, .transcribing)
        XCTAssertEqual(pastedTexts, [])

        do {
            let settled = await settle { !pastedTexts.isEmpty && state.mode == .idle }
            XCTAssertTrue(settled)
        }

        XCTAssertEqual(pastedTexts, ["fast final transcript"])
        XCTAssertEqual(state.mode, .idle)
    }

    func testRecordingIdleCleanupDoesNotClearPasteIntentAfterTranscribingResumes() async {
        let state = VoiceState()
        state.sendCommand = { _ in }
        state.recordingIdleFinalTranscriptGrace = .milliseconds(20)
        state.pasteConfirmationDelay = 0
        state.minimumTranscribingDisplayDuration = 0

        var pastedTexts: [String] = []
        state.pasteHandler = { text in
            pastedTexts.append(text)
            return true
        }

        state.record()
        state.handleEvent([
            "type": "state",
            "state": "transcribing",
        ])
        state.handleEvent([
            "type": "state",
            "state": "idle",
            "source": "recording",
        ])
        state.handleEvent([
            "type": "state",
            "state": "transcribing",
        ])

        try? await Task.sleep(for: .milliseconds(100))

        state.handleEvent([
            "type": "transcription",
            "text": "final text after transcribing resumes",
        ])

        XCTAssertEqual(pastedTexts, ["final text after transcribing resumes"])
    }

    func testRepasteUsesStoredTranscript() {
        let state = VoiceState()
        state.pasteConfirmationDelay = 0

        let expectation = expectation(description: "paste invoked")
        var pastedTexts: [String] = []
        state.pasteHandler = { text in
            pastedTexts.append(text)
            expectation.fulfill()
            return true
        }

        state.handleEvent([
            "type": "transcription",
            "text": "test capture from codex",
        ])

        state.repasteLastTranscript()

        wait(for: [expectation], timeout: 1)
        XCTAssertEqual(pastedTexts, ["test capture from codex"])
    }

    func testRepasteLastTranscriptUsesLatestFinalTranscriptInsteadOfCurrentPartial() {
        let state = VoiceState()
        state.pasteConfirmationDelay = 0

        let expectation = expectation(description: "paste invoked")
        var pastedTexts: [String] = []
        state.pasteHandler = { text in
            pastedTexts.append(text)
            expectation.fulfill()
            return true
        }

        state.handleEvent([
            "type": "transcription",
            "text": "stable final transcript",
        ])
        state.handleEvent([
            "type": "transcription",
            "text": "new partial transcript",
            "partial": true,
        ])

        state.repasteLastTranscript()

        wait(for: [expectation], timeout: 1)
        XCTAssertEqual(pastedTexts, ["stable final transcript"])
    }

    func testRepasteTranscriptUsesRequestedHistoryItem() {
        let state = VoiceState()
        state.pasteConfirmationDelay = 0

        let expectation = expectation(description: "paste invoked")
        var pastedTexts: [String] = []
        state.pasteHandler = { text in
            pastedTexts.append(text)
            expectation.fulfill()
            return true
        }

        state.repasteTranscript("older history item")

        wait(for: [expectation], timeout: 1)
        XCTAssertEqual(pastedTexts, ["older history item"])
    }

    func testRepasteTranscriptShowsRequestedHistoryItemInConfirmation() {
        let state = VoiceState()
        state.pasteConfirmationDelay = 0
        state.transcript = "current unrelated transcript"

        let expectation = expectation(description: "paste invoked")
        state.pasteHandler = { _ in
            expectation.fulfill()
            return true
        }

        state.repasteTranscript("older history item")

        wait(for: [expectation], timeout: 1)
        XCTAssertEqual(state.confirmationText, "older history item")
    }

    func testSettingsHistoryRepasteUsesCapturedExternalTargetAndAXInsertion() {
        let state = VoiceState()
        state.pasteScheduler = { _, block in block() }
        let capturedApp = NSRunningApplication.current
        var frontmostApp: NSRunningApplication? = capturedApp
        state.frontmostAppProvider = { frontmostApp }
        var activatedApps: [NSRunningApplication] = []
        state.targetAppActivator = { activatedApps.append($0) }
        var insertionCaptureCount = 0
        var insertedTexts: [String] = []
        var clipboardWrites: [String] = []
        var pasteShortcutPosted = false
        state.dictationInsertionHandlerProvider = {
            insertionCaptureCount += 1
            return { text in
                insertedTexts.append(text)
                return true
            }
        }
        state.pasteboardWriter = { clipboardWrites.append($0) }
        state.simulatedPasteHandler = {
            pasteShortcutPosted = true
            return true
        }

        state.captureSettingsHistoryPasteTarget()
        frontmostApp = NSRunningApplication.current
        state.repasteTranscript("settings history line", source: "settings_history")

        XCTAssertEqual(insertionCaptureCount, 1)
        XCTAssertEqual(activatedApps, [capturedApp])
        XCTAssertEqual(insertedTexts, ["settings history line"])
        XCTAssertEqual(clipboardWrites, [])
        XCTAssertFalse(pasteShortcutPosted)
    }

    func testSettingsHistoryAXInsertionRejectsSecondPasteUntilAsyncCompletion() {
        let state = VoiceState()
        state.pasteScheduler = { _, block in block() }
        let capturedApp = NSRunningApplication.current
        state.frontmostAppProvider = { capturedApp }
        state.targetAppActivator = { _ in }
        var insertedTexts: [String] = []
        var pendingCompletion: ((DictationInsertionResult) -> Void)?
        state.asyncDictationInsertionHandlerProvider = {
            { text, completion in
                insertedTexts.append(text)
                pendingCompletion = completion
                return true
            }
        }
        state.simulatedPasteHandler = {
            XCTFail("an in-flight AX insertion must not fall back to Cmd+V")
            return false
        }

        state.captureSettingsHistoryPasteTarget()
        state.repasteTranscript("first transcript", source: "settings_history")
        state.repasteTranscript("same-target clipboard transcript")
        state.repasteTranscript("second transcript", source: "settings_history")

        XCTAssertEqual(insertedTexts, ["first transcript"])
        XCTAssertEqual(state.confirmationText, "Text insertion already in progress")

        pendingCompletion?(.verified)

        XCTAssertEqual(state.confirmationText, "first transcript")

        state.repasteTranscript("third transcript", source: "settings_history")

        XCTAssertEqual(insertedTexts, ["first transcript", "third transcript"])
    }

    func testAXInsertionWatchdogReleasesPasteFlowWhenCompletionNeverArrives() {
        let state = VoiceState()
        state.pasteScheduler = { _, block in block() }
        state.axInsertionCompletionTimeout = 0.01
        let capturedApp = NSRunningApplication.current
        state.frontmostAppProvider = { capturedApp }
        state.targetAppActivator = { _ in }
        var insertedTexts: [String] = []
        state.asyncDictationInsertionHandlerProvider = {
            { text, completion in
                insertedTexts.append(text)
                if text == "retry transcript" {
                    completion(.verified)
                }
                return true
            }
        }

        state.captureSettingsHistoryPasteTarget()
        state.repasteTranscript("stalled transcript", source: "settings_history")

        let watchdogFired = expectation(description: "AX insertion watchdog fired")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            XCTAssertTrue(state.confirmationText?.contains("Unverified") == true)

            state.repasteTranscript("retry transcript", source: "settings_history")

            XCTAssertEqual(insertedTexts, ["stalled transcript", "retry transcript"])
            XCTAssertEqual(state.confirmationText, "retry transcript")
            watchdogFired.fulfill()
        }
        wait(for: [watchdogFired], timeout: 1)
    }

    func testNonAXRepasteToAnotherTargetContinuesDuringAXInsertion() {
        let state = VoiceState()
        state.pasteScheduler = { _, block in block() }
        let capturedApp = NSRunningApplication.current
        let otherApp = FakeRunningApplication(
            bundleIdentifier: "com.example.OtherEditor",
            processIdentifier: 6262
        )
        var frontmostApp: NSRunningApplication? = capturedApp
        state.frontmostAppProvider = { frontmostApp }
        state.targetAppActivator = { _ in }
        state.asyncDictationInsertionHandlerProvider = {
            { _, _ in true }
        }
        var pasteboardString: String?
        state.pasteboardSnapshotter = { nil }
        state.pasteboardWriter = { pasteboardString = $0 }
        state.pasteboardStringProvider = { pasteboardString }
        var pasteShortcutCount = 0
        state.simulatedPasteHandler = {
            pasteShortcutCount += 1
            return true
        }
        var typedTexts: [String] = []
        state.textTypingHandler = { text in
            typedTexts.append(text)
            return true
        }

        state.captureSettingsHistoryPasteTarget()
        state.repasteTranscript("streaming transcript", source: "settings_history")
        frontmostApp = otherApp
        state.focusedTargetEligibilityProvider = {
            DictationFocusedTargetEligibility(
                processIdentifier: otherApp.processIdentifier, role: "AXTextField",
                isEditable: true, isSecure: false, matchesCurrentFocus: { true }
            )
        }
        state.repasteTranscript("typed transcript")

        // Since 2026-09-13 the non-AX path TYPES; it never touches the pasteboard.
        XCTAssertEqual(typedTexts, ["typed transcript"])
        XCTAssertEqual(pasteShortcutCount, 0)
        XCTAssertNil(pasteboardString, "the pasteboard is never written")
        XCTAssertTrue(state.confirmationText?.contains("Unverified") == true)
    }

    func testSettingsHistoryCapturePreservesExternalTargetWhenVoiceBarIsFrontmost() {
        let state = VoiceState()
        state.pasteScheduler = { _, block in block() }
        let externalApp = FakeRunningApplication(
            bundleIdentifier: "com.example.Editor",
            processIdentifier: 4242
        )
        let voiceBarApp = FakeRunningApplication(
            bundleIdentifier: Bundle.main.bundleIdentifier,
            processIdentifier: 5252
        )
        var frontmostApp: NSRunningApplication? = externalApp
        state.frontmostAppProvider = { frontmostApp }
        var activatedApps: [NSRunningApplication] = []
        state.targetAppActivator = { activatedApps.append($0); frontmostApp = $0 }
        var insertionCaptureCount = 0
        var insertedTexts: [String] = []
        state.dictationInsertionHandlerProvider = {
            insertionCaptureCount += 1
            return { text in
                insertedTexts.append(text)
                return true
            }
        }
        state.simulatedPasteHandler = {
            XCTFail("settings history paste should use the preserved AX insertion target")
            return false
        }

        state.captureSettingsHistoryPasteTarget()
        frontmostApp = voiceBarApp
        state.captureSettingsHistoryPasteTarget()
        state.repasteTranscript("preserved settings history line", source: "settings_history")

        XCTAssertEqual(insertionCaptureCount, 1)
        XCTAssertEqual(activatedApps, [externalApp])
        XCTAssertEqual(insertedTexts, ["preserved settings history line"])
    }

    func testCopyTranscriptWritesRequestedHistoryItemToPasteboard() {
        let state = VoiceState()

        var copiedTexts: [String] = []
        state.pasteboardWriter = { copiedTexts.append($0) }
        state.pasteboardStringProvider = { copiedTexts.last }

        state.copyTranscript("history item to copy")

        XCTAssertEqual(copiedTexts, ["history item to copy"])
        XCTAssertEqual(state.confirmationText, "Copied")
    }

    func testPartialTranscriptionDoesNotAutoPasteOrConsumeFinalPaste() {
        let state = VoiceState()
        var pastedTexts: [String] = []
        state.pasteHandler = { text in
            pastedTexts.append(text)
            return true
        }
        state.sendCommand = { _ in }

        state.record()
        state.handleEvent([
            "type": "transcription",
            "text": "wow",
            "partial": true,
        ])

        XCTAssertEqual(pastedTexts, [])

        state.handleEvent([
            "type": "transcription",
            "text": "this is the full transcript ending with wow",
            "partial": false,
        ])

        XCTAssertEqual(pastedTexts, ["this is the full transcript ending with wow"])
        XCTAssertEqual(state.transcript, "this is the full transcript ending with wow")
    }

    func testAutoPasteUsesRecordedInputInsertionBeforeTypingFallback() {
        let state = VoiceState()
        state.sendCommand = { _ in }
        var frontmostApp: NSRunningApplication? = NSRunningApplication.current
        state.frontmostAppProvider = { frontmostApp }
        state.pasteScheduler = { _, block in block() }
        state.targetAppActivator = { frontmostApp = $0 }

        var insertedTexts: [String] = []
        var pasteShortcutPosted = false
        state.dictationInsertionHandlerProvider = {
            { text in
                insertedTexts.append(text)
                return true
            }
        }
        state.simulatedPasteHandler = {
            pasteShortcutPosted = true
            return true
        }

        state.record()
        frontmostApp = nil
        state.handleEvent([
            "type": "transcription",
            "text": "this is the full transcript ending with wow",
        ])

        XCTAssertEqual(insertedTexts, ["this is the full transcript ending with wow"])
        XCTAssertFalse(pasteShortcutPosted)
        XCTAssertTrue(state.confirmationText?.contains("Unverified") == true)
    }

    func testAutoPasteUsesRecordStartInsertionWhenSameTargetIsFrontmostAtPasteTime() {
        let state = VoiceState()
        state.sendCommand = { _ in }
        state.frontmostAppProvider = { NSRunningApplication.current }
        state.pasteScheduler = { _, block in block() }
        state.targetAppActivator = { _ in }

        var insertedTexts: [String] = []
        var clipboardWrites: [String] = []
        var pasteboardString: String?
        var pasteShortcutPosted = false
        state.dictationInsertionHandlerProvider = {
            { text in
                insertedTexts.append(text)
                return true
            }
        }
        state.pasteboardWriter = {
            clipboardWrites.append($0)
            pasteboardString = $0
        }
        state.pasteboardStringProvider = { pasteboardString }
        state.simulatedPasteHandler = {
            pasteShortcutPosted = true
            return true
        }

        state.record()
        state.handleEvent([
            "type": "transcription",
            "text": "paste into the focus that is current on release",
        ])

        XCTAssertEqual(insertedTexts, ["paste into the focus that is current on release"])
        XCTAssertEqual(clipboardWrites, [])
        XCTAssertFalse(pasteShortcutPosted)
        XCTAssertTrue(state.confirmationText?.contains("Unverified") == true)
    }

    // AIDEV-NOTE: Lane P — a multi-line transcript pasted into a terminal composer
    // submitted itself. The AX insertion path delivers text unbracketed, so each
    // newline reached Claude Code's composer as a Return. Terminals therefore never
    // take AX. They took clipboard + Cmd+V until 2026-09-13; now the transcript is
    // TYPED — printable text, each line break as Shift+Return (SynthesizedTyping) —
    // and the pasteboard is never touched (Etan's spec — see VoiceState's paste call
    // site).
    private static let multiLineSpecimen = """
    So, here are a few things:
    1. I went there, and then I came back here.
    2. I went to the store.
    """

    func testAutoPasteToTerminalTargetUsesBracketedTypingInsteadOfAXInsertion() {
        let state = VoiceState()
        state.sendCommand = { _ in }
        let terminalApp = FakeRunningApplication(
            bundleIdentifier: "com.cmuxterm.app",
            processIdentifier: 9191
        )
        state.frontmostAppProvider = { terminalApp }
        state.pasteScheduler = { _, block in block() }
        state.targetAppActivator = { _ in }

        var insertedTexts: [String] = []
        var clipboardWrites: [String] = []
        var pasteboardString: String?
        var pasteShortcutPosted = false
        state.asyncDictationInsertionHandlerProvider = {
            { text, completion in
                insertedTexts.append(text)
                completion(.verified)
                return true
            }
        }
        state.pasteboardWriter = {
            clipboardWrites.append($0)
            pasteboardString = $0
        }
        state.pasteboardStringProvider = { pasteboardString }
        state.simulatedPasteHandler = {
            pasteShortcutPosted = true
            return true
        }
        var typed: [String] = []
        state.textTypingHandler = { text in
            typed.append(text)
            return true
        }

        state.record()
        state.handleEvent([
            "type": "transcription",
            "text": Self.multiLineSpecimen,
        ])

        XCTAssertEqual(insertedTexts, [], "a terminal target must never take the AX path")
        XCTAssertEqual(clipboardWrites, [], "dictation must never write the pasteboard")
        XCTAssertFalse(pasteShortcutPosted, "and never posts Cmd+V")
        XCTAssertEqual(typed, [Self.multiLineSpecimen])
        XCTAssertEqual(state.confirmationText, Self.multiLineSpecimen)
        XCTAssertEqual(state.latestDictationInsertionStatus, .unverified)
    }

    // Transcription cleanup already trims trailing whitespace upstream; the terminal
    // strip in TerminalPasteTargets is the backstop. This asserts the end-to-end
    // contract: a terminal never receives a trailing newline, whoever removed it.
    func testAutoPasteToTerminalTargetNeverDeliversATrailingNewline() {
        let state = VoiceState()
        state.sendCommand = { _ in }
        let terminalApp = FakeRunningApplication(
            bundleIdentifier: "com.apple.Terminal",
            processIdentifier: 9292
        )
        state.frontmostAppProvider = { terminalApp }
        state.pasteScheduler = { _, block in block() }
        state.targetAppActivator = { _ in }

        var clipboardWrites: [String] = []
        var pasteboardString: String?
        state.asyncDictationInsertionHandlerProvider = {
            { _, _ in
                XCTFail("a terminal target must never take the AX path")
                return false
            }
        }
        state.pasteboardWriter = {
            clipboardWrites.append($0)
            pasteboardString = $0
        }
        state.pasteboardStringProvider = { pasteboardString }
        state.simulatedPasteHandler = { true }
        var typedTexts: [String] = []
        state.textTypingHandler = { text in
            typedTexts.append(text)
            return true
        }

        state.record()
        state.handleEvent([
            "type": "transcription",
            "text": Self.multiLineSpecimen + "\n",
        ])

        XCTAssertEqual(typedTexts, [Self.multiLineSpecimen])
        XCTAssertEqual(clipboardWrites, [], "the pasteboard is never written")
    }

    func testAutoPasteToNonTerminalTargetStillUsesAXInsertion() {
        let state = VoiceState()
        state.sendCommand = { _ in }
        let editorApp = FakeRunningApplication(
            bundleIdentifier: "com.example.Editor",
            processIdentifier: 9393
        )
        state.frontmostAppProvider = { editorApp }
        state.pasteScheduler = { _, block in block() }
        state.targetAppActivator = { _ in }

        var insertedTexts: [String] = []
        var clipboardWrites: [String] = []
        state.asyncDictationInsertionHandlerProvider = {
            { text, completion in
                insertedTexts.append(text)
                completion(.verified)
                return true
            }
        }
        state.pasteboardWriter = { clipboardWrites.append($0) }
        state.simulatedPasteHandler = {
            XCTFail("a non-terminal target keeps today's AX-first behaviour")
            return false
        }

        state.record()
        state.handleEvent([
            "type": "transcription",
            "text": Self.multiLineSpecimen + "\n",
        ])

        // Upstream transcription cleanup trims the trailing newline before delivery;
        // what matters here is that the AX path is still the one that fires.
        XCTAssertEqual(insertedTexts, [Self.multiLineSpecimen])
        XCTAssertEqual(clipboardWrites, [])
    }

    func testAutoPasteUsesFreshFocusedInsertionInsteadOfStaleCapturedInsertionWhenTargetIsFrontmost() {
        let state = VoiceState()
        state.sendCommand = { _ in }
        state.frontmostAppProvider = { NSRunningApplication.current }
        state.pasteScheduler = { _, block in block() }
        state.targetAppActivator = { _ in }

        var captureAttempts = 0
        var staleCapturedTexts: [String] = []
        var freshFocusedTexts: [String] = []
        var clipboardWrites: [String] = []
        var pasteShortcutPosted = false
        state.dictationInsertionHandlerProvider = {
            captureAttempts += 1
            if captureAttempts == 1 {
                return { text in
                    staleCapturedTexts.append(text)
                    return true
                }
            }
            return { text in
                freshFocusedTexts.append(text)
                return true
            }
        }
        state.pasteboardWriter = { clipboardWrites.append($0) }
        state.simulatedPasteHandler = {
            pasteShortcutPosted = true
            return true
        }

        state.record()
        state.handleEvent([
            "type": "transcription",
            "text": "paste into the input focused at release",
        ])

        XCTAssertEqual(captureAttempts, 2)
        XCTAssertEqual(staleCapturedTexts, [])
        XCTAssertEqual(freshFocusedTexts, ["paste into the input focused at release"])
        XCTAssertEqual(clipboardWrites, [])
        XCTAssertFalse(pasteShortcutPosted)
    }

    func testAutoPasteDoesNotUseCapturedInsertionWhenCurrentTargetIsFrontmostAndFreshCaptureIsUnavailable() {
        let state = VoiceState()
        state.sendCommand = { _ in }
        let targetApp = FakeRunningApplication(
            bundleIdentifier: "com.example.TargetApp",
            processIdentifier: 1111
        )
        var frontmostApp: NSRunningApplication? = targetApp
        state.frontmostAppProvider = { frontmostApp }
        state.pasteScheduler = { _, block in block() }
        state.targetAppActivator = { _ in }

        var captureAttempts = 0
        var staleCapturedTexts: [String] = []
        var clipboardWrites: [String] = []
        var pasteboardString: String?
        var pasteShortcutPosted = false
        state.dictationInsertionHandlerProvider = {
            captureAttempts += 1
            guard captureAttempts == 1 else { return nil }
            return { text in
                staleCapturedTexts.append(text)
                return true
            }
        }
        state.pasteboardWriter = {
            clipboardWrites.append($0)
            pasteboardString = $0
        }
        state.pasteboardStringProvider = { pasteboardString }
        state.simulatedPasteHandler = {
            pasteShortcutPosted = true
            return true
        }
        var typedTexts: [String] = []
        state.textTypingHandler = { text in
            typedTexts.append(text)
            return true
        }

        state.record()
        frontmostApp = targetApp
        state.handleEvent([
            "type": "transcription",
            "text": "type instead of stale captured ax",
        ])

        XCTAssertEqual(captureAttempts, 2)
        XCTAssertEqual(staleCapturedTexts, [])
        XCTAssertEqual(typedTexts, [])
        XCTAssertEqual(state.latestDictationInsertionStatus, .notInserted)
        XCTAssertEqual(clipboardWrites, [], "An AX miss must not authorize global typing")
        XCTAssertFalse(pasteShortcutPosted)
    }

    func testAutoPasteDoesNotUseCapturedInsertionWhenTargetAppRemainsFrontmostAndFreshCaptureIsUnavailable() {
        let state = VoiceState()
        state.sendCommand = { _ in }
        state.frontmostAppProvider = { NSRunningApplication.current }
        state.pasteScheduler = { _, block in block() }
        state.targetAppActivator = { _ in }

        var captureAttempts = 0
        var insertedTexts: [String] = []
        var clipboardWrites: [String] = []
        var pasteboardString: String? = "original clipboard"
        var pasteShortcutPosted = false
        var pasteOutcomes: [String] = []
        state.dictationInsertionHandlerProvider = {
            captureAttempts += 1
            guard captureAttempts == 1 else { return nil }
            return { text in
                insertedTexts.append(text)
                return true
            }
        }
        state.pasteboardWriter = {
            clipboardWrites.append($0)
            pasteboardString = $0
        }
        state.pasteboardStringProvider = { pasteboardString }
        state.simulatedPasteHandler = {
            pasteShortcutPosted = true
            return true
        }
        state.diagnosticLogger = { event, details in
            if event == "paste_confirmation", let outcome = details["outcome"] {
                pasteOutcomes.append(outcome)
            }
        }
        var typedTexts: [String] = []
        state.textTypingHandler = { text in
            typedTexts.append(text)
            return true
        }

        state.record()
        state.handleEvent([
            "type": "transcription",
            "text": "typed without touching the clipboard",
        ])

        // Etan's spec in one test: "original clipboard" is what he copied, and it
        // must still be there after the dictation lands.
        XCTAssertEqual(captureAttempts, 2)
        XCTAssertEqual(insertedTexts, [])
        XCTAssertEqual(typedTexts, [])
        XCTAssertEqual(state.latestDictationInsertionStatus, .notInserted)
        XCTAssertEqual(clipboardWrites, [])
        XCTAssertEqual(pasteboardString, "original clipboard")
        XCTAssertFalse(pasteShortcutPosted)
        XCTAssertEqual(pasteOutcomes, ["notInserted"])
    }

    func testAutoPasteTreatsDifferentPidWithSameBundleIdentifierAsSameTargetForFreshInsertion() {
        let state = VoiceState()
        state.sendCommand = { _ in }
        let recordStartApp = FakeRunningApplication(
            bundleIdentifier: "com.example.TargetApp",
            processIdentifier: 1111
        )
        let pasteTimeApp = FakeRunningApplication(
            bundleIdentifier: "com.example.TargetApp",
            processIdentifier: 2222
        )
        var frontmostApp: NSRunningApplication? = recordStartApp
        state.frontmostAppProvider = { frontmostApp }
        state.pasteScheduler = { _, block in block() }
        state.targetAppActivator = { _ in }

        var captureAttempts = 0
        var insertedTexts: [String] = []
        var clipboardWrites: [String] = []
        var pasteShortcutPosted = false
        state.dictationInsertionHandlerProvider = {
            captureAttempts += 1
            guard captureAttempts > 1 else { return nil }
            return { text in
                insertedTexts.append(text)
                return true
            }
        }
        state.pasteboardWriter = { clipboardWrites.append($0) }
        state.simulatedPasteHandler = {
            pasteShortcutPosted = true
            return true
        }

        state.record()
        frontmostApp = pasteTimeApp
        state.handleEvent([
            "type": "transcription",
            "text": "same bundle target should get fresh ax",
        ])

        XCTAssertEqual(captureAttempts, 2)
        XCTAssertEqual(insertedTexts, ["same bundle target should get fresh ax"])
        XCTAssertEqual(clipboardWrites, [])
        XCTAssertFalse(pasteShortcutPosted)
    }

    func testAutoPasteDoesNotRetryAnUnverifiedFreshInsertion() {
        let state = VoiceState()
        state.sendCommand = { _ in }
        var frontmostApp: NSRunningApplication? = NSRunningApplication.current
        state.frontmostAppProvider = { frontmostApp }
        state.pasteScheduler = { _, block in block() }
        state.targetAppActivator = { frontmostApp = $0 }

        var captureAttempts = 0
        var freshAttempts: [String] = []
        var capturedAttempts: [String] = []
        var clipboardWrites: [String] = []
        var pasteboardString: String?
        var pasteShortcutPosted = false
        state.dictationInsertionHandlerProvider = {
            captureAttempts += 1
            if captureAttempts == 1 {
                return { text in
                    capturedAttempts.append(text)
                    return false
                }
            }
            return { text in
                freshAttempts.append(text)
                return false
            }
        }
        state.pasteboardWriter = {
            clipboardWrites.append($0)
            pasteboardString = $0
        }
        state.pasteboardStringProvider = { pasteboardString }
        state.simulatedPasteHandler = {
            pasteShortcutPosted = true
            return true
        }
        var typedTexts: [String] = []
        state.textTypingHandler = { text in
            typedTexts.append(text)
            return true
        }

        state.record()
        frontmostApp = nil
        state.handleEvent([
            "type": "transcription",
            "text": "typing only after ax misses",
        ])

        XCTAssertEqual(captureAttempts, 2)
        XCTAssertEqual(freshAttempts, ["typing only after ax misses"])
        XCTAssertEqual(capturedAttempts, [])
        XCTAssertEqual(typedTexts, [])
        XCTAssertEqual(state.latestDictationInsertionStatus, .unverified)
        XCTAssertEqual(clipboardWrites, [], "the clipboard is never a fallback")
        XCTAssertFalse(pasteShortcutPosted)
    }

    func testAutoPasteAttemptsFreshInsertionAfterActivatingRecordedTarget() {
        let state = VoiceState()
        state.sendCommand = { _ in }
        var frontmostApp: NSRunningApplication? = NSRunningApplication.current
        state.frontmostAppProvider = { frontmostApp }
        state.pasteScheduler = { _, block in block() }
        state.targetAppActivator = { _ in
            frontmostApp = NSRunningApplication.current
        }

        var captureAttempts = 0
        var staleCapturedTexts: [String] = []
        var freshFocusedTexts: [String] = []
        var clipboardWrites: [String] = []
        var pasteShortcutPosted = false
        state.dictationInsertionHandlerProvider = {
            captureAttempts += 1
            if captureAttempts == 1 {
                return { text in
                    staleCapturedTexts.append(text)
                    return true
                }
            }
            return { text in
                freshFocusedTexts.append(text)
                return true
            }
        }
        state.pasteboardWriter = { clipboardWrites.append($0) }
        state.simulatedPasteHandler = {
            pasteShortcutPosted = true
            return true
        }

        state.record()
        frontmostApp = nil
        state.handleEvent([
            "type": "transcription",
            "text": "paste into target after activation",
        ])

        XCTAssertEqual(captureAttempts, 2)
        XCTAssertEqual(staleCapturedTexts, [])
        XCTAssertEqual(freshFocusedTexts, ["paste into target after activation"])
        XCTAssertEqual(clipboardWrites, [])
        XCTAssertFalse(pasteShortcutPosted)
    }

    func testAutoPasteAttemptsFreshInsertionCaptureBeforeClipboardFallback() {
        let state = VoiceState()
        state.sendCommand = { _ in }
        state.frontmostAppProvider = { NSRunningApplication.current }
        state.pasteScheduler = { _, block in block() }
        state.targetAppActivator = { _ in }

        var captureAttempts = 0
        var insertedTexts: [String] = []
        var clipboardWrites: [String] = []
        var pasteShortcutPosted = false
        state.dictationInsertionHandlerProvider = {
            captureAttempts += 1
            guard captureAttempts > 1 else { return nil }
            return { text in
                insertedTexts.append(text)
                return true
            }
        }
        state.pasteboardWriter = { clipboardWrites.append($0) }
        state.simulatedPasteHandler = {
            pasteShortcutPosted = true
            return true
        }

        state.record()
        state.handleEvent([
            "type": "transcription",
            "text": "fresh capture should insert here",
        ])

        XCTAssertEqual(captureAttempts, 2)
        XCTAssertEqual(insertedTexts, ["fresh capture should insert here"])
        XCTAssertEqual(clipboardWrites, [])
        XCTAssertFalse(pasteShortcutPosted)
    }

    func testAutoPasteRetainsTranscriptWhenLegacyInsertionCannotVerify() {
        let state = VoiceState()
        state.sendCommand = { _ in }
        var frontmostApp: NSRunningApplication? = NSRunningApplication.current
        state.frontmostAppProvider = { frontmostApp }
        state.pasteScheduler = { _, block in block() }
        state.targetAppActivator = { frontmostApp = $0 }

        var insertedTexts: [String] = []
        var clipboardWrites: [String] = []
        var restoredSnapshots: [PasteboardSnapshot] = []
        var pasteboardString: String?
        var pasteShortcutPosted = false
        var pasteboardChangeCount = 7
        state.dictationInsertionHandlerProvider = {
            { text in
                insertedTexts.append(text)
                return false
            }
        }
        state.pasteboardSnapshotter = {
            PasteboardSnapshot(
                changeCount: pasteboardChangeCount,
                items: [["public.utf8-plain-text": Data("user-copy".utf8)]]
            )
        }
        state.pasteboardWriter = {
            clipboardWrites.append($0)
            pasteboardString = $0
            pasteboardChangeCount += 1
        }
        state.pasteboardStringProvider = { pasteboardString }
        state.pasteboardChangeCountProvider = { pasteboardChangeCount }
        state.pasteboardSnapshotRestorer = {
            restoredSnapshots.append($0)
            pasteboardChangeCount += 1
        }
        state.simulatedPasteHandler = {
            pasteShortcutPosted = true
            return true
        }
        var typedTexts: [String] = []
        state.textTypingHandler = { text in
            typedTexts.append(text)
            return true
        }

        state.record()
        frontmostApp = nil
        state.handleEvent([
            "type": "transcription",
            "text": "this is the full transcript ending with wow",
        ])

        // A legacy setter error cannot prove nothing landed. No second delivery or
        // clipboard operation is allowed, and the complete transcript is retained.
        XCTAssertEqual(insertedTexts, [
            "this is the full transcript ending with wow",
        ])
        XCTAssertEqual(typedTexts, [])
        XCTAssertEqual(state.latestDictationInsertionStatus, .unverified)
        XCTAssertEqual(clipboardWrites, [])
        XCTAssertEqual(restoredSnapshots, [])
        XCTAssertFalse(pasteShortcutPosted)
        XCTAssertTrue(state.confirmationText?.contains("Unverified") == true)
    }

    func testAutoPasteRetainsTranscriptWhenNoFocusedInputWasCaptured() {
        let state = VoiceState()
        state.sendCommand = { _ in }
        state.frontmostAppProvider = { NSRunningApplication.current }
        state.pasteScheduler = { _, block in block() }
        state.targetAppActivator = { _ in }
        state.dictationInsertionHandlerProvider = { nil }
        var pasteboardString: String?
        state.pasteboardWriter = { pasteboardString = $0 }
        state.pasteboardStringProvider = { pasteboardString }
        state.simulatedPasteHandler = { true }
        // No captured AX target is evidence of unknown focus, not permission to type.
        var typedTexts: [String] = []
        state.textTypingHandler = { text in
            typedTexts.append(text)
            return true
        }

        state.record()
        state.handleEvent([
            "type": "transcription",
            "text": "this might not have an input",
        ])

        XCTAssertEqual(typedTexts, [])
        XCTAssertEqual(state.latestDictationInsertionStatus, .notInserted)
        XCTAssertNil(pasteboardString, "the pasteboard is never written")
        XCTAssertTrue(state.confirmationText?.contains("Not pasted") == true)
    }

    /// The failure this guarded — Cmd+V posted after a pasteboard write that did
    /// not take, pasting whatever was on his clipboard — cannot happen any more:
    /// dictation never writes the pasteboard and never posts Cmd+V. What remains
    /// is the typing failure itself, which must say so and point at Shift+F5
    /// rather than falling back to the clipboard.
    func testAutoPasteWithoutAXDoesNotAttemptTypingOrTouchClipboard() {
        let state = VoiceState()
        state.sendCommand = { _ in }
        state.frontmostAppProvider = { NSRunningApplication.current }
        state.pasteScheduler = { _, block in block() }
        state.targetAppActivator = { _ in }
        state.dictationInsertionHandlerProvider = { nil }

        var clipboardWrites: [String] = []
        var diagnostics: [(String, [String: String])] = []
        var pasteShortcutPosted = false
        state.pasteboardWriter = { clipboardWrites.append($0) }
        state.pasteboardStringProvider = {
            "stale clipboard content that must not be pasted"
        }
        state.diagnosticLogger = { event, details in
            diagnostics.append((event, details))
        }
        state.simulatedPasteHandler = {
            pasteShortcutPosted = true
            return true
        }
        state.textTypingHandler = { _ in false }

        state.record()
        state.handleEvent([
            "type": "transcription",
            "text": "fresh transcript that must not paste stale clipboard content",
        ])

        XCTAssertEqual(clipboardWrites, [], "a failed typing attempt must not fall back to the clipboard")
        XCTAssertFalse(pasteShortcutPosted)
        XCTAssertTrue(state.confirmationText?.contains("Not pasted") == true)
        XCTAssertFalse(diagnostics.contains { event, _ in event == "paste_typing_result" })
    }

    func testAutoPasteNeverWritesOrRestoresTheClipboardAfterAXMisses() {
        let state = VoiceState()
        state.sendCommand = { _ in }
        var frontmostApp: NSRunningApplication? = NSRunningApplication.current
        state.frontmostAppProvider = { frontmostApp }
        state.targetAppActivator = { frontmostApp = $0 }

        var insertedTexts: [String] = []
        var clipboardWrites: [String] = []
        var restoredSnapshots: [PasteboardSnapshot] = []
        var pasteboardString: String?
        var pasteShortcutPosted = false
        var pasteboardChangeCount = 3

        state.dictationInsertionHandlerProvider = {
            { text in
                insertedTexts.append(text)
                return false
            }
        }
        state.pasteScheduler = { _, block in block() }
        state.pasteboardSnapshotter = {
            PasteboardSnapshot(
                changeCount: pasteboardChangeCount,
                items: [["public.utf8-plain-text": Data("user-copy".utf8)]]
            )
        }
        state.pasteboardWriter = {
            clipboardWrites.append($0)
            pasteboardString = $0
            pasteboardChangeCount += 1
        }
        state.pasteboardStringProvider = { pasteboardString }
        state.pasteboardChangeCountProvider = { pasteboardChangeCount }
        state.pasteboardSnapshotRestorer = {
            restoredSnapshots.append($0)
            pasteboardChangeCount += 1
        }
        state.simulatedPasteHandler = {
            pasteShortcutPosted = true
            pasteboardString = "new user clipboard"
            pasteboardChangeCount += 1
            return true
        }

        var typedTexts: [String] = []
        state.textTypingHandler = { text in
            typedTexts.append(text)
            return true
        }

        state.record()
        frontmostApp = nil
        state.handleEvent([
            "type": "transcription",
            "text": "clipboard safety check",
        ])

        // This used to prove the timed restore was skipped when his clipboard
        // changed underneath it. There is no restore any more, and nothing to
        // restore from: one unverified AX attempt consumes delivery, and his
        // clipboard is never touched at all.
        XCTAssertEqual(insertedTexts, [
            "clipboard safety check",
        ])
        XCTAssertEqual(typedTexts, [])
        XCTAssertEqual(state.latestDictationInsertionStatus, .unverified)
        XCTAssertEqual(clipboardWrites, [])
        XCTAssertFalse(pasteShortcutPosted)
        XCTAssertEqual(restoredSnapshots, [])
        XCTAssertNil(pasteboardString, "his clipboard was never written")
    }

    /// AIDEV-NOTE: This was `testAutoPasteRestoresClipboardAfterFallbackPasteDelay`,
    /// the timed restore: write the transcript, put "old clipboard" back 0.5 s
    /// later. That restore is the race Etan reported on 2026-09-09, and #69's
    /// removal of it is what made every Cmd+V paste the transcript. It no longer
    /// exists in any form: dictation never writes the pasteboard, so no restore is
    /// ever scheduled and there is nothing to restore.
    func testAutoPasteSchedulesNoClipboardRestoreBecauseItNeverWritesTheClipboard() {
        let state = VoiceState()
        state.sendCommand = { _ in }
        state.frontmostAppProvider = { NSRunningApplication.current }
        state.targetAppActivator = { _ in }
        state.pasteConfirmationDelay = 0

        var scheduled: [(delay: TimeInterval, block: () -> Void)] = []
        var scheduledDelays: [TimeInterval] = []
        var pasteboardString: String?
        var pasteboardChangeCount = 5
        var restoredSnapshots: [PasteboardSnapshot] = []

        state.pasteScheduler = { delay, block in
            scheduled.append((delay, block))
            scheduledDelays.append(delay)
        }
        state.pasteboardSnapshotter = {
            PasteboardSnapshot(
                changeCount: pasteboardChangeCount,
                items: [["public.utf8-plain-text": Data("old clipboard".utf8)]]
            )
        }
        state.pasteboardWriter = {
            pasteboardString = $0
            pasteboardChangeCount += 1
        }
        state.pasteboardStringProvider = { pasteboardString }
        state.pasteboardChangeCountProvider = { pasteboardChangeCount }
        state.pasteboardSnapshotRestorer = {
            restoredSnapshots.append($0)
            pasteboardString = "old clipboard"
            pasteboardChangeCount += 1
        }
        state.simulatedPasteHandler = { true }
        var typedTexts: [String] = []
        state.textTypingHandler = { text in
            typedTexts.append(text)
            return true
        }

        state.record()
        state.handleEvent([
            "type": "transcription",
            "text": "fresh transcript",
        ])

        // Drain the flow's own scheduled steps. There used to be one more: the
        // clipboard restore at `pasteboardRestoreDelay`. Its absence is the point.
        var drained = 0
        while !scheduled.isEmpty, drained < 10 {
            scheduled.removeFirst().block()
            drained += 1
        }
        XCTAssertLessThan(drained, 10, "the paste flow must settle, not reschedule forever")

        XCTAssertEqual(typedTexts, [])
        XCTAssertEqual(state.latestDictationInsertionStatus, .notInserted)
        XCTAssertFalse(
            scheduledDelays.contains { abs($0 - state.pasteboardRestoreDelay) < 0.001 },
            "no clipboard restore is ever scheduled"
        )
        XCTAssertNil(pasteboardString, "the pasteboard was never written")
        XCTAssertEqual(restoredSnapshots, [], "so there was never anything to restore")
        XCTAssertTrue(state.confirmationText?.contains("Not pasted") == true)
    }

    func testDefaultFallbackPasteboardWriterMarksTranscriptAsTransientAndAutoGenerated() {
        let pasteboard = NSPasteboard.general
        let saved = Self.capturePasteboardForTest()
        defer { Self.restorePasteboardForTest(saved) }
        let state = VoiceState()

        state.pasteboardWriter("fresh transcript")

        XCTAssertEqual(pasteboard.string(forType: .string), "fresh transcript")
        XCTAssertNotNil(pasteboard.data(forType: Self.transientType))
        XCTAssertNotNil(pasteboard.data(forType: Self.autoGeneratedType))
    }

    func testDefaultPasteboardSnapshotSkipsDynamicAndNspasteboardTypes() {
        let pasteboard = NSPasteboard.general
        let saved = Self.capturePasteboardForTest()
        defer { Self.restorePasteboardForTest(saved) }
        let state = VoiceState()
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setData(Data("keep".utf8), forType: .string)
        item.setData(Data("dynamic".utf8), forType: NSPasteboard.PasteboardType("dyn.voicebar-test"))
        item.setData(Data(), forType: Self.transientType)
        item.setData(Data(), forType: Self.autoGeneratedType)
        pasteboard.writeObjects([item])

        let snapshot = state.pasteboardSnapshotter()
        let itemTypes = Set(snapshot?.items.first.map { Array($0.keys) } ?? [])

        XCTAssertTrue(itemTypes.contains(NSPasteboard.PasteboardType.string.rawValue))
        XCTAssertFalse(itemTypes.contains("dyn.voicebar-test"))
        XCTAssertFalse(itemTypes.contains(Self.transientType.rawValue))
        XCTAssertFalse(itemTypes.contains(Self.autoGeneratedType.rawValue))
    }

    func testDefaultPasteboardRestorerMarksRestoredContentAsTransientAndAutoGenerated() {
        let pasteboard = NSPasteboard.general
        let saved = Self.capturePasteboardForTest()
        defer { Self.restorePasteboardForTest(saved) }
        let state = VoiceState()

        state.pasteboardSnapshotRestorer(
            PasteboardSnapshot(
                changeCount: pasteboard.changeCount,
                items: [[NSPasteboard.PasteboardType.string.rawValue: Data("old clipboard".utf8)]]
            )
        )

        XCTAssertEqual(pasteboard.string(forType: .string), "old clipboard")
        XCTAssertNotNil(pasteboard.data(forType: Self.transientType))
        XCTAssertNotNil(pasteboard.data(forType: Self.autoGeneratedType))
    }

    func testAutoPasteFailureUsesGenericMessageInsteadOfAccessibilityBlame() {
        let state = VoiceState()
        state.sendCommand = { _ in }
        state.frontmostAppProvider = { NSRunningApplication.current }
        state.pasteScheduler = { _, block in block() }
        state.targetAppActivator = { _ in }
        state.dictationInsertionHandlerProvider = { { _ in false } }
        var pasteboardString: String?
        state.pasteboardWriter = { pasteboardString = $0 }
        state.pasteboardStringProvider = { pasteboardString }
        state.simulatedPasteHandler = { false }

        state.record()
        state.handleEvent([
            "type": "transcription",
            "text": "this is the full transcript ending with wow",
        ])

        XCTAssertTrue(state.confirmationText?.contains("Unverified") == true)
        XCTAssertFalse(state.confirmationText?.contains("Accessibility") ?? true)
    }

    func testRepasteWaitsForMenuFocusToSettle() {
        XCTAssertGreaterThan(VoicePastePlan.repaste.activationDelay, 0)
        XCTAssertEqual(VoicePastePlan.autoPaste.activationDelay, 0)
    }

    func testRecentTranscriptionsAreMostRecentFirst() {
        let state = VoiceState(
            recentTranscriptionsLoader: { [] },
            recentTranscriptionsSaver: { _ in },
            recentTranscriptionEntriesLoader: { [] },
            recentTranscriptionEntriesSaver: { _ in }
        )

        state.handleEvent([
            "type": "transcription",
            "text": "first note",
        ])
        state.handleEvent([
            "type": "transcription",
            "text": "second note",
        ])
        state.handleEvent([
            "type": "transcription",
            "text": "third note",
        ])

        XCTAssertEqual(state.recentTranscriptions, [
            "third note",
            "second note",
            "first note",
        ])
    }

    private static func capturePasteboardForTest() -> [[String: Data]] {
        NSPasteboard.general.pasteboardItems?.map { item in
            item.types.reduce(into: [String: Data]()) { result, type in
                if let data = item.data(forType: type) {
                    result[type.rawValue] = data
                }
            }
        } ?? []
    }

    private static func restorePasteboardForTest(_ saved: [[String: Data]]) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let items = saved.map { itemSnapshot -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in itemSnapshot {
                item.setData(data, forType: NSPasteboard.PasteboardType(type))
            }
            return item
        }
        if !items.isEmpty {
            pasteboard.writeObjects(items)
        }
    }
}
