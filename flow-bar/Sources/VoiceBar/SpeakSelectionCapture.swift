import AppKit
import ApplicationServices
import Carbon
import VoiceBarUI

final class SpeakSelectionCapture {
    private static let captureQueue = DispatchQueue(label: "com.voicelayer.speak-selection", qos: .utility)
    typealias Snapshot = [[(NSPasteboard.PasteboardType, Data)]]
    private let captureBlockReason: (SelectionCaptureResult.PreflightStage) -> SelectionCaptureResult?
    private let snapshotReader: () -> Snapshot?
    private let writeRestoredItems: ([NSPasteboardItem]) -> Bool
    private let readAXSelection: () -> String?
    private let pasteboardProvider: () -> NSPasteboard
    private var pasteboard: NSPasteboard { pasteboardProvider() }
    private let pasteboardChangeCount: () -> Int
    private let postCopy: () -> Bool
    private let readCopiedString: () -> String?
    private let schedule: (TimeInterval, @escaping () -> Void) -> Void
    private let now: () -> TimeInterval

    init(canCapture: (() -> Bool)? = nil,
         preflight: PreflightProviders? = nil,
         snapshotReader: (() -> Snapshot?)? = nil,
         writeRestoredItems: (([NSPasteboardItem]) -> Bool)? = nil,
         readAXSelection: @escaping () -> String? = SpeakSelectionCapture.readFocusedSelectedText,
         pasteboard: NSPasteboard? = nil,
         postCopy: @escaping () -> Bool = SpeakSelectionCapture.postCopyShortcut,
         readCopiedString: (() -> String?)? = nil,
         pasteboardChangeCount: (() -> Int)? = nil,
         schedule: @escaping (TimeInterval, @escaping () -> Void) -> Void = {
             SpeakSelectionCapture.captureQueue.asyncAfter(deadline: .now() + $0, execute: $1)
         },
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.captureBlockReason = canCapture.map { check in { _ in check() ? nil : .secureField } }
            ?? { Self.focusedCaptureBlockReason(stage: $0, providers: preflight ?? .live) }
        let board = { pasteboard ?? NSPasteboard.general }
        self.pasteboardProvider = board
        self.pasteboardChangeCount = pasteboardChangeCount ?? { board().changeCount }
        self.snapshotReader = snapshotReader ?? { SelectionPasteboardSnapshot.readInHelper(name: board().name.rawValue) }
        self.writeRestoredItems = writeRestoredItems ?? { board().writeObjects($0) }
        self.readAXSelection = readAXSelection
        self.postCopy = postCopy
        self.readCopiedString = readCopiedString ?? { board().string(forType: .string) }
        self.schedule = schedule
        self.now = now
    }

    func capture(completion: @escaping (SelectionCaptureResult) -> Void) {
        Self.captureQueue.async {
            if let reason = self.captureBlockReason(.initial) {
                Self.onMain { completion(reason) }
                return
            }
            // AX IPC can take multiple messaging timeouts. Never do it on the tap's run loop.
            let selectedText = self.readAXSelection()
            if let text = selectedText, !text.isEmpty {
                Self.onMain { completion(.completed(text).observed(axRead: .text, path: .ax)) }
            } else {
                let axRead: SelectionCaptureResult.AXRead = selectedText == nil ? .unavailable : .empty
                // Keep AppKit pasteboard/item access serialized with the app's other clipboard users.
                Self.onMain {
                    self.captureUsingPasteboard { completion($0.observed(axRead: axRead, path: .copy)) }
                }
            }
        }
    }

    private func captureUsingPasteboard(completion: @escaping (SelectionCaptureResult) -> Void) {
        // Unlike the transcript-paste snapshot, keep dynamic and org.nspasteboard
        // types too. Fail closed if any advertised representation cannot be saved.
        let changeCount = pasteboardChangeCount()
        Self.captureQueue.async {
            let snapshot = self.snapshotReader()
            let blockReason = self.captureBlockReason(.recheck)
            Self.onMain {
                guard let snapshot else { completion(.captureFailed); return }
                guard self.pasteboardChangeCount() == changeCount else { completion(.clipboardChanged); return }
                if let blockReason { completion(blockReason); return }
                self.copyAndPoll(snapshot: snapshot, changeCount: changeCount, completion: completion)
            }
        }
    }

    private func copyAndPoll(snapshot: Snapshot, changeCount: Int,
                             completion: @escaping (SelectionCaptureResult) -> Void) {
        let deadline = now() + 0.4
        func finish(_ result: SelectionCaptureResult, expectedChangeCount: Int) {
            switch restore(snapshot, expectedChangeCount: expectedChangeCount) {
            case .restored:
                completion(result)
            case .changed:
                completion(.clipboardChanged)
            case .failed:
                NSLog("[VoiceBar] Selection capture could not restore the pasteboard")
                completion(.clipboardRestoreFailed)
            }
        }
        guard postCopy() else { finish(.copyFailed, expectedChangeCount: changeCount); return }
        func poll() {
            Self.onMain { [self] in
                let observedChangeCount = pasteboard.changeCount
                if observedChangeCount != changeCount {
                    // More than one ownership change before we can read is ambiguous.
                    guard observedChangeCount == changeCount + 1 else {
                        finish(.clipboardChanged, expectedChangeCount: changeCount)
                        return
                    }
                    let text = readCopiedString()
                    let copiedChangeCount = pasteboard.changeCount
                    guard copiedChangeCount == observedChangeCount else {
                        finish(.clipboardChanged, expectedChangeCount: observedChangeCount)
                        return
                    }
                    finish(text?.isEmpty == false ? .completed(text) : .copyEmpty, expectedChangeCount: copiedChangeCount)
                } else if now() >= deadline {
                    finish(.copyTimedOut, expectedChangeCount: changeCount)
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

    /// Only the live adapter performs AX IPC; tests supply inert values and closures.
    struct PreflightProviders {
        var secureInput: () -> Bool
        var trusted: () -> Bool
        var focused: () -> (AXError, CFTypeRef?)
        var attribute: (CFTypeRef, String) -> (AXError, CFTypeRef?)

        static var live: Self {
            Self(secureInput: { IsSecureEventInputEnabled() }, trusted: { AXIsProcessTrusted() }, focused: {
                let system = AXUIElementCreateSystemWide()
                AXUIElementSetMessagingTimeout(system, 0.2)
                var value: CFTypeRef?
                let status = AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &value)
                if status == .success, let value, CFGetTypeID(value) == AXUIElementGetTypeID() {
                    AXUIElementSetMessagingTimeout(value as! AXUIElement, 0.2)
                }
                return (status, value)
            }, attribute: { element, key in
                var value: CFTypeRef?
                let status = AXUIElementCopyAttributeValue(element as! AXUIElement, key as CFString, &value)
                return (status, value)
            })
        }
    }

    private static func focusedCaptureBlockReason(stage: SelectionCaptureResult.PreflightStage,
                                                   providers: PreflightProviders) -> SelectionCaptureResult? {
        func blocked(_ reason: SelectionCaptureResult.PreflightReason, status: AXError? = nil,
                     secure: Bool = false) -> SelectionCaptureResult {
            (secure ? SelectionCaptureResult.secureField : .captureFailed)
                .preflightFailure(stage: stage, reason: reason, axStatus: status?.rawValue)
        }
        if providers.secureInput() { return blocked(.secureInput, secure: true) }
        guard providers.trusted() else { return blocked(.axUntrusted) }
        let (focusStatus, focused) = providers.focused()
        guard focusStatus == .success else { return blocked(.focusQueryFailed, status: focusStatus) }
        guard let focused else { return blocked(.focusAbsent, status: focusStatus) }
        guard CFGetTypeID(focused) == AXUIElementGetTypeID() else {
            return blocked(.focusWrongType, status: focusStatus)
        }
        let (roleStatus, roleValue) = providers.attribute(focused, kAXRoleAttribute)
        let role = roleStatus == .success ? roleValue as? String : nil
        let (subroleStatus, subroleValue) = providers.attribute(focused, kAXSubroleAttribute)
        let subrole = subroleStatus == .success ? subroleValue as? String : nil
        let secureInput = providers.secureInput()
        if isSecureFocus(role: role, subrole: subrole, secureInput: secureInput) {
            return blocked(secureInput ? .secureInput : .secureRole, status: roleStatus, secure: true)
        }
        // Preserve secure-input/subrole precedence even when the role query failed.
        guard roleStatus == .success else { return blocked(.roleQueryFailed, status: roleStatus) }
        guard let roleValue else { return blocked(.roleAbsent, status: roleStatus) }
        guard roleValue is String else { return blocked(.roleWrongType, status: roleStatus) }
        return nil
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
