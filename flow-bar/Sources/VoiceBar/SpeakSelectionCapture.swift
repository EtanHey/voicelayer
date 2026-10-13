import AppKit
import ApplicationServices

final class SpeakSelectionCapture {
    private let readAXSelection: () -> String?
    private let pasteboard: NSPasteboard
    private let postCopy: () -> Bool
    private let schedule: (TimeInterval, @escaping () -> Void) -> Void
    private let now: () -> TimeInterval

    init(readAXSelection: @escaping () -> String? = SpeakSelectionCapture.readFocusedSelectedText,
         pasteboard: NSPasteboard = .general,
         postCopy: @escaping () -> Bool = SpeakSelectionCapture.postCopyShortcut,
         schedule: @escaping (TimeInterval, @escaping () -> Void) -> Void = {
             DispatchQueue.main.asyncAfter(deadline: .now() + $0, execute: $1)
         },
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.readAXSelection = readAXSelection
        self.pasteboard = pasteboard
        self.postCopy = postCopy
        self.schedule = schedule
        self.now = now
    }

    func capture(completion: @escaping (String?) -> Void) {
        if let text = readAXSelection(), !text.isEmpty {
            completion(text)
            return
        }

        // Unlike the transcript-paste snapshot, keep dynamic and org.nspasteboard
        // types too. Fail closed if any advertised representation cannot be saved.
        let changeCount = pasteboard.changeCount
        guard let snapshot = snapshot(), pasteboard.changeCount == changeCount else {
            completion(nil)
            return
        }
        let deadline = now() + 0.4
        func finish(_ text: String?) {
            let restored = restore(snapshot)
            if !restored { NSLog("[VoiceBar] Selection capture could not restore the pasteboard") }
            completion(restored ? text : nil)
        }
        guard postCopy() else { finish(nil); return }
        func poll() {
            if pasteboard.changeCount != changeCount {
                let text = pasteboard.string(forType: .string)
                finish(text?.isEmpty == false ? text : nil)
            } else if now() >= deadline {
                finish(nil)
            } else {
                schedule(min(0.02, deadline - now()), poll)
            }
        }
        poll()
    }

    private typealias Snapshot = [[(NSPasteboard.PasteboardType, Data)]]

    private func snapshot() -> Snapshot? {
        guard let items = pasteboard.pasteboardItems else {
            return (pasteboard.types ?? []).isEmpty ? [] : nil
        }
        var saved: Snapshot = []
        for item in items {
            var values: [(NSPasteboard.PasteboardType, Data)] = []
            for type in item.types {
                guard let data = item.data(forType: type) else { return nil }
                values.append((type, data))
            }
            saved.append(values)
        }
        return saved
    }

    private func restore(_ snapshot: Snapshot) -> Bool {
        var items: [NSPasteboardItem] = []
        for values in snapshot {
            let item = NSPasteboardItem()
            for (type, data) in values {
                guard item.setData(data, forType: type) else { return false }
            }
            items.append(item)
        }
        pasteboard.clearContents()
        return items.isEmpty || pasteboard.writeObjects(items)
    }

    private static func readFocusedSelectedText() -> String? {
        guard AXIsProcessTrusted() else { return nil }
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.2)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        let element = focused as! AXUIElement
        AXUIElementSetMessagingTimeout(element, 0.2)
        var selected: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &selected) == .success
        else { return nil }
        return selected as? String
    }

    private static func postCopyShortcut() -> Bool {
        guard AXIsProcessTrusted(),
              let source = CGEventSource(stateID: .privateState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: 0x08, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 0x08, keyDown: false) else { return false }
        // Option may still be held. The synthetic chord must contain only Command.
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }
}
