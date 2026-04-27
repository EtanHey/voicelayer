import AppKit
import ApplicationServices
import Foundation

struct CommandModeSelectionSnapshot: Equatable {
    var value: String
    var selectedRange: NSRange
}

enum CommandModeApplyResult: Equatable {
    case axVerified(String)
    case clipboardFallback(String)
    case failed(String)
}

enum AXWriteDisposition: Equatable {
    case failed
    case appliedVerified
    case appliedUnverified
}

final class CommandModeAXHelper {
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

    static func captureFocusedInsertionHandler() -> ((String) -> Bool)? {
        guard AXIsProcessTrusted(), let element = focusedElement() else { return nil }
        return { text in
            insertText(text, into: element)
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
        return AXUIElementSetAttributeValue(
            element,
            kAXValueAttribute as CFString,
            value as CFTypeRef
        ) == .success
    }

    private static func insertText(_ text: String, into element: AXUIElement) -> Bool {
        guard let value = readAttributeString(element, attribute: kAXValueAttribute as CFString),
              let selectedRange = readSelectedRange(element),
              let swiftRange = Range(selectedRange, in: value)
        else {
            return false
        }

        let updatedValue = value.replacingCharacters(in: swiftRange, with: text)
        let disposition = assessAXWrite(
            expectedValue: updatedValue,
            didWrite: AXUIElementSetAttributeValue(
                element,
                kAXValueAttribute as CFString,
                updatedValue as CFTypeRef
            ) == .success,
            readBackValue: readAttributeString(element, attribute: kAXValueAttribute as CFString)
        )
        guard disposition != .failed else {
            return false
        }

        let insertionLocation = selectedRange.location + (text as NSString).length
        _ = writeSelectedRange(NSRange(location: insertionLocation, length: 0), to: element)
        return true
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
