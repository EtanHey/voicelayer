import AppKit
import ApplicationServices
import VoiceBarUI

/// All AX operations, including target capture and comparison, stay on this serial queue.
final class ListDeliveryAXWorker {
    private static let queue = DispatchQueue(label: "com.voicelayer.list-delivery.ax", qos: .userInitiated)
    private let pid: pid_t
    private var target: AXUIElement?
    init(pid: pid_t) { self.pid = pid }

    private func focused() -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        let element = value as! AXUIElement
        AXUIElementSetMessagingTimeout(element, 0.25)
        return element
    }
    private func read(_ element: AXUIElement) -> String? {
        var subrole: CFTypeRef?
        // Unknown subrole is conservatively unreadable.
        guard AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole) == .success,
              subrole as? String != kAXSecureTextFieldSubrole as String else { return nil }
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
