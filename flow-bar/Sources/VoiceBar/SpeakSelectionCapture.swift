import AppKit
import ApplicationServices
import Carbon
import VoiceBarUI

/// The AX calls the selection preflight makes, injectable so the Electron recovery is testable.
struct SelectionFocusAX {
    enum Failure: String {
        case focusAbsent = "focus_absent", focusWrongType = "focus_wrong_type"
        case roleQueryFailed = "role_query_failed", roleAbsent = "role_absent", roleWrongType = "role_wrong_type"
    }
    struct Focus: Equatable {
        var role: String?; var subrole: String?
        var failure: Failure? = nil
        var roleStatus: AXError = .success
        var subroleStatus: AXError = .success
        var subroleValueIsValid = true
        // Malformed successful focus responses still return .failure to preserve capture policy.
        var queryStatus: AXError? = nil
    }
    /// A PID alone can be reused; the kernel start time pins one process lifetime.
    struct AppIdentity: Equatable { var pid: pid_t; var startTime: UInt64 }
    var secureInputEnabled: () -> Bool
    var trusted: () -> Bool
    /// The system-wide focused element; `.success` always carries a focus.
    var queryFocus: () -> (AXError, Focus?)
    var frontmostApp: () -> AppIdentity?
    /// The unreadable-focus Copy policy: only a Chromium/Electron bundle qualifies, because Chromium turns on
    /// secure event input for password fields, which every preflight and the Copy shortcut still check.
    /// A successful AXManualAccessibility set alone proves nothing about how an app protects secrets.
    var isChromiumFamily: (AppIdentity) -> Bool
    var setManualAccessibility: (AppIdentity) -> AXError
    var sleep: (TimeInterval) -> Void
    // Fake AX adapters have no host policy unless they explicitly supply one.
    var bundleIdentifier: ((AppIdentity) -> String?)? = nil

    static let live = SelectionFocusAX(
        secureInputEnabled: { IsSecureEventInputEnabled() },
        trusted: { AXIsProcessTrusted() },
        queryFocus: {
            let system = AXUIElementCreateSystemWide()
            AXUIElementSetMessagingTimeout(system, 0.2)
            var focused: CFTypeRef?
            let status = AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused)
            guard status == .success else { return (status, nil) }
            if let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() {
                AXUIElementSetMessagingTimeout(focused as! AXUIElement, 0.2)
            }
            return decodeFocus(focused) { key in
                var value: CFTypeRef?
                let status = AXUIElementCopyAttributeValue(focused as! AXUIElement, key as CFString, &value)
                return (status, value)
            }
        },
        frontmostApp: {
            guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
                  pid != ProcessInfo.processInfo.processIdentifier else { return nil }
            var info = kinfo_proc()
            var size = MemoryLayout<kinfo_proc>.stride
            var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
            guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
            let start = info.kp_proc.p_un.__p_starttime
            return AppIdentity(pid: pid, startTime: UInt64(start.tv_sec) * 1_000_000 + UInt64(start.tv_usec))
        },
        isChromiumFamily: { app in
            ChromiumFamilyApps.contains(bundleURL: NSRunningApplication(processIdentifier: app.pid)?.bundleURL)
        },
        setManualAccessibility: { app in
            let pid = app.pid
            // Chromium keeps its AX tree off until an assistive client asks. Prefer Manual over
            // AXEnhancedUserInterface, which also changes window animation behaviour.
            let element = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(element, 0.2)
            return AXUIElementSetAttributeValue(element, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        },
        sleep: { Thread.sleep(forTimeInterval: $0) },
        bundleIdentifier: { NSRunningApplication(processIdentifier: $0.pid)?.bundleIdentifier })

    /// Decodes the existing query without additional AX calls or logging attribute values.
    static func decodeFocus(_ value: CFTypeRef?, attribute: (String) -> (AXError, CFTypeRef?)) -> (AXError, Focus?) {
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return (.failure, Focus(role: nil, subrole: nil,
                                    failure: value == nil ? .focusAbsent : .focusWrongType, queryStatus: .success))
        }
        let (status, roleValue) = attribute(kAXRoleAttribute)
        let (subroleStatus, subroleValue) = attribute(kAXSubroleAttribute)
        let failure: Failure? = status != .success ? .roleQueryFailed
            : roleValue == nil ? .roleAbsent : roleValue is String ? nil : .roleWrongType
        return (.success, Focus(role: status == .success ? roleValue as? String : nil,
                                subrole: subroleStatus == .success ? subroleValue as? String : nil,
                                failure: failure, roleStatus: status, subroleStatus: subroleStatus,
                                subroleValueIsValid: subroleValue == nil || subroleValue is String))
    }
}

struct SelectionFocusPreflight {
    var blockReason: SelectionCaptureResult?
    var axEnable: SelectionCaptureResult.AXEnable?
    var retries = 0
    var details: [String: String] = [:]
    var clipboardFocusResolved = false
    /// The focus stayed unreadable in this app, which accepted AXManualAccessibility (Chromium family,
    /// whose password fields enable secure event input). Preserved-clipboard Copy may run only while
    /// this exact process is still frontmost.
    var copyExemptApp: SelectionFocusAX.AppIdentity?
    var unreadableFocusAllowsCopy: Bool { copyExemptApp != nil }
}

final class SpeakSelectionCapture {
    private static let captureQueue = DispatchQueue(label: "com.voicelayer.speak-selection", qos: .utility)
    typealias Snapshot = [[(NSPasteboard.PasteboardType, Data)]]
    private let preflight: (_ recover: Bool, _ copyExemptApp: SelectionFocusAX.AppIdentity?) -> SelectionFocusPreflight
    private let frontmostApp: () -> SelectionFocusAX.AppIdentity?
    private let bundleIdentifier: ((SelectionFocusAX.AppIdentity) -> String?)?
    private let snapshotReader: () -> Snapshot?
    private let writeRestoredItems: ([NSPasteboardItem]) -> Bool
    private let readAXSelection: () -> String?
    private let pasteboard: NSPasteboard
    private let postCopy: () -> Bool
    private let readCopiedString: () -> String?
    private let clipboardChangeCount: () -> Int
    private let clipboardSecureInputEnabled: () -> Bool
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
         clipboardChangeCount: (() -> Int)? = nil,
         schedule: @escaping (TimeInterval, @escaping () -> Void) -> Void = {
             SpeakSelectionCapture.captureQueue.asyncAfter(deadline: .now() + $0, execute: $1)
         },
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.preflight = canCapture.map { check in { _, _ in SelectionFocusPreflight(blockReason: check() ? nil : .secureField) } }
            ?? { SpeakSelectionCapture.preflight(focusAX, recover: $0, copyExemptApp: $1) }
        self.frontmostApp = focusAX.frontmostApp
        self.bundleIdentifier = focusAX.bundleIdentifier
        let pasteboardName = pasteboard.name.rawValue
        self.snapshotReader = snapshotReader ?? { SelectionPasteboardSnapshot.readInHelper(name: pasteboardName) }
        self.writeRestoredItems = writeRestoredItems ?? { pasteboard.writeObjects($0) }
        self.readAXSelection = readAXSelection
        self.pasteboard = pasteboard
        self.postCopy = postCopy
        self.readCopiedString = readCopiedString ?? { pasteboard.string(forType: .string) }
        self.clipboardChangeCount = clipboardChangeCount ?? { pasteboard.changeCount }
        self.clipboardSecureInputEnabled = focusAX.secureInputEnabled
        self.schedule = schedule
        self.now = now
    }

    /// Explicit user action only. No Copy, snapshot, restoration, AX recovery or trust prompt.
    /// The admission closure is rechecked on main after each asynchronous secure-focus check.
    func readClipboard(isCurrent: @escaping () -> Bool,
                       completion: @escaping (SelectionCaptureResult) -> Void) {
        Self.captureQueue.async {
            let gate = self.preflight(false, nil)
            Self.onMain {
                guard isCurrent() else { completion(.captureFailed); return }
                if let reason = gate.blockReason { completion(reason); return }
                guard gate.clipboardFocusResolved else { completion(.captureFailed); return }
                guard !self.clipboardSecureInputEnabled() else { completion(.secureField); return }
                let generation = self.clipboardChangeCount()
                let text = self.readCopiedString()
                guard self.clipboardChangeCount() == generation else { completion(.clipboardChanged); return }
                Self.captureQueue.async {
                    let recheck = self.preflight(false, nil)
                    Self.onMain {
                        guard isCurrent() else { completion(.captureFailed); return }
                        if let reason = recheck.blockReason { completion(reason); return }
                        guard recheck.clipboardFocusResolved else { completion(.captureFailed); return }
                        guard !self.clipboardSecureInputEnabled() else { completion(.secureField); return }
                        guard self.clipboardChangeCount() == generation else { completion(.clipboardChanged); return }
                        completion(.completed(text).observed(axRead: .notAttempted, path: .clipboard))
                    }
                }
            }
        }
    }

    func capture(completion: @escaping (SelectionCaptureResult) -> Void) {
        Self.captureQueue.async {
            // AX IPC can take multiple messaging timeouts. Never do it on the tap's run loop.
            let preflight = self.preflight(true, nil)
            let complete = { (result: SelectionCaptureResult) in
                completion(result.withPreflight(axEnable: preflight.axEnable, retries: preflight.retries)
                    .withPreflightDetails(preflight.details))
            }
            if let reason = preflight.blockReason {
                Self.onMain { complete(reason) }
                return
            }
            // T3's AX selection can flatten lists. Its normal Copy preserves the original bytes.
            // This target pin grants no unreadable-focus exemption; only preflight can earn that.
            let intendedCopyApp = self.bundleIdentifier.flatMap { bundleIdentifier in
                self.frontmostApp().flatMap { bundleIdentifier($0) == "com.t3tools.t3code" ? $0 : nil }
            }
            let selectedText = preflight.unreadableFocusAllowsCopy ? nil : self.readAXSelection()
            if let text = selectedText, !text.isEmpty, intendedCopyApp == nil {
                Self.onMain { complete(.completed(text).observed(axRead: .text, path: .ax)) }
            } else {
                let axRead: SelectionCaptureResult.AXRead = preflight.unreadableFocusAllowsCopy ? .notAttempted
                    : selectedText == nil ? .unavailable : selectedText?.isEmpty == true ? .empty : .text
                // Keep AppKit pasteboard/item access serialized with the app's other clipboard users.
                Self.onMain {
                    self.captureUsingPasteboard(copyExemptApp: preflight.copyExemptApp,
                                                intendedCopyApp: intendedCopyApp) {
                        complete($0.observed(axRead: axRead, path: .copy))
                    }
                }
            }
        }
    }

    private func captureUsingPasteboard(copyExemptApp: SelectionFocusAX.AppIdentity?,
                                        intendedCopyApp: SelectionFocusAX.AppIdentity?,
                                        completion: @escaping (SelectionCaptureResult) -> Void) {
        // Unlike the transcript-paste snapshot, keep dynamic and org.nspasteboard
        // types too. Fail closed if any advertised representation cannot be saved.
        let changeCount = pasteboard.changeCount
        Self.captureQueue.async {
            let snapshot = self.snapshotReader()
            let recheck = self.preflight(false, copyExemptApp)
            Self.onMain {
                let complete = { (result: SelectionCaptureResult) in
                    completion(result.withPreflightDetails(recheck.details))
                }
                guard let snapshot else { complete(.captureFailed); return }
                guard self.pasteboard.changeCount == changeCount else { complete(.clipboardChanged); return }
                if let blockReason = recheck.blockReason { complete(blockReason); return }
                if let intendedCopyApp, self.frontmostApp() != intendedCopyApp {
                    complete(.captureFailed)
                    return
                }
                self.copyAndPoll(snapshot: snapshot, changeCount: changeCount, copyExemptApp: copyExemptApp,
                                 intendedCopyApp: intendedCopyApp,
                                 completion: complete)
            }
        }
    }

    private func copyAndPoll(snapshot: Snapshot, changeCount: Int, copyExemptApp: SelectionFocusAX.AppIdentity?,
                             intendedCopyApp: SelectionFocusAX.AppIdentity?,
                             completion: @escaping (SelectionCaptureResult) -> Void) {
        let deadline = now() + 0.4
        var copyAttempted = false
        func finish(_ result: SelectionCaptureResult, expectedChangeCount: Int) {
            let complete = { (resolved: SelectionCaptureResult) in
                completion(copyAttempted ? resolved.withCopyAttempt(resolvedAs: resolved.outcome) : resolved)
            }
            guard copyAttempted else {
                complete(pasteboard.changeCount == expectedChangeCount ? result : .clipboardChanged)
                return
            }
            switch restore(snapshot, expectedChangeCount: expectedChangeCount) {
            case .restored:
                complete(result)
            case .changed:
                complete(.clipboardChanged)
            case .failed:
                NSLog("[VoiceBar] Selection capture could not restore the pasteboard")
                complete(.clipboardRestoreFailed)
            }
        }
        // An unreadable-focus Copy goes only to the exact process that earned it, checked right before Cmd+C.
        if let copyExemptApp, frontmostApp() != copyExemptApp {
            finish(.captureFailed, expectedChangeCount: changeCount)
            return
        }
        if let intendedCopyApp, frontmostApp() != intendedCopyApp {
            finish(.captureFailed, expectedChangeCount: changeCount)
            return
        }
        copyAttempted = true
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
    static func preflight(_ ax: SelectionFocusAX, recover: Bool,
                          copyExemptApp: SelectionFocusAX.AppIdentity?) -> SelectionFocusPreflight {
        var result = SelectionFocusPreflight()
        let prefix = recover ? "preflight_initial_" : "preflight_recheck_"
        var fields = ["manual_ax_attempted": "false", "retry_statuses": ""]
        func done(_ reason: String) -> SelectionFocusPreflight {
            fields["reason"] = reason
            result.details = Dictionary(uniqueKeysWithValues: fields.map { (prefix + $0.key, $0.value) })
            result.blockReason = result.blockReason?.withPreflightDetails(result.details)
            return result
        }
        if ax.secureInputEnabled() { result.blockReason = .secureField; return done("secure_input") }
        guard ax.trusted() else { result.blockReason = .captureFailed; return done("ax_untrusted") }
        var (status, focus) = ax.queryFocus()
        fields["ax_status"] = String((focus?.queryStatus ?? status).rawValue)
        fields["final_ax_status"] = fields["ax_status"]
        var retryStatuses: [String] = []
        let unreadable = status == .noValue || status == .cannotComplete
        if recover, unreadable, let app = ax.frontmostApp() {
            fields["manual_ax_attempted"] = "true"
            let enableStatus = ax.setManualAccessibility(app)
            fields["manual_ax_status"] = String(enableStatus.rawValue)
            guard enableStatus == .success else {
                result.axEnable = .failed
                result.blockReason = .captureFailed
                return done("focus_query_failed")
            }
            result.axEnable = .attempted
            while status != .success, result.retries < focusRetryLimit {
                ax.sleep(focusRetryStep)
                result.retries += 1
                (status, focus) = ax.queryFocus()
                retryStatuses.append(String((focus?.queryStatus ?? status).rawValue))
                fields["retry_statuses"] = retryStatuses.joined(separator: ",")
                fields["final_ax_status"] = retryStatuses.last
            }
            if status == .success {
                result.axEnable = .set
            } else if ax.isChromiumFamily(app), ax.frontmostApp() == app {
                result.copyExemptApp = app
            }
        } else if !recover, let copyExemptApp {
            // The Copy recheck: the exemption belongs to the app that earned it, never to whatever is
            // frontmost after a switch during the retries or the clipboard snapshot, readable or not.
            guard ax.frontmostApp() == copyExemptApp else {
                result.blockReason = .captureFailed
                return done("app_changed")
            }
            if unreadable { result.copyExemptApp = copyExemptApp }
        }
        // An unreadable focus cannot establish permission to synthesize Copy, except in the Chromium-family
        // app that accepted AXManualAccessibility, while it stays frontmost and secure event input stays off.
        guard status == .success, let focus else {
            if result.unreadableFocusAllowsCopy, !ax.secureInputEnabled() { return done("focus_query_failed") }
            result.copyExemptApp = nil
            result.blockReason = .captureFailed
            return done(focus?.failure?.rawValue ?? (status == .success ? "focus_absent" : "focus_query_failed"))
        }
        fields["role_ax_status"] = String(focus.roleStatus.rawValue)
        // Evidence only: ordinary selection keeps its existing admission policy.
        result.clipboardFocusResolved = (focus.subroleStatus == .success && focus.subroleValueIsValid)
            || focus.subroleStatus == .noValue || focus.subroleStatus == .attributeUnsupported
        let secureInput = ax.secureInputEnabled()
        if isSecureFocus(role: focus.role, subrole: focus.subrole, secureInput: secureInput) {
            result.blockReason = .secureField
            return done(secureInput ? "secure_input" : "secure_role")
        } else if focus.role == nil {
            result.blockReason = .captureFailed
            return done(focus.failure?.rawValue ?? "role_absent")
        }
        return done("allowed")
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
