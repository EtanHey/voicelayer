import AppKit
import ApplicationServices
import VoiceBarUI

/// All AX operations, including target capture and comparison, stay on this serial queue.
final class ListDeliveryAXWorker {
    private static let queue = DispatchQueue(label: "com.voicelayer.list-delivery.ax", qos: .userInitiated)
    private let pid: pid_t
    private var target: AXUIElement?
    private var enabledManualAccessibility = false
    private let focusReader: (() -> AXUIElement?)?
    private let subroleReader: ((AXUIElement) -> String?)?
    private let roleReader: ((AXUIElement) -> String?)?
    private let protectedReader: ((AXUIElement) -> Bool)?
    private let valueReader: ((AXUIElement) -> String?)?
    private let enableManualAccessibility: (() -> Void)?
    private let chromium: () -> Bool
    init(pid: pid_t, focusReader: (() -> AXUIElement?)? = nil,
         subroleReader: ((AXUIElement) -> String?)? = nil, valueReader: ((AXUIElement) -> String?)? = nil,
         chromium: (() -> Bool)? = nil, enableManualAccessibility: (() -> Void)? = nil,
         roleReader: ((AXUIElement) -> String?)? = nil, protectedReader: ((AXUIElement) -> Bool)? = nil) {
        self.pid = pid; self.focusReader = focusReader; self.subroleReader = subroleReader
        self.roleReader = roleReader; self.protectedReader = protectedReader
        self.valueReader = valueReader; self.enableManualAccessibility = enableManualAccessibility
        self.chromium = chromium ?? { ChromiumFamilyApps.contains(bundleURL: NSRunningApplication(processIdentifier: pid)?.bundleURL) }
    }

    private func focused() -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        var value: CFTypeRef?
        let element: AXUIElement?
        if let focusReader { element = focusReader() }
        else if AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &value) == .success,
                let value, CFGetTypeID(value) == AXUIElementGetTypeID() { element = (value as! AXUIElement) }
        else { element = nil }
        guard let element else {
            if !enabledManualAccessibility,
               chromium() {
                enabledManualAccessibility = true
                if let enableManualAccessibility { enableManualAccessibility() }
                else { AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue) }
                return focused()
            }
            return nil
        }
        if focusReader == nil { AXUIElementSetMessagingTimeout(element, 0.25) }
        return element
    }
    private func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }
    /// The same secure predicate as typing eligibility (subrole or AXProtectedContent)
    /// plus a secure role: the value of such a field is never read.
    private func isSecure(_ element: AXUIElement) -> Bool {
        let secure = kAXSecureTextFieldSubrole as String
        let subrole = subroleReader.map { $0(element) } ?? attribute(element, kAXSubroleAttribute) as? String
        let role = roleReader.map { $0(element) } ?? attribute(element, kAXRoleAttribute) as? String
        let protected = protectedReader.map { $0(element) } ?? (attribute(element, "AXProtectedContent") as? Bool == true)
        return subrole == secure || role == secure || protected
    }
    private func read(_ element: AXUIElement) -> String? {
        guard !isSecure(element) else { return nil }
        if let valueReader { return valueReader(element) }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success else { return nil }
        return value as? String
    }
    func request(_ request: ListDeliveryMachine.Request, completion: @escaping (ListDeliveryMachine.Reply) -> Void) {
        Self.queue.async { [self] in
            var same = false
            var value: String?
            switch request.kind {
            case .capture:
                if let element = focused(), let text = read(element) {
                    target = element; same = true; value = text
                }
            case .read:
                // Read the captured element, never the newly focused element.
                if let target { value = read(target); same = value != nil }
            case .check:
                if let target, let current = focused() { same = CFEqual(target, current) }
            }
            let reply = ListDeliveryMachine.Reply(request: request, same: same, value: value,
                                                   completed: ProcessInfo.processInfo.systemUptime)
            DispatchQueue.main.async { completion(reply) }
        }
    }
}

/// A main-local activation epoch catches change-and-change-back during an AX request.
final class ListDeliveryActivationEpoch {
    private(set) var value: UInt64 = 0
    private var observer: NSObjectProtocol?
    init() {
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.value += 1 }
    }
    deinit { if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) } }
}
