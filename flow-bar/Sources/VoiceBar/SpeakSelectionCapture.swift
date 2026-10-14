import AppKit
import ApplicationServices

final class SpeakSelectionCapture {
    private static let captureQueue = DispatchQueue(label: "com.voicelayer.speak-selection", qos: .utility)
    private let readAXSelection: () -> String?
    private let pasteboard: NSPasteboard
    private let postCopy: () -> Bool
    private let readCopiedString: () -> String?
    private let schedule: (TimeInterval, @escaping () -> Void) -> Void
    private let now: () -> TimeInterval

    init(readAXSelection: @escaping () -> String? = SpeakSelectionCapture.readFocusedSelectedText,
         pasteboard: NSPasteboard = .general,
         postCopy: @escaping () -> Bool = SpeakSelectionCapture.postCopyShortcut,
         readCopiedString: (() -> String?)? = nil,
         schedule: @escaping (TimeInterval, @escaping () -> Void) -> Void = {
             SpeakSelectionCapture.captureQueue.asyncAfter(deadline: .now() + $0, execute: $1)
         },
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.readAXSelection = readAXSelection
        self.pasteboard = pasteboard
        self.postCopy = postCopy
        self.readCopiedString = readCopiedString ?? { pasteboard.string(forType: .string) }
        self.schedule = schedule
        self.now = now
    }

    func capture(completion: @escaping (String?) -> Void) {
        Self.captureQueue.async {
            // AX IPC can take multiple messaging timeouts. Never do it on the tap's run loop.
            if let text = self.readAXSelection(), !text.isEmpty {
                Self.onMain { completion(text) }
            } else {
                // Keep AppKit pasteboard/item access serialized with the app's other clipboard users.
                Self.onMain { self.captureUsingPasteboard(completion: completion) }
            }
        }
    }

    private func captureUsingPasteboard(completion: @escaping (String?) -> Void) {
        // Unlike the transcript-paste snapshot, keep dynamic and org.nspasteboard
        // types too. Fail closed if any advertised representation cannot be saved.
        let changeCount = pasteboard.changeCount
        guard let snapshot = snapshot(), pasteboard.changeCount == changeCount else {
            completion(nil)
            return
        }
        let deadline = now() + 0.4
        func finish(_ text: String?, expectedChangeCount: Int) {
            switch restore(snapshot, expectedChangeCount: expectedChangeCount) {
            case .restored:
                completion(text)
            case .changed:
                completion(nil) // A competing copy makes the captured text untrustworthy too.
            case .failed:
                NSLog("[VoiceBar] Selection capture could not restore the pasteboard")
                completion(nil)
            }
        }
        guard postCopy() else { finish(nil, expectedChangeCount: changeCount); return }
        func poll() {
            Self.onMain { [self] in
                let observedChangeCount = pasteboard.changeCount
                if observedChangeCount != changeCount {
                    // More than one ownership change before we can read is ambiguous.
                    guard observedChangeCount == changeCount + 1 else {
                        finish(nil, expectedChangeCount: changeCount)
                        return
                    }
                    let text = readCopiedString()
                    let copiedChangeCount = pasteboard.changeCount
                    guard copiedChangeCount == observedChangeCount else {
                        finish(nil, expectedChangeCount: observedChangeCount)
                        return
                    }
                    finish(text?.isEmpty == false ? text : nil, expectedChangeCount: copiedChangeCount)
                } else if now() >= deadline {
                    finish(nil, expectedChangeCount: changeCount)
                } else {
                    schedule(min(0.02, deadline - now()), poll)
                }
            }
        }
        Self.captureQueue.async { poll() }
    }

    private static func onMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
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

    private enum RestorationResult { case restored, changed, failed }

    private func restore(_ snapshot: Snapshot, expectedChangeCount: Int) -> RestorationResult {
        var items: [NSPasteboardItem] = []
        for values in snapshot {
            let item = NSPasteboardItem()
            for (type, data) in values {
                guard item.setData(data, forType: type) else { return .failed }
            }
            items.append(item)
        }
        // Check immediately before taking ownership, after preparing every item.
        guard pasteboard.changeCount == expectedChangeCount else { return .changed }
        pasteboard.clearContents()
        return items.isEmpty || pasteboard.writeObjects(items) ? .restored : .failed
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
