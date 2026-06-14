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

final class CommandModeAXHelper {
    /// Above this focused-element value length, the legacy whole-value rewrite is
    /// considered unsafe (it is the proxy for "would wedge a terminal pane"). We
    /// never fall back to a whole-value rewrite for values at/above this size.
    static let largeValueThreshold = 5000

    private let readSelection: () -> CommandModeSelectionSnapshot?
    private let writeValue: (String) -> Bool
    private let readBackValue: () -> String?
    /// Surgical insert primitive: set kAXSelectedText to ONLY the new text. Inserts
    /// at the caret / replaces the current selection — never reads or rewrites the
    /// full element value, so it cannot wedge a terminal.
    private let writeSelectedText: (String) -> Bool
    /// Current focused-element value length, used to guard the legacy fallback.
    private let readValueLength: () -> Int?

    init(
        readSelection: @escaping () -> CommandModeSelectionSnapshot? = CommandModeAXHelper.readFocusedSelectionSnapshot,
        writeValue: @escaping (String) -> Bool = CommandModeAXHelper.writeFocusedValue,
        readBackValue: @escaping () -> String? = CommandModeAXHelper.readFocusedValue,
        writeSelectedText: @escaping (String) -> Bool = CommandModeAXHelper.writeFocusedSelectedText,
        readValueLength: @escaping () -> Int? = CommandModeAXHelper.readFocusedValueLength
    ) {
        self.readSelection = readSelection
        self.writeValue = writeValue
        self.readBackValue = readBackValue
        self.writeSelectedText = writeSelectedText
        self.readValueLength = readValueLength
    }

    /// Insert `text` at the caret (or over the current selection) using the surgical
    /// kAXSelectedText primitive. Returns true on success.
    ///
    /// - Primary path: set kAXSelectedText to the chunk. On success → done; the whole
    ///   element value is NEVER read or rewritten (the wedge guard).
    /// - Guarded fallback: only when kAXSelectedText fails AND the current value is small
    ///   (< largeValueThreshold) do we fall back to the legacy whole-value rewrite. If the
    ///   value is large (or its length can't be read), return false — never do a large
    ///   whole-value rewrite.
    func insertAtCursor(_ text: String) -> Bool {
        if writeSelectedText(text) {
            return true
        }

        // kAXSelectedText rejected — only the legacy value-rewrite path can recover, and
        // only for small values. Large values are the wedge risk: bail out.
        guard let valueLength = readValueLength(), valueLength < Self.largeValueThreshold else {
            return false
        }

        guard let snapshot = readSelection(),
              let swiftRange = Range(snapshot.selectedRange, in: snapshot.value)
        else {
            return false
        }

        let updatedValue = snapshot.value.replacingCharacters(in: swiftRange, with: text)
        let disposition = Self.assessAXWrite(
            expectedValue: updatedValue,
            didWrite: writeValue(updatedValue),
            readBackValue: readBackValue()
        )
        return disposition != .failed
    }

    func applyReplacement(_ replacement: String) -> CommandModeApplyResult {
        guard let snapshot = readSelection() else {
            return .failed("No writable selection")
        }

        guard let swiftRange = Range(snapshot.selectedRange, in: snapshot.value) else {
            return .failed("Invalid selection range")
        }

        let updatedValue = snapshot.value.replacingCharacters(in: swiftRange, with: replacement)
        let disposition = Self.assessAXWrite(
            expectedValue: updatedValue,
            didWrite: writeValue(updatedValue),
            readBackValue: readBackValue()
        )
        guard disposition != .failed else {
            return .failed("AX write failed")
        }
        return .axVerified("Applied to selection")
    }

    static func captureFocusedInsertionHandler() -> ((String) -> Bool)? {
        guard AXIsProcessTrusted(), let element = focusedElement() else { return nil }
        let helper = CommandModeAXHelper(
            readSelection: { Self.readSelectionSnapshot(for: element) },
            writeValue: { Self.writeValue($0, to: element) },
            readBackValue: { Self.readAttributeString(element, attribute: kAXValueAttribute as CFString) },
            writeSelectedText: { Self.writeSelectedText($0, to: element) },
            readValueLength: { Self.readValueLength(for: element) }
        )
        return { text in
            helper.insertAtCursor(text)
        }
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
        return writeValue(value, to: element)
    }

    private static func readFocusedValueLength() -> Int? {
        guard let element = focusedElement() else { return nil }
        return readValueLength(for: element)
    }

    private static func writeFocusedSelectedText(_ text: String) -> Bool {
        guard let element = focusedElement() else { return false }
        return writeSelectedText(text, to: element)
    }

    // MARK: - Element-scoped live AX primitives

    private static func readSelectionSnapshot(for element: AXUIElement) -> CommandModeSelectionSnapshot? {
        guard let value = readAttributeString(element, attribute: kAXValueAttribute as CFString),
              let selectedRange = readSelectedRange(element)
        else {
            return nil
        }
        return CommandModeSelectionSnapshot(value: value, selectedRange: selectedRange)
    }

    private static func readValueLength(for element: AXUIElement) -> Int? {
        guard let value = readAttributeString(element, attribute: kAXValueAttribute as CFString) else {
            return nil
        }
        return (value as NSString).length
    }

    /// Surgical insert: replace the current selection (or insert at the caret) with ONLY
    /// `text`. Never reads or rewrites the full element value.
    private static func writeSelectedText(_ text: String, to element: AXUIElement) -> Bool {
        AXUIElementSetAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            text as CFTypeRef
        ) == .success
    }

    private static func writeValue(_ value: String, to element: AXUIElement) -> Bool {
        AXUIElementSetAttributeValue(
            element,
            kAXValueAttribute as CFString,
            value as CFTypeRef
        ) == .success
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

    private static func readSelectedRange(_ element: AXUIElement) -> NSRange? {
        var raw: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &raw
        )
        guard status == .success, let axValue = raw else { return nil }
        let value = axValue as! AXValue
        var range = CFRange()
        guard AXValueGetType(value) == .cfRange,
              AXValueGetValue(value, .cfRange, &range)
        else {
            return nil
        }
        return NSRange(location: range.location, length: range.length)
    }
}
