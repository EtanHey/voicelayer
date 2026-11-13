// Lane T7 fixture harness around VoiceBar's production typing code. Only ever point it at the agent
// browser you started.
//   post <pid> < text            SynthesizedTyping plan -> SynthesizedKeyEvents CGEvents through
//                                postGuardedBatch (final frontmost-PID guard), posted to the HID tap.
//   post --bridge <pid> < text   ListAwareTyping.deliver with the production AX reader on <pid>; each batch
//                                is written to stdout as a JSON line for the driver to replay over CDP, and
//                                the harness waits for a line on the FIFO named by T7_ACK_FIFO first.
import AppKit
import CoreGraphics
import Foundation
import VoiceBarUI

let args = CommandLine.arguments
if args.count == 3, args[1] == "--bridge" {
    let pid = pid_t(args[2])!
    let text = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
    let ackPath = ProcessInfo.processInfo.environment["T7_ACK_FIFO"]!
    func waitAck() {
        // Opening a FIFO for reading blocks until the driver opens it to write its ack.
        guard let acks = FileHandle(forReadingAtPath: ackPath) else { return }
        _ = try? acks.readToEnd()
        try? acks.close()
    }
    let sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
    let target = ListAwareTyping.Target(pid: pid, frontmostPID: { pid }) // batches replay over CDP, not to the front app
    let env = ListAwareTyping.Environment(
        readValue: target.makeReader(sleep: sleep),
        post: { plan in
            let steps: [[String: String]] = plan.map {
                switch $0 { case let .text(s): return ["t": "text", "s": s]; case .newline: return ["t": "newline"] }
            }
            let data = try! JSONSerialization.data(withJSONObject: steps)
            FileHandle.standardOutput.write(data + Data("\n".utf8))
            waitAck()
            return .posted
        },
        targetUnchanged: target.isUnchanged,
        sleep: sleep,
        now: { ProcessInfo.processInfo.systemUptime },
        log: { FileHandle.standardError.write(Data("[list-aware] \($0)\n".utf8)) }
    )
    let result = ListAwareTyping.deliver(text, env: env)
    FileHandle.standardError.write(Data("[list-aware] result \(result)\n".utf8))
    exit(result == .posted ? 0 : 3)
}

let pid = pid_t(args[1])!
let text = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
guard let source = CGEventSource(stateID: .hidSystemState) else { exit(1) }
let result = SynthesizedKeyEvents.postGuardedBatch(
    expectedPID: pid,
    buildEvents: { SynthesizedKeyEvents.events(for: SynthesizedTyping.keystrokes(for: text), source: source) },
    frontmostPID: { NSWorkspace.shared.frontmostApplication?.processIdentifier },
    postEvent: { $0.post(tap: .cghidEventTap) }
)
print("result \(result)")
exit(result == .posted ? 0 : 3)
