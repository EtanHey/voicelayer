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
        guard writeValue(updatedValue) else {
            writePasteboard(replacement)
            return postPasteShortcut()
                ? .clipboardFallback("Pasted fallback")
                : .failed("AX write failed")
        }

        if readBackValue() == updatedValue {
            return .axVerified("Applied to selection")
        }

        writePasteboard(replacement)
        return postPasteShortcut()
            ? .clipboardFallback("Pasted fallback")
            : .failed("AX verification failed")
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
