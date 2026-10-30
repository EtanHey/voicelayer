import CryptoKit
import Foundation
import VoiceBarUI

/// Secret exists only in this app incarnation and its owned child's environment.
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
    @MainActor static func reply(_ v: [String: Any], ownedDaemonPID: Int32?, idle: Bool, gate: NativeUpdateGate) -> [String: Any]? {
        guard let action = v["action"] as? String, ["drain", "quit"].contains(action),
              let pid = v["pid"] as? Int, let exactPID = Int32(exactly: pid), exactPID == ownedDaemonPID,
              let id = v["id"] as? String, UUID(uuidString: id) != nil,
              let owner = v["incarnation"] as? String, UUID(uuidString: owner) != nil,
              let l = NativeUpdateGate.validLease(v["lease"]), let signed = v["mac"] as? String,
              signed == mac(action, v, l),
              gate.acknowledge(lease: l, idle: idle) != nil,
              action != "quit" || gate.permitsTermination(controlledLease: l) else { return nil }
        var result: [String: Any] = ["cmd": "update_gate_drain_ack", "action": action, "id": id, "pid": ProcessInfo.processInfo.processIdentifier,
                                   "incarnation": incarnation, "lease": l]
        result["mac"] = mac("ack-" + action, result, l)
        return result
    }
}
