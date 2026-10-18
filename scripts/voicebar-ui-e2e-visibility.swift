import AppKit
import Foundation

// No AX, Automation, quitting, window closing or permission API. Snapshot before
// the first hide so a cancelled/partially failed preparation is still reversible.
struct VisibleApplication: Codable {
    let pid: Int32
    let bundleIdentifier: String?
    let bundlePath: String?
    let launched: Date?
    let name: String?
}
struct VisibilityReceipt: Codable {
    var visibleBefore: [VisibleApplication]
    var restored: Bool
    var failures: [String]
    var residentUserVisibilitySnapshot: String? = nil
}

@main struct VisibilityTool {
    @MainActor static func windowOwners() -> Set<Int32> {
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        return Set(windows.compactMap { ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value })
    }
    @MainActor static func main() {
        do {
            guard CommandLine.arguments.count == 3,
                  ["hide", "restore"].contains(CommandLine.arguments[1]) else {
                throw NSError(domain: "UIE2E visibility usage: hide|restore RECEIPT.json", code: 2)
            }
            let mode = CommandLine.arguments[1], url = URL(fileURLWithPath: CommandLine.arguments[2])
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            if mode == "hide" {
                guard !FileManager.default.fileExists(atPath: url.path) else {
                    throw NSError(domain: "Refusing to overwrite visibility snapshot", code: 3)
                }
                let owners = windowOwners()
                let resident = NSWorkspace.shared.runningApplications.filter { $0.bundleIdentifier == "com.voicelayer.voicebar" }
                var leaveResidentShown = false
                if let path = ProcessInfo.processInfo.environment["VOICEBAR_UIE2E_RESIDENT_SNAPSHOT"],
                   let snapshot = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as? [String: Any],
                   snapshot["visibilityPolicy"] as? String == "leave-shown",
                   let pid = snapshot["pid"] as? Int32,
                   let surface = snapshot["initialSurface"] as? [[String: Any]], !surface.isEmpty {
                    leaveResidentShown = resident.count == 1 && resident[0].processIdentifier == pid &&
                        resident[0].bundleURL?.path == "/Applications/VoiceBar.app" && owners.contains(pid)
                }
                guard leaveResidentShown || !resident.contains(where: { owners.contains($0.processIdentifier) }) else {
                    throw NSError(domain: "Resident VoiceBar surface visible: authorized AX Hide for 1 hour required; no application hide fallback", code: 6)
                }
                let apps = NSWorkspace.shared.runningApplications.filter {
                    $0.activationPolicy == .regular && $0.bundleIdentifier != "com.voicelayer.voicebar" &&
                    !$0.isHidden && !$0.isTerminated &&
                    owners.contains($0.processIdentifier) &&
                    $0.bundleIdentifier != "com.voicelayer.voicebar.uie2e" && $0.processIdentifier != getpid()
                }
                var receipt = VisibilityReceipt(visibleBefore: apps.map {
                    VisibleApplication(pid: $0.processIdentifier, bundleIdentifier: $0.bundleIdentifier,
                        bundlePath: $0.bundleURL?.path, launched: $0.launchDate, name: $0.localizedName)
                }, restored: false, failures: [])
                if let snapshot = ProcessInfo.processInfo.environment["VOICEBAR_UIE2E_RESIDENT_SNAPSHOT"] {
                    guard FileManager.default.fileExists(atPath: snapshot) else {
                        throw NSError(domain: "Missing resident AX reversible snapshot", code: 7)
                    }
                    receipt.residentUserVisibilitySnapshot = snapshot
                }
                try encoder.encode(receipt).write(to: url, options: .atomic)
                // Resident restoration is owned by the linked AX operator snapshot;
                // this helper restores only the regular applications it actually hid.
                // These requests are asynchronous; their Bool can be false even when
                // the window disappears. Only observed completion decides success.
                for app in apps { _ = app.hide() }
                let deadline = Date().addingTimeInterval(3)
                while apps.contains(where: { !$0.isHidden && windowOwners().contains($0.processIdentifier) && !$0.isTerminated }), Date() < deadline {
                    RunLoop.current.run(until: Date().addingTimeInterval(0.05))
                }
                for app in apps where !app.isHidden && windowOwners().contains(app.processIdentifier) && !app.isTerminated {
                    receipt.failures.append("Hide Others unconfirmed: \(app.localizedName ?? String(app.processIdentifier))")
                }
                try encoder.encode(receipt).write(to: url, options: .atomic)
                if !receipt.failures.isEmpty { throw NSError(domain: receipt.failures.joined(separator: "; "), code: 4) }
            } else {
                guard FileManager.default.fileExists(atPath: url.path) else { return }
                var receipt = try JSONDecoder().decode(VisibilityReceipt.self, from: Data(contentsOf: url))
                var restoreFailures: [String] = []
                var restoredApps: [NSRunningApplication] = []
                for entry in receipt.visibleBefore {
                    if entry.bundleIdentifier == "com.voicelayer.voicebar" {
                        restoreFailures.append("Resident restoration requires AX Show VoiceBar; no application unhide fallback")
                        continue
                    }
                    guard let app = NSRunningApplication(processIdentifier: entry.pid), !app.isTerminated,
                          app.bundleIdentifier == entry.bundleIdentifier, app.bundleURL?.path == entry.bundlePath,
                          app.launchDate == entry.launched else { continue } // Never reopen/relaunch or adopt a reused PID.
                    if app.isHidden { _ = app.unhide() }
                    restoredApps.append(app)
                }
                let deadline = Date().addingTimeInterval(3)
                while restoredApps.contains(where: { $0.isHidden && !$0.isTerminated }), Date() < deadline {
                    RunLoop.current.run(until: Date().addingTimeInterval(0.05))
                }
                for app in restoredApps where app.isHidden && !app.isTerminated {
                    restoreFailures.append("Unhide unconfirmed: \(app.localizedName ?? String(app.processIdentifier))")
                }
                receipt.restored = restoreFailures.isEmpty
                receipt.failures += restoreFailures
                try encoder.encode(receipt).write(to: url, options: .atomic)
                if !receipt.restored { throw NSError(domain: restoreFailures.joined(separator: "; "), code: 5) }
            }
        } catch {
            fputs("FAIL UIE2E visibility: \(error)\n", stderr)
            exit(1)
        }
    }
}
