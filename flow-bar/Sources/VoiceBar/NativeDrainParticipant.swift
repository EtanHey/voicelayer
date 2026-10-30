import CryptoKit
import Foundation
import VoiceBarUI

/// Secret is ephemeral in this app and inherited by its owned daemon and descendant processes.
enum NativeDrainParticipant {
    static let secret = UUID().uuidString + UUID().uuidString
    static let incarnation = UUID().uuidString
    private static func message(_ kind: String, _ v: [String: Any], _ l: [String: Any]) -> String {
        [kind, v["id"] as! String, String((v["pid"] as! NSNumber).intValue), v["incarnation"] as! String,
         String((l["generation"] as! NSNumber).int64Value), l["operationId"] as! String,
         l["ownerId"] as! String, l["targetSha"] as! String].joined(separator: "|")
    }
    private static func mac(_ kind: String, _ v: [String: Any], _ l: [String: Any]) -> String {
        HMAC<SHA256>.authenticationCode(for: Data(message(kind, v, l).utf8), using: SymmetricKey(data: Data(secret.utf8)))
            .map { String(format: "%02x", $0) }.joined()
    }
    private static func authentic(_ signed: String, kind: String, value: [String: Any], lease: [String: Any]) -> Bool {
        guard signed.utf8.count == 64, signed.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { return false }
        var bytes = Data()
        var index = signed.startIndex
        for _ in 0..<32 {
            let end = signed.index(index, offsetBy: 2)
            guard let byte = UInt8(signed[index..<end], radix: 16) else { return false }
            bytes.append(byte); index = end
        }
        return HMAC<SHA256>.isValidAuthenticationCode(bytes, authenticating: Data(message(kind, value, lease).utf8),
            using: SymmetricKey(data: Data(secret.utf8)))
    }
    @MainActor static func reply(_ v: [String: Any], ownedDaemonPID: Int32?, idle: Bool, gate: NativeUpdateGate) -> [String: Any]? {
        guard let action = v["action"] as? String, ["drain", "quit"].contains(action),
              let pid = v["pid"] as? Int, let exactPID = Int32(exactly: pid), exactPID == ownedDaemonPID,
              let id = v["id"] as? String, UUID(uuidString: id) != nil,
              let owner = v["incarnation"] as? String, UUID(uuidString: owner) != nil,
              let l = NativeUpdateGate.validLease(v["lease"]), let signed = v["mac"] as? String,
              authentic(signed, kind: action, value: v, lease: l),
              gate.acknowledge(lease: l, idle: idle) != nil,
              action != "quit" || gate.permitsTermination(controlledLease: l) else { return nil }
        var result: [String: Any] = ["cmd": "update_gate_drain_ack", "action": action, "id": id, "pid": ProcessInfo.processInfo.processIdentifier,
                                   "incarnation": incarnation, "lease": l]
        result["mac"] = mac("ack-" + action, result, l)
        return result
    }
}
