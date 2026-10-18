import AppKit
import ApplicationServices
import Carbon
import VoiceBarUI

/// The AX calls the selection preflight makes, injectable so the Electron recovery is testable.
struct SelectionFocusAX {
    struct Focus: Equatable { var role: String?; var subrole: String? }
    var secureInputEnabled: () -> Bool
    var trusted: () -> Bool
    /// The system-wide focused element; `.success` always carries a focus.
    var queryFocus: () -> (AXError, Focus?)
    var frontmostPID: () -> pid_t?
    var setManualAccessibility: (pid_t) -> AXError
    var sleep: (TimeInterval) -> Void

    static let live = SelectionFocusAX(
        secureInputEnabled: { IsSecureEventInputEnabled() },
        trusted: { AXIsProcessTrusted() },
        queryFocus: {
            let system = AXUIElementCreateSystemWide()
            AXUIElementSetMessagingTimeout(system, 0.2)
            var focused: CFTypeRef?
            let status = AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused)
            guard status == .success else { return (status, nil) }
            guard let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return (.failure, nil) }
            let element = focused as! AXUIElement
            AXUIElementSetMessagingTimeout(element, 0.2)
            func attribute(_ key: String) -> String? {
                var value: CFTypeRef?
                guard AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success else { return nil }
                return value as? String
            }
            return (.success, Focus(role: attribute(kAXRoleAttribute), subrole: attribute(kAXSubroleAttribute)))
        },
        frontmostPID: {
            guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
                  pid != ProcessInfo.processInfo.processIdentifier else { return nil }
            return pid
        },
        setManualAccessibility: { pid in
            // Chromium keeps its AX tree off until an assistive client asks. Prefer Manual over
            // AXEnhancedUserInterface, which also changes window animation behaviour.
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, 0.2)
            return AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        },
        sleep: { Thread.sleep(forTimeInterval: $0) })
}

struct SelectionFocusPreflight {
    var blockReason: SelectionCaptureResult?
    var axEnable: SelectionCaptureResult.AXEnable?
    var retries = 0
    /// The focus stayed unreadable in an app that accepted AXManualAccessibility (Chromium family,
    /// whose password fields enable secure event input), so preserved-clipboard Copy may still run.
    var unreadableFocusAllowsCopy = false
}

final class SpeakSelectionCapture {
    private static let captureQueue = DispatchQueue(label: "com.voicelayer.speak-selection", qos: .utility)
    typealias Snapshot = [[(NSPasteboard.PasteboardType, Data)]]
    private let preflight: (_ recover: Bool, _ allowUnreadableFocus: Bool) -> SelectionFocusPreflight
    private let snapshotReader: () -> Snapshot?
    private let writeRestoredItems: ([NSPasteboardItem]) -> Bool
    private let readAXSelection: () -> String?
    private let pasteboard: NSPasteboard
    private let postCopy: () -> Bool
    private let readCopiedString: () -> String?
    private let schedule: (TimeInterval, @escaping () -> Void) -> Void
    private let now: () -> TimeInterval

    init(canCapture: (() -> Bool)? = nil,
         focusAX: SelectionFocusAX = .live,
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
        self.preflight = canCapture.map { check in { _, _ in SelectionFocusPreflight(blockReason: check() ? nil : .secureField) } }
            ?? { SpeakSelectionCapture.preflight(focusAX, recover: $0, allowUnreadableFocus: $1) }
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
            // AX IPC can take multiple messaging timeouts. Never do it on the tap's run loop.
            let preflight = self.preflight(true, false)
            let complete = { (result: SelectionCaptureResult) in
                completion(result.withPreflight(axEnable: preflight.axEnable, retries: preflight.retries))
            }
            if let reason = preflight.blockReason {
                Self.onMain { complete(reason) }
                return
            }
            let selectedText = preflight.unreadableFocusAllowsCopy ? nil : self.readAXSelection()
            if let text = selectedText, !text.isEmpty {
                Self.onMain { complete(.completed(text).observed(axRead: .text, path: .ax)) }
            } else {
                let axRead: SelectionCaptureResult.AXRead = preflight.unreadableFocusAllowsCopy ? .notAttempted
                    : selectedText == nil ? .unavailable : .empty
                // Keep AppKit pasteboard/item access serialized with the app's other clipboard users.
                Self.onMain {
                    self.captureUsingPasteboard(allowUnreadableFocus: preflight.unreadableFocusAllowsCopy) {
                        complete($0.observed(axRead: axRead, path: .copy))
                    }
                }
            }
        }
    }

    private func captureUsingPasteboard(allowUnreadableFocus: Bool,
                                        completion: @escaping (SelectionCaptureResult) -> Void) {
        // Unlike the transcript-paste snapshot, keep dynamic and org.nspasteboard
        // types too. Fail closed if any advertised representation cannot be saved.
        let changeCount = pasteboard.changeCount
        Self.captureQueue.async {
            let snapshot = self.snapshotReader()
            let blockReason = self.preflight(false, allowUnreadableFocus).blockReason
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

    static let focusRetryLimit = 8
    static let focusRetryStep: TimeInterval = 0.1

    /// Gates every read. A fresh Electron/Chromium app answers the focus query with kAXErrorNoValue
    /// until AXManualAccessibility is set on it, so set it once and re-query for under a second.
    static func preflight(_ ax: SelectionFocusAX, recover: Bool, allowUnreadableFocus: Bool) -> SelectionFocusPreflight {
        if ax.secureInputEnabled() { return SelectionFocusPreflight(blockReason: .secureField) }
        guard ax.trusted() else { return SelectionFocusPreflight(blockReason: .captureFailed) }
        var (status, focus) = ax.queryFocus()
        var result = SelectionFocusPreflight()
        if recover, status == .noValue || status == .cannotComplete, let pid = ax.frontmostPID() {
            guard ax.setManualAccessibility(pid) == .success else {
                result.axEnable = .failed
                result.blockReason = .captureFailed
                return result
            }
            result.axEnable = .attempted
            while status != .success, result.retries < focusRetryLimit {
                ax.sleep(focusRetryStep)
                result.retries += 1
                (status, focus) = ax.queryFocus()
            }
            if status == .success {
                result.axEnable = .set
            } else {
                result.unreadableFocusAllowsCopy = true
            }
        } else if !recover, allowUnreadableFocus, status == .noValue || status == .cannotComplete {
            result.unreadableFocusAllowsCopy = true
        }
        // An unreadable focus cannot establish permission to synthesize Copy, except in an app that
        // accepted AXManualAccessibility while secure event input stays off.
        guard status == .success, let focus else {
            if result.unreadableFocusAllowsCopy, !ax.secureInputEnabled() { return result }
            result.unreadableFocusAllowsCopy = false
            result.blockReason = .captureFailed
            return result
        }
        if isSecureFocus(role: focus.role, subrole: focus.subrole, secureInput: ax.secureInputEnabled()) {
            result.blockReason = .secureField
        } else if focus.role == nil {
            result.blockReason = .captureFailed
        }
        return result
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
