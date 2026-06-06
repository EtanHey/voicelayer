import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

struct FrontmostSelectionReadResult: Equatable {
    enum Source: String {
        case accessibilitySelectedText
        case clipboardFallback
    }

    var text: String
    var source: Source
}

enum FrontmostSelectionReader {
    static func readCurrentSelection() -> FrontmostSelectionReadResult? {
        if let text = readAccessibilitySelection() {
            return FrontmostSelectionReadResult(text: text, source: .accessibilitySelectedText)
        }

        if let text = readClipboardSelectionFallback() {
            return FrontmostSelectionReadResult(text: text, source: .clipboardFallback)
        }

        return nil
    }

    private static func readAccessibilitySelection() -> String? {
        guard let frontmost = NSWorkspace.shared.frontmostApplication else { return nil }

        let appElement = AXUIElementCreateApplication(frontmost.processIdentifier)
        var focusedValue: CFTypeRef?
        let focusedResult = AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedValue
        )

        let selectionElement: AXUIElement
        if focusedResult == .success,
           let focusedValue,
           CFGetTypeID(focusedValue) == AXUIElementGetTypeID() {
            selectionElement = focusedValue as! AXUIElement
        } else {
            selectionElement = appElement
        }

        var selectedTextValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            selectionElement,
            kAXSelectedTextAttribute as CFString,
            &selectedTextValue
        ) == .success,
            let selectedText = selectedTextValue as? String
        else {
            return nil
        }

        let trimmed = selectedText.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func readClipboardSelectionFallback() -> String? {
        guard let source = CGEventSource(stateID: .hidSystemState) else { return nil }

        let pasteboard = NSPasteboard.general
        let snapshot = PasteboardSnapshot.capture(from: pasteboard)

        // AX is preferred because it reads kAXSelectedTextAttribute without side effects.
        // Some apps do not expose selected text through AX, so this fallback briefly
        // sends Cmd+C, reads the clipboard, then restores the previous pasteboard.
        pasteboard.clearContents()
        postCommandC(using: source)
        Thread.sleep(forTimeInterval: 0.08)

        let selected = pasteboard.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        snapshot.restore(to: pasteboard)

        guard let selected, !selected.isEmpty else { return nil }
        return selected
    }

    private static func postCommandC(using source: CGEventSource) {
        let cKey: CGKeyCode = 0x08
        let cDown = CGEvent(keyboardEventSource: source, virtualKey: cKey, keyDown: true)
        let cUp = CGEvent(keyboardEventSource: source, virtualKey: cKey, keyDown: false)
        cDown?.flags = .maskCommand
        cUp?.flags = .maskCommand
        cDown?.post(tap: .cghidEventTap)
        cUp?.post(tap: .cghidEventTap)
    }
}

private struct PasteboardSnapshot {
    var items: [[String: Data]]

    static func capture(from pasteboard: NSPasteboard) -> PasteboardSnapshot {
        let items = pasteboard.pasteboardItems?.compactMap { item -> [String: Data]? in
            let values = item.types.reduce(into: [String: Data]()) { result, type in
                if let data = item.data(forType: type) {
                    result[type.rawValue] = data
                }
            }
            return values.isEmpty ? nil : values
        } ?? []
        return PasteboardSnapshot(items: items)
    }

    func restore(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        let restoredItems = items.map { itemSnapshot -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in itemSnapshot {
                item.setData(data, forType: NSPasteboard.PasteboardType(type))
            }
            return item
        }
        pasteboard.writeObjects(restoredItems)
    }
}
