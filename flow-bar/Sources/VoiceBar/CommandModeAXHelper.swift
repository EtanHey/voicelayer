import AppKit
import ApplicationServices
import Foundation
import VoiceBarUI

struct CommandModeSelectionSnapshot: Equatable {
    var value: String
    var selectedRange: NSRange
}

enum AXWriteDisposition: Equatable {
    case failed
    case appliedVerified
    case appliedUnverified
}

enum AXEnabledAttributeRead: Equatable {
    case value(Bool), absent, failure(AXError)

    var value: Bool? { if case .value(let value) = self { return value }; return nil }
    var error: AXError? { if case .failure(let error) = self { return error }; return nil }
}

enum AXInsertionStrategy: Equatable {
    case valueRewrite
    case selectionLocal
    case requiresNativeProof
    case selectedTextStreaming(maxChunkUTF16Length: Int, interChunkDelay: TimeInterval)
}

enum AXSelectedTextStreamingDisposition: Equatable {
    case failedBeforeWrite
    case partiallyApplied(writtenChunkCount: Int, totalChunkCount: Int)
    case applied(writtenChunkCount: Int)

    var suppressesWholeTranscriptFallback: Bool {
        self != .failedBeforeWrite
    }
}

final class CommandModeAXHelper {
    private static let atomicValueRewriteBundleIdentifiers = Set([
        "com.cmuxterm.app",
    ])

    private let readSelection: () -> CommandModeSelectionSnapshot?
    private let writeValue: (String) -> Bool
    private let readBackValue: () -> String?
    private let writePasteboard: (String) -> Void
    private let postPasteShortcut: () -> Bool

    init(
        readSelection: @escaping () -> CommandModeSelectionSnapshot? = CommandModeAXHelper.readFocusedSelectionSnapshot,
        writeValue: @escaping (String) -> Bool = CommandModeAXHelper.writeFocusedValue,
        readBackValue: @escaping () -> String? = CommandModeAXHelper.readFocusedValue,
        writePasteboard: @escaping (String) -> Void = CommandModeAXHelper.writeStringToPasteboard,
        postPasteShortcut: @escaping () -> Bool = CommandModeAXHelper.postPasteShortcutLive
    ) {
        self.readSelection = readSelection
        self.writeValue = writeValue
        self.readBackValue = readBackValue
        self.writePasteboard = writePasteboard
        self.postPasteShortcut = postPasteShortcut
    }

    func applyReplacement(_ replacement: String) -> CommandModeApplyResult {
        guard let snapshot = readSelection() else {
            writePasteboard(replacement)
            return postPasteShortcut()
                ? .clipboardFallback("Pasted fallback")
                : .failed("No writable selection")
        }

        guard let swiftRange = Range(snapshot.selectedRange, in: snapshot.value) else {
            writePasteboard(replacement)
            return postPasteShortcut()
                ? .clipboardFallback("Pasted fallback")
                : .failed("Invalid selection range")
        }

        let updatedValue = snapshot.value.replacingCharacters(in: swiftRange, with: replacement)
        let disposition = Self.assessAXWrite(
            expectedValue: updatedValue,
            didWrite: writeValue(updatedValue),
            readBackValue: readBackValue()
        )
        guard disposition != .failed else {
            writePasteboard(replacement)
            return postPasteShortcut()
                ? .clipboardFallback("Pasted fallback")
                : .failed("AX write failed")
        }
        return .axVerified("Applied to selection")
    }

    static func captureFocusedInsertionHandler() -> AsyncDictationInsertionHandler? {
        guard AXIsProcessTrusted(), let element = focusedElement() else { return nil }
        return { text, completion in
            insertText(text, into: element) { result in
                DispatchQueue.main.async { completion(result) }
            }
        }
    }

    /// Captures focus identity and metadata only; never reads the element's text.
    static func captureFocusedTargetEligibility() -> DictationFocusedTargetEligibility? {
        guard AXIsProcessTrusted() else {
            logNativePaste("paste_native_focus", ["reason": "ax_untrusted"])
            return nil
        }
        guard let element = focusedElement() else {
            logNativePaste("paste_native_focus", ["reason": "focused_element_unavailable"])
            return nil
        }
        var pid = pid_t()
        guard AXUIElementGetPid(element, &pid) == .success else {
            logNativePaste("paste_native_focus", ["reason": "focused_pid_unavailable"])
            return nil
        }
        let window = readElement(element, attribute: kAXWindowAttribute as CFString)
        return targetEligibility(element, pid: pid) {
            guard AXIsProcessTrusted() else { return focusDeclined("ax_untrusted", pid: pid) }
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
                return focusDeclined("frontmost_pid_changed", pid: pid)
            }
            guard let current = focusedElement() else { return focusDeclined("focused_element_unavailable", pid: pid) }
            guard CFEqual(current, element) else { return focusDeclined("element_changed", pid: pid) }
            if let window {
                guard let currentWindow = readElement(current, attribute: kAXWindowAttribute as CFString) else {
                    return focusDeclined("window_unavailable", pid: pid)
                }
                guard CFEqual(currentWindow, window) else { return focusDeclined("window_changed", pid: pid) }
            }
            let rechecked = targetEligibility(current, pid: pid, matchesCurrentFocus: { true })
            let reason = rechecked.typingRejectionReason(into: pid)
            var details = rechecked.diagnosticDetails
            details["reason"] = reason ?? "eligible"
            details["focusedPID"] = String(pid)
            details["sameElement"] = "true"
            details["sameWindow"] = window == nil ? "not_captured" : "true"
            logNativePaste("paste_native_focus_revalidated", details)
            return reason == nil
        }
    }

    static func typingEligibility(
        processIdentifier: pid_t, role: String?, subrole: String?, enabled: Bool?, editable: Bool?,
        selectedTextSettable: Bool, valueSettable: Bool, protectedContent: Bool,
        enabledReadError: AXError? = nil,
        matchesCurrentFocus: @escaping () -> Bool
    ) -> DictationFocusedTargetEligibility {
        // TextEdit omits AXEnabled; writable text is disabled only by an explicit false.
        DictationFocusedTargetEligibility(
            processIdentifier: processIdentifier, role: role,
            isEditable: enabledReadError == nil && enabled != false && (editable ?? (selectedTextSettable || valueSettable)),
            isSecure: subrole == kAXSecureTextFieldSubrole || protectedContent,
            matchesCurrentFocus: matchesCurrentFocus,
            diagnosticDetails: [
                "enabledAttribute": enabledReadError == nil ? enabled.map(String.init) ?? "nil" : "error",
                "enabledReadStatus": enabledReadError.map { String($0.rawValue) } ?? "ok_or_absent",
                "editableAttribute": editable.map(String.init) ?? "nil",
                "selectedTextSettable": String(selectedTextSettable),
                "valueSettable": String(valueSettable),
                "protectedContent": String(protectedContent),
                "subrole": subrole ?? "nil",
            ]
        )
    }

    private static func targetEligibility(
        _ element: AXUIElement, pid: pid_t, matchesCurrentFocus: @escaping () -> Bool
    ) -> DictationFocusedTargetEligibility {
        let enabled = readEnabledAttribute(element)
        return typingEligibility(
            processIdentifier: pid,
            role: readAttributeString(element, attribute: kAXRoleAttribute as CFString),
            subrole: readAttributeString(element, attribute: kAXSubroleAttribute as CFString),
            enabled: enabled.value,
            editable: readAttributeBool(element, attribute: "AXEditable" as CFString),
            selectedTextSettable: isSettable(element, attribute: kAXSelectedTextAttribute as CFString),
            valueSettable: isSettable(element, attribute: kAXValueAttribute as CFString),
            protectedContent: readAttributeBool(element, attribute: "AXProtectedContent" as CFString) == true,
            enabledReadError: enabled.error,
            matchesCurrentFocus: matchesCurrentFocus
        )
    }

    private static func focusedElement() -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focused
        )
        guard status == .success, let focused else { return nil }
        return (focused as! AXUIElement)
    }

    private static func readFocusedSelectionSnapshot() -> CommandModeSelectionSnapshot? {
        guard let element = focusedElement(),
              let value = readAttributeString(element, attribute: kAXValueAttribute as CFString),
              let selectedRange = readSelectedRange(element)
        else {
            return nil
        }
        return CommandModeSelectionSnapshot(value: value, selectedRange: selectedRange)
    }

    private static func readFocusedValue() -> String? {
        guard let element = focusedElement() else { return nil }
        return readAttributeString(element, attribute: kAXValueAttribute as CFString)
    }

    private static func writeFocusedValue(_ value: String) -> Bool {
        guard let element = focusedElement() else { return false }
        return AXUIElementSetAttributeValue(
            element,
            kAXValueAttribute as CFString,
            value as CFTypeRef
        ) == .success
    }

    private static func insertText(
        _ text: String,
        into element: AXUIElement,
        completion: @escaping (DictationInsertionResult) -> Void
    ) -> Bool {
        guard let window = readElement(element, attribute: kAXWindowAttribute as CFString) else {
            return axDeclined("window_unavailable")
        }
        return beginSelectionLocalInsertion(
            text,
            readSnapshot: { selectionSnapshot(element) },
            isEligible: {
                guard insertionStrategy(text: text, focusedValueLength: 0,
                                        targetBundleIdentifier: targetBundleIdentifier(for: element)) == .selectionLocal else {
                    return axDeclined("strategy_not_selection_local")
                }
                guard isCurrentTarget(element, window: window) else { return false }
                var ancestor: AXUIElement? = element
                var reachedWindow = false
                for _ in 0..<32 {
                    guard let current = ancestor else { return axDeclined("ancestor_unavailable") }
                    if readAttributeString(current, attribute: kAXRoleAttribute as CFString) == "AXWebArea" {
                        // AX text/ranges do not certify rich nodes or browser selection.
                        // Native matched-prestate proof must precede enabling this route.
                        return axDeclined("web_ancestor")
                    }
                    if CFEqual(current, window) { reachedWindow = true; break }
                    ancestor = readElement(current, attribute: kAXParentAttribute as CFString)
                }
                let role = readAttributeString(element, attribute: kAXRoleAttribute as CFString)
                let subrole = readAttributeString(element, attribute: kAXSubroleAttribute as CFString)
                let enabled = readEnabledAttribute(element)
                if let reason = nativeWriteRejectionReason(
                    role: role, subrole: subrole,
                    protected: readAttributeBool(element, attribute: "AXProtectedContent" as CFString) == true,
                    enabled: enabled.value,
                    selectedTextSettable: isSettable(element, attribute: kAXSelectedTextAttribute as CFString),
                    selectedRangeSettable: isSettable(element, attribute: kAXSelectedTextRangeAttribute as CFString),
                    reachedWindow: reachedWindow, enabledReadError: enabled.error
                ) {
                    if let error = enabled.error {
                        logNativePaste("paste_native_ax_guard_failed", ["reason": reason,
                            "enabledAttribute": "error", "enabledReadStatus": String(error.rawValue)])
                        return false
                    }
                    return axDeclined(reason)
                }
                return true
            },
            isCurrentTarget: { isCurrentTarget(element, window: window) },
            writeSelection: {
                AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, $0 as CFTypeRef) == .success
            },
            writeCaret: { writeSelectedRange($0, to: element) },
            observeSettled: { work in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
            },
            onDecline: { _ = axDeclined($0) },
            completion: completion
        )
    }

    static func nativeWriteRejectionReason(
        role: String?, subrole: String?, protected: Bool, enabled: Bool?,
        selectedTextSettable: Bool, selectedRangeSettable: Bool, reachedWindow: Bool,
        enabledReadError: AXError? = nil
    ) -> String? {
        guard reachedWindow else { return "window_not_in_ancestors" }
        guard role == kAXTextFieldRole || role == kAXTextAreaRole else { return "non_text_role" }
        guard subrole != kAXSecureTextFieldSubrole else { return "secure_target" }
        guard !protected else { return "protected_content" }
        guard enabledReadError == nil else { return "enabled_read_failed" }
        guard enabled != false else { return "not_enabled" }
        guard selectedTextSettable else { return "selected_text_not_settable" }
        guard selectedRangeSettable else { return "selected_range_not_settable" }
        return nil
    }

    /// The live F5 transport seam: one selection-local write, never whole AXValue.
    /// Text and caret must match both immediately and after bounded host reconciliation.
    @discardableResult
    static func beginSelectionLocalInsertion(
        _ text: String,
        readSnapshot: @escaping () -> CommandModeSelectionSnapshot?,
        isEligible: () -> Bool,
        isCurrentTarget: @escaping () -> Bool,
        writeSelection: (String) -> Bool,
        writeCaret: (NSRange) -> Bool,
        observeSettled: (@escaping () -> Void) -> Void,
        onDecline: (String) -> Void = { _ in },
        completion: @escaping (DictationInsertionResult) -> Void
    ) -> Bool {
        // Eligibility owns its specific refusal diagnostic.
        guard isEligible() else { return false }
        guard let before = readSnapshot() else { onDecline("snapshot_unavailable"); return false }
        guard let range = Range(before.selectedRange, in: before.value) else { onDecline("invalid_range"); return false }
        guard isCurrentTarget() else { onDecline("target_changed"); return false }
        let expected = CommandModeSelectionSnapshot(
            value: before.value.replacingCharacters(in: range, with: text),
            selectedRange: NSRange(location: before.selectedRange.location + text.utf16.count, length: 0)
        )
        guard isCurrentTarget() else { onDecline("target_changed_before_write"); return false }
        guard readSnapshot() == before else { onDecline("selection_changed_before_write"); return false }
        // A rejected setter can still have changed the host. Never return false after
        // attempting a write and never dispatch a full retry from uncertain readback.
        guard writeSelection(text) else {
            completion(.appliedUnverified)
            return true
        }
        guard isCurrentTarget(), readSnapshot()?.value == expected.value else {
            completion(.appliedUnverified)
            return true
        }
        let caretAccepted = writeCaret(expected.selectedRange)
        let immediateMatches = caretAccepted && readSnapshot() == expected && isCurrentTarget()
        observeSettled {
            completion(immediateMatches && isCurrentTarget() && readSnapshot() == expected
                       ? .verified : .appliedUnverified)
        }
        return true
    }

    static func insertionStrategy(
        text: String,
        focusedValueLength: Int,
        targetBundleIdentifier: String?
    ) -> AXInsertionStrategy {
        // These recorded rich hosts cannot certify node/caret mapping from AX text,
        // even if their accessibility tree omits an AXWebArea ancestor.
        if targetBundleIdentifier == "com.t3tools.t3code" || targetBundleIdentifier == "net.imput.helium" {
            return .requiresNativeProof
        }
        if let targetBundleIdentifier,
           atomicValueRewriteBundleIdentifiers.contains(targetBundleIdentifier) {
            return .valueRewrite
        }
        return .selectionLocal
    }

    private static func selectionSnapshot(_ element: AXUIElement) -> CommandModeSelectionSnapshot? {
        guard let value = readAttributeString(element, attribute: kAXValueAttribute as CFString),
              let selectedRange = readSelectedRange(element) else { return nil }
        return CommandModeSelectionSnapshot(value: value, selectedRange: selectedRange)
    }

    private static func isCurrentTarget(_ element: AXUIElement, window: AXUIElement) -> Bool {
        var pid = pid_t()
        guard AXUIElementGetPid(element, &pid) == .success else { return axDeclined("focused_pid_unavailable") }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return axDeclined("frontmost_pid_mismatch") }
        guard let focused = focusedElement() else { return axDeclined("focused_element_unavailable") }
        guard CFEqual(focused, element) else { return axDeclined("element_changed") }
        guard let currentWindow = readElement(focused, attribute: kAXWindowAttribute as CFString) else {
            return axDeclined("current_window_unavailable")
        }
        guard CFEqual(currentWindow, window) else { return axDeclined("window_changed") }
        return true
    }

    private static func axDeclined(_ reason: String) -> Bool {
        logNativePaste("paste_native_ax_guard_failed", ["reason": reason])
        return false
    }

    private static func focusDeclined(_ reason: String, pid: pid_t) -> Bool {
        logNativePaste("paste_native_focus_revalidated", ["reason": reason, "focusedPID": String(pid)])
        return false
    }

    private static func logNativePaste(_ event: String, _ details: [String: String]) {
        let fields = details.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
        NSLog("[VoiceBar][diag] %@ %@", event, fields)
    }

    private static func readElement(_ element: AXUIElement, attribute: CFString) -> AXUIElement? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &raw) == .success,
              let raw, CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        return (raw as! AXUIElement)
    }

    private static func readAttributeBool(_ element: AXUIElement, attribute: CFString) -> Bool? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &raw) == .success else { return nil }
        return raw as? Bool
    }

    static func decodeEnabledAttribute(status: AXError, value: Bool?) -> AXEnabledAttributeRead {
        switch status {
        case .attributeUnsupported, .noValue: return .absent
        case .success: return value.map(AXEnabledAttributeRead.value) ?? .failure(.failure)
        default: return .failure(status)
        }
    }

    private static func readEnabledAttribute(_ element: AXUIElement) -> AXEnabledAttributeRead {
        var raw: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, kAXEnabledAttribute as CFString, &raw)
        return decodeEnabledAttribute(status: status, value: raw as? Bool)
    }

    private static func isSettable(_ element: AXUIElement, attribute: CFString) -> Bool {
        var settable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(element, attribute, &settable) == .success && settable.boolValue
    }

    static func selectedTextChunks(
        for text: String,
        maxUTF16Length: Int
    ) -> [String] {
        guard !text.isEmpty else { return [] }
        let maxLength = max(1, maxUTF16Length)
        var chunks: [String] = []
        var current = ""
        var currentLength = 0

        for scalar in text.unicodeScalars {
            let scalarString = String(scalar)
            let scalarLength = (scalarString as NSString).length
            if currentLength + scalarLength > maxLength, !current.isEmpty {
                chunks.append(current)
                current = ""
                currentLength = 0
            }
            current.append(scalarString)
            currentLength += scalarLength
        }

        if !current.isEmpty {
            chunks.append(current)
        }
        return chunks
    }

    static func beginSelectedTextStreaming(
        for text: String,
        maxUTF16Length: Int,
        interChunkDelay: TimeInterval,
        writeChunk: @escaping (String) -> Bool,
        enqueueRemainder: (@escaping () -> Void) -> Void,
        sleep: @escaping (TimeInterval) -> Void,
        onCompletion: @escaping (AXSelectedTextStreamingDisposition) -> Void
    ) -> Bool {
        let chunks = selectedTextChunks(for: text, maxUTF16Length: maxUTF16Length)
        guard let firstChunk = chunks.first else {
            onCompletion(.applied(writtenChunkCount: 0))
            return true
        }
        guard writeChunk(firstChunk) else {
            onCompletion(.failedBeforeWrite)
            return false
        }
        guard chunks.count > 1 else {
            onCompletion(.applied(writtenChunkCount: 1))
            return true
        }

        enqueueRemainder {
            var writtenChunkCount = 1
            for chunk in chunks.dropFirst() {
                if interChunkDelay > 0 {
                    sleep(interChunkDelay)
                }
                guard writeChunk(chunk) else {
                    onCompletion(
                        .partiallyApplied(
                            writtenChunkCount: writtenChunkCount,
                            totalChunkCount: chunks.count
                        )
                    )
                    return
                }
                writtenChunkCount += 1
            }
            onCompletion(.applied(writtenChunkCount: writtenChunkCount))
        }
        return true
    }

    static func selectedTextStreamingDisposition(
        for text: String,
        maxUTF16Length: Int,
        interChunkDelay: TimeInterval,
        writeChunk: (String) -> Bool,
        sleep: (TimeInterval) -> Void
    ) -> AXSelectedTextStreamingDisposition {
        let chunks = selectedTextChunks(for: text, maxUTF16Length: maxUTF16Length)
        guard !chunks.isEmpty else { return .applied(writtenChunkCount: 0) }

        var writtenChunkCount = 0
        for (index, chunk) in chunks.enumerated() {
            guard writeChunk(chunk) else {
                return writtenChunkCount == 0
                    ? .failedBeforeWrite
                    : .partiallyApplied(
                        writtenChunkCount: writtenChunkCount,
                        totalChunkCount: chunks.count
                    )
            }
            writtenChunkCount += 1
            if index < chunks.count - 1, interChunkDelay > 0 {
                sleep(interChunkDelay)
            }
        }
        return .applied(writtenChunkCount: writtenChunkCount)
    }

    static func assessAXWrite(
        expectedValue: String,
        didWrite: Bool,
        readBackValue: String?
    ) -> AXWriteDisposition {
        guard didWrite else { return .failed }
        guard let readBackValue else { return .appliedUnverified }
        return readBackValue == expectedValue ? .appliedVerified : .appliedUnverified
    }

    private static func readAttributeString(_ element: AXUIElement, attribute: CFString) -> String? {
        var raw: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, attribute, &raw)
        guard status == .success else { return nil }
        return raw as? String
    }

    private static func targetBundleIdentifier(for element: AXUIElement) -> String? {
        var pid = pid_t()
        guard AXUIElementGetPid(element, &pid) == .success else { return nil }
        return NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
    }

    private static func readSelectedRange(_ element: AXUIElement) -> NSRange? {
        var raw: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &raw
        )
        guard status == .success, let axValue = raw, CFGetTypeID(axValue) == AXValueGetTypeID() else { return nil }
        let value = axValue as! AXValue
        var range = CFRange()
        guard AXValueGetType(value) == .cfRange,
              AXValueGetValue(value, .cfRange, &range)
        else {
            return nil
        }
        return NSRange(location: range.location, length: range.length)
    }

    private static func writeSelectedRange(_ range: NSRange, to element: AXUIElement) -> Bool {
        var cfRange = CFRange(location: range.location, length: range.length)
        guard let value = AXValueCreate(.cfRange, &cfRange) else { return false }
        return AXUIElementSetAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            value
        ) == .success
    }

    private static func writeStringToPasteboard(_ string: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
    }

    private static func postPasteShortcutLive() -> Bool {
        guard AXIsProcessTrusted() else { return false }
        guard let source = CGEventSource(stateID: .hidSystemState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
        else {
            return false
        }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }
}
