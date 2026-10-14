import AppKit
import ApplicationServices
import Carbon
import VoiceBarUI

final class SpeakSelectionCapture {
    private static let captureQueue = DispatchQueue(label: "com.voicelayer.speak-selection", qos: .utility)
    typealias Snapshot = [[(NSPasteboard.PasteboardType, Data)]]
    private let captureBlockReason: () -> SelectionCaptureResult?
    private let snapshotReader: () -> Snapshot?
    private let writeRestoredItems: ([NSPasteboardItem]) -> Bool
    private let readAXSelection: () -> String?
    private let pasteboard: NSPasteboard
    private let postCopy: () -> Bool
    private let readCopiedString: () -> String?
    private let schedule: (TimeInterval, @escaping () -> Void) -> Void
    private let now: () -> TimeInterval

    init(canCapture: (() -> Bool)? = nil,
         snapshotReader: (() -> Snapshot?)? = nil,
         writeRestoredItems: (([NSPasteboardItem]) -> Bool)? = nil,
         readAXSelection: @escaping () -> String? = SpeakSelectionCapture.readFocusedSelectedText,
         pasteboard: NSPasteboard = .general,
         postCopy: @escaping () -> Bool = SpeakSelectionCapture.postCopyShortcut,
         readCopiedString: (() -> String?)? = nil,
         schedule: @escaping (TimeInterval, @escaping () -> Void) -> Void = {
             SpeakSelectionCapture.captureQueue.asyncAfter(deadline: .now() + $0, execute: $1)
         },
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.captureBlockReason = canCapture.map { check in { check() ? nil : .secureField } }
            ?? SpeakSelectionCapture.focusedCaptureBlockReason
        let pasteboardName = pasteboard.name.rawValue
        self.snapshotReader = snapshotReader ?? { SelectionPasteboardSnapshot.readInHelper(name: pasteboardName) }
        self.writeRestoredItems = writeRestoredItems ?? { pasteboard.writeObjects($0) }
        self.readAXSelection = readAXSelection
        self.pasteboard = pasteboard
        self.postCopy = postCopy
        self.readCopiedString = readCopiedString ?? { pasteboard.string(forType: .string) }
        self.schedule = schedule
        self.now = now
    }

    func capture(completion: @escaping (SelectionCaptureResult) -> Void) {
        Self.captureQueue.async {
            if let reason = self.captureBlockReason() {
                Self.onMain { completion(reason) }
                return
            }
            // AX IPC can take multiple messaging timeouts. Never do it on the tap's run loop.
            if let text = self.readAXSelection(), !text.isEmpty {
                Self.onMain { completion(.completed(text)) }
            } else {
                // Keep AppKit pasteboard/item access serialized with the app's other clipboard users.
                Self.onMain { self.captureUsingPasteboard(completion: completion) }
            }
        }
    }

    private func captureUsingPasteboard(completion: @escaping (SelectionCaptureResult) -> Void) {
        // Unlike the transcript-paste snapshot, keep dynamic and org.nspasteboard
        // types too. Fail closed if any advertised representation cannot be saved.
        let changeCount = pasteboard.changeCount
        Self.captureQueue.async {
            let snapshot = self.snapshotReader()
            let blockReason = self.captureBlockReason()
            Self.onMain {
                guard let snapshot else { completion(.captureFailed); return }
                guard self.pasteboard.changeCount == changeCount else { completion(.clipboardChanged); return }
                if let blockReason { completion(blockReason); return }
                self.copyAndPoll(snapshot: snapshot, changeCount: changeCount, completion: completion)
            }
        }
    }

    private func copyAndPoll(snapshot: Snapshot, changeCount: Int,
                             completion: @escaping (SelectionCaptureResult) -> Void) {
        let deadline = now() + 0.4
        func finish(_ text: String?, expectedChangeCount: Int) {
            switch restore(snapshot, expectedChangeCount: expectedChangeCount) {
            case .restored:
                completion(.completed(text))
            case .changed:
                completion(.clipboardChanged)
            case .failed:
                NSLog("[VoiceBar] Selection capture could not restore the pasteboard")
                completion(.clipboardRestoreFailed)
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

    private enum RestorationResult { case restored, changed, failed }

    private func restore(_ snapshot: Snapshot, expectedChangeCount: Int) -> RestorationResult {
        func prepareItems() -> [NSPasteboardItem]? {
            var items: [NSPasteboardItem] = []
            for values in snapshot {
                let item = NSPasteboardItem()
                for (type, data) in values {
                    guard item.setData(data, forType: type) else { return nil }
                }
                items.append(item)
            }
            return items
        }
        guard let items = prepareItems() else { return .failed }
        // Check immediately before taking ownership, after preparing every item.
        guard pasteboard.changeCount == expectedChangeCount else { return .changed }
        let clearedCount = pasteboard.clearContents()
        if items.isEmpty || writeRestoredItems(items) { return .restored }
        // Our data writes keep the generation; preserve a new clear/declare transaction.
        guard pasteboard.changeCount == clearedCount else { return .changed }
        // Reusing accepted items after clearing throws; build fresh items for the retry.
        guard let retryItems = prepareItems() else { return .failed }
        guard pasteboard.changeCount == clearedCount else { return .changed }
        let retryCount = pasteboard.clearContents()
        if writeRestoredItems(retryItems) { return .restored }
        return pasteboard.changeCount == retryCount ? .failed : .changed
    }

    static func isSecureFocus(role: String?, subrole: String?, secureInput: Bool) -> Bool {
        secureInput || role == (kAXSecureTextFieldSubrole as String) || subrole == (kAXSecureTextFieldSubrole as String)
    }

    private static func focusedCaptureBlockReason() -> SelectionCaptureResult? {
        if IsSecureEventInputEnabled() { return .secureField }
        guard AXIsProcessTrusted() else { return .captureFailed }
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.2)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return .captureFailed }
        let element = focused as! AXUIElement
        AXUIElementSetMessagingTimeout(element, 0.2)
        func attribute(_ key: String) -> String? {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success else { return nil }
            return value as? String
        }
        let role = attribute(kAXRoleAttribute)
        // An unreadable focus cannot establish permission to synthesize Copy.
        if isSecureFocus(role: role, subrole: attribute(kAXSubroleAttribute),
                         secureInput: IsSecureEventInputEnabled()) { return .secureField }
        return role == nil ? .captureFailed : nil
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
        var role: CFTypeRef?
        var subrole: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role) == .success else { return nil }
        AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole)
        guard !isSecureFocus(role: role as? String, subrole: subrole as? String,
                             secureInput: IsSecureEventInputEnabled()) else { return nil }
        var selected: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &selected) == .success
        else { return nil }
        return IsSecureEventInputEnabled() ? nil : selected as? String
    }

    private static func postCopyShortcut() -> Bool {
        guard !IsSecureEventInputEnabled(), AXIsProcessTrusted(),
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
