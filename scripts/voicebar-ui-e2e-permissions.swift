import AppKit
import ApplicationServices
import CryptoKit
import ScreenCaptureKit
// Read-only: CG/AX reads and ScreenCaptureKit window-isolated stills. Nothing here presses,
// raises, activates, posts events to or dismisses any window, foreign or QA.
func attr(_ e:AXUIElement,_ key:String)->CFTypeRef?{var v:CFTypeRef?;return AXUIElementCopyAttributeValue(e,key as CFString,&v) == .success ? v:nil}
func strings(_ e:AXUIElement,_ depth:Int=0)->[String]{guard depth<12 else{return []};let own=["AXTitle","AXDescription","AXValue"].compactMap{attr(e,$0) as? String};let children=attr(e,"AXChildren") as? [AXUIElement] ?? [];return own+children.flatMap{strings($0,depth+1)}}

// BEGIN FOREIGN MODALS
/// A read that distinguishes "explicitly not there" from "could not be read". Only the latter
/// is a failure: it makes the inventory NOT_PROVEN, never a clean empty result.
enum AXRead<T> { case value(T), absent, failed(String) }
/// One on-screen CG window. `bounds == nil` means its geometry could not be read.
struct CGRow { let id: UInt32; let pid: Int32; let owner: String; let layer: Int; let bounds: CGRect?; let alpha: Double; let title: String }
protocol ModalSource {
    associatedtype Element
    func windows() -> [CGRow]?                       // nil: CG enumeration failed
    func axWindows(_ pid: Int32) -> AXRead<[Element]>
    func isModal(_ window: Element) -> AXRead<Bool>
    func children(_ window: Element) -> AXRead<[Element]>
    func role(_ element: Element) -> AXRead<String>
    func title(_ element: Element) -> String
}
let qaBundle = "com.voicelayer.voicebar.uie2e"
/// kCGModalPanelWindowLevel: NSAlert/app-modal panels and system dialogs (run-03's Gatekeeper prompt).
let modalPanelLayer = 8
// System agents whose any visible window is a modal over the run. Real bundle IDs, compared
// case-insensitively: CoreServicesUIAgent is com.apple.coreservices.uiagent, coreautha is
// com.apple.LocalAuthentication.UIAgent.
let systemModalOwners: Set<String> = ["com.apple.coreservices.uiagent", "com.apple.coreservicesuiagent",
    "com.apple.securityagent", "com.apple.usernotificationcenter", "com.apple.coreautha",
    "com.apple.localauthentication.uiagent"]
func isSystemModalOwner(_ owner: String) -> Bool { systemModalOwners.contains(owner.lowercased()) }
struct ModalInventory { var modals: [[String: Any]] = []; var errors: [[String: Any]] = [] }
/// ANY visible foreign modal on ANY display, independent of where QA windows are: a system-agent
/// window, a window at the modal-panel level, or an app's AX modal window or sheet. `qaPids` (the
/// run's proven QA process) is excluded: its product alert is the fixture under test.
func modalInventory<S: ModalSource>(_ source: S, qaPids: Set<Int32>) -> ModalInventory {
    var inventory = ModalInventory()
    guard let rows = source.windows() else {
        inventory.errors.append(["kind": "cg-enumeration", "owner": "unknown"]); return inventory
    }
    func modal(_ owner: String, _ pid: Int32, _ title: String, _ kind: String) {
        inventory.modals.append(["owner": owner, "pid": Int(pid), "title": title, "source": kind])
    }
    var inspect = Set<Int32>()
    for row in rows where !qaPids.contains(row.pid) && row.alpha > 0 {
        guard let bounds = row.bounds else {
            inventory.errors.append(["kind": "cg-geometry", "owner": row.owner, "pid": Int(row.pid)]); continue
        }
        if bounds.isEmpty { continue }
        if isSystemModalOwner(row.owner) { modal(row.owner, row.pid, row.title, "system-owner"); continue }
        if row.layer == modalPanelLayer { modal(row.owner, row.pid, row.title, "modal-level") }
        // Apps with only menu-bar/Dock/overlay windows cannot host a modal window or sheet.
        if (0..<20).contains(row.layer) { inspect.insert(row.pid) }
    }
    for pid in inspect.sorted() {
        let owner = rows.first { $0.pid == pid }?.owner ?? "unknown"
        func failed(_ kind: String, _ reason: String) {
            inventory.errors.append(["kind": kind, "owner": owner, "pid": Int(pid), "reason": reason])
        }
        let windows: [S.Element]
        switch source.axWindows(pid) {
        case .failed(let reason): failed("ax-windows", reason); continue
        case .absent: continue
        case .value(let found): windows = found
        }
        for window in windows {
            switch source.isModal(window) {
            case .value(true): modal(owner, pid, source.title(window), "modal")
            case .value(false), .absent: break
            case .failed(let reason): failed("ax-modal", reason)
            }
            switch source.children(window) {
            case .failed(let reason): failed("ax-children", reason)
            case .absent: break
            case .value(let children):
                for child in children {
                    switch source.role(child) {
                    case .value("AXSheet"): modal(owner, pid, source.title(window), "sheet")
                    case .value, .absent: break
                    case .failed(let reason): failed("ax-role", reason)
                    }
                }
            }
        }
    }
    return inventory
}
/// Once any modal or unreadable inventory is seen, every later decision is STOP: no recovery.
struct BoundaryLatch {
    private(set) var stopped: [String: Any]?
    mutating func decide(_ inventory: ModalInventory) -> String {
        if stopped != nil { return "stop" }
        if !inventory.errors.isEmpty { stopped = ["status": "not-proven", "errors": inventory.errors]; return "not-proven" }
        if !inventory.modals.isEmpty { stopped = ["status": "stop", "modals": inventory.modals]; return "stop" }
        return "clear"
    }
}
/// Exactly one live process running this run's QA executable, else none (NOT_PROVEN).
func provenQAPid(executable: String, candidates: [(pid: Int32, path: String)]) -> Int32? {
    let matches = candidates.filter { $0.path == executable }
    return matches.count == 1 ? matches[0].pid : nil
}
/// The proven QA process's visible windows, front to back; anything else is never captured.
func provenQAWindows(_ rows: [CGRow], qaPid: Int32?) -> [CGRow] {
    guard let qaPid else { return [] }
    return rows.filter { $0.pid == qaPid && $0.alpha > 0 && !($0.bounds?.isEmpty ?? true) }
}
/// Positive expected-absent proof for a hidden-state step: a SUCCESSFUL CG on-screen inventory with
/// zero visible windows owned by the proven QA PID (or, after QA exited, no process running this
/// run's QA executable at all). A failed read, an unreadable QA window geometry, or an ambiguous
/// QA process gives no proof, so the step fails.
func expectedAbsentProof(_ rows: [CGRow]?, qaPid: Int32?, qaProcessCount: Int) -> [String: Any]? {
    guard let rows else { return nil }
    if let qaPid {
        let owned = rows.filter { $0.pid == qaPid && $0.alpha > 0 }
        guard owned.allSatisfy({ $0.bounds.map { $0.isEmpty } ?? false }) else { return nil }
        return ["cgInventory": "ok", "qaPid": Int(qaPid), "onScreenQAWindows": 0]
    }
    return qaProcessCount == 0 ? ["cgInventory": "ok", "qaProcess": "none", "onScreenQAWindows": 0] : nil
}
/// Window-isolated captures (front to back) composited at their screen positions on black:
/// transparent QA pixels become black; no other window or desktop pixel is ever an input.
func compositeOnBlack(_ shots: [(image: CGImage, frame: CGRect)]) -> CGImage? {
    guard let first = shots.first, first.frame.width > 0 else { return nil }
    let scale = CGFloat(first.image.width) / first.frame.width
    let union = shots.dropFirst().reduce(first.frame) { $0.union($1.frame) }
    guard let context = CGContext(data: nil, width: Int((union.width * scale).rounded()), height: Int((union.height * scale).rounded()),
                                  bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: context.width, height: context.height))
    for shot in shots.reversed() {   // back to front; frames are top-left screen points
        context.draw(shot.image, in: CGRect(x: (shot.frame.minX - union.minX) * scale,
            y: (union.maxY - shot.frame.maxY) * scale, width: shot.frame.width * scale, height: shot.frame.height * scale))
    }
    return context.makeImage()
}
func redact(_ text: String) -> String {
    let digest = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    return "<redacted len=\(text.count) sha256=\(digest.prefix(8))>"
}
/// Persisted form: owner kept only if it is a plain identifier, every title redacted.
func redactedEntries(_ entries: [[String: Any]]) -> [[String: Any]] {
    entries.map { entry in
        var out = entry
        let owner = entry["owner"] as? String ?? "unknown"
        out["owner"] = owner.range(of: #"^[A-Za-z0-9._-]{1,128}$"#, options: .regularExpression) != nil ? owner : redact(owner)
        if let title = entry["title"] as? String { out["title"] = redact(title) }
        if let reason = entry["reason"] as? String { out["reason"] = reason.range(of: #"^[a-z0-9-]{1,40}$"#, options: .regularExpression) != nil ? reason : redact(reason) }
        return out
    }
}
// END FOREIGN MODALS

func bundle(_ pid: Int32) -> String { NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? "unknown" }
func axRead(_ element: AXUIElement, _ key: String) -> AXRead<CFTypeRef> {
    var value: CFTypeRef?
    let error = AXUIElementCopyAttributeValue(element, key as CFString, &value)
    switch error {
    case .success: return value.map { .value($0) } ?? .absent
    case .noValue, .attributeUnsupported, .invalidUIElement: return .absent   // explicitly not there / element gone
    case .cannotComplete: return .failed("cannot-complete")
    case .apiDisabled: return .failed("api-disabled")
    default: return .failed("ax-error-\(error.rawValue)")
    }
}
struct LiveModalSource: ModalSource {
    func windows() -> [CGRow]? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        return list.map { row in
            let pid = (row[kCGWindowOwnerPID as String] as? Int32) ?? 0
            let bounds = (row[kCGWindowBounds as String] as? NSDictionary).flatMap { CGRect(dictionaryRepresentation: $0) }
            return CGRow(id: (row[kCGWindowNumber as String] as? UInt32) ?? 0, pid: pid, owner: bundle(pid),
                         layer: row[kCGWindowLayer as String] as? Int ?? 0, bounds: bounds,
                         alpha: row[kCGWindowAlpha as String] as? Double ?? 1, title: row[kCGWindowName as String] as? String ?? "")
        }
    }
    func axWindows(_ pid: Int32) -> AXRead<[AXUIElement]> {
        let app = AXUIElementCreateApplication(pid); AXUIElementSetMessagingTimeout(app, 0.3)
        switch axRead(app, "AXWindows") {
        case .value(let v): return (v as? [AXUIElement]).map { .value($0) } ?? .failed("windows-type")
        case .absent: return .absent
        case .failed(let r): return .failed(r)
        }
    }
    func isModal(_ window: AXUIElement) -> AXRead<Bool> {
        switch axRead(window, "AXModal") {
        case .value(let v): return (v as? Bool).map { .value($0) } ?? .failed("modal-type")
        case .absent: return .absent
        case .failed(let r): return .failed(r)
        }
    }
    func children(_ window: AXUIElement) -> AXRead<[AXUIElement]> {
        switch axRead(window, "AXChildren") {
        case .value(let v): return (v as? [AXUIElement]).map { .value($0) } ?? .failed("children-type")
        case .absent: return .absent
        case .failed(let r): return .failed(r)
        }
    }
    func role(_ element: AXUIElement) -> AXRead<String> {
        switch axRead(element, "AXRole") {
        case .value(let v): return (v as? String).map { .value($0) } ?? .failed("role-type")
        case .absent: return .absent
        case .failed(let r): return .failed(r)
        }
    }
    func title(_ element: AXUIElement) -> String { attr(element, "AXTitle") as? String ?? "" }
}
func qaCandidates() -> [(pid: Int32, path: String)] {
    NSWorkspace.shared.runningApplications.filter { $0.bundleIdentifier == qaBundle }.compactMap { app in
        var buffer = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(app.processIdentifier, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return (app.processIdentifier, URL(fileURLWithPath: String(cString: buffer)).resolvingSymlinksInPath().path)
    }
}
func excludedQAPids(executable: String?) -> Set<Int32> {
    guard let executable else { return Set(qaCandidates().map(\.pid)) }   // one-shot without a run binding
    return provenQAPid(executable: executable, candidates: qaCandidates()).map { [$0] } ?? []
}
func json(_ object: Any) -> Data { try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) }

/// Window-ID capture of the proven QA process only (ScreenCaptureKit desktop-independent window,
/// the equivalent of `screencapture -l<id> -o`), composited on black. nil reason = captured.
func captureStill(qaPid: Int32?, qaProcessCount: Int, to path: URL) -> (windows: [UInt32], reason: String?, proof: [String: Any]?) {
    let rows = LiveModalSource().windows()   // one fresh CG read at this step, for capture and proof
    let proof = expectedAbsentProof(rows, qaPid: qaPid, qaProcessCount: qaProcessCount)
    guard let qaPid else { return ([], "no-proven-qa-process", proof) }
    guard let rows else { return ([], "cg-enumeration", nil) }
    let targets = provenQAWindows(rows, qaPid: qaPid)
    guard !targets.isEmpty else { return ([], "no-proven-qa-window", proof) }
    func failed(_ reason: String) -> (windows: [UInt32], reason: String?, proof: [String: Any]?) { ([], reason, nil) }
    let done = DispatchSemaphore(value: 0)
    var content: SCShareableContent?
    SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { found, _ in content = found; done.signal() }
    guard done.wait(timeout: .now() + 3) == .success, let content else { return failed("sck-content") }
    var shots: [(image: CGImage, frame: CGRect)] = []
    for target in targets {
        guard let window = content.windows.first(where: { $0.windowID == target.id && $0.owningApplication?.processID == qaPid }),
              let frame = target.bounds else { return failed("window-identity-changed") }
        let config = SCStreamConfiguration()
        let scale = NSScreen.screens.first { $0.frame.intersects(frame) }?.backingScaleFactor ?? 2
        config.width = Int(frame.width * scale); config.height = Int(frame.height * scale)
        config.showsCursor = false; config.capturesAudio = false
        var image: CGImage?
        let shot = DispatchSemaphore(value: 0)
        SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: window), configuration: config) { found, _ in
            image = found; shot.signal()
        }
        guard shot.wait(timeout: .now() + 3) == .success, let image else { return failed("window-capture-failed") }
        shots.append((image, frame))
    }
    guard let composite = compositeOnBlack(shots),
          let destination = CGImageDestinationCreateWithURL(path as CFURL, "public.png" as CFString, 1, nil) else { return failed("composite") }
    CGImageDestinationAddImage(destination, composite, nil)
    return CGImageDestinationFinalize(destination) ? (targets.map(\.id), nil, nil) : failed("png-write")
}

/// Long-lived boundary broker. The sandboxed XCTest runner posts a name-only distributed
/// notification before each fixture command, UI action and still; the broker answers with a
/// fresh synchronous modal decision (and, for stills, a window-ID capture) in an ack file.
final class Broker {
    let token: String, boundary: URL, executable: String, latchPath: URL
    var latch = BoundaryLatch(), count = 0
    init(token: String, root: URL, executable: String, latchPath: URL) {
        self.token = token; boundary = root.appendingPathComponent("boundary")
        self.executable = executable; self.latchPath = latchPath
    }
    func start() {
        try! FileManager.default.createDirectory(at: boundary, withIntermediateDirectories: true)
        for kind in ["command", "action", "still"] {
            DistributedNotificationCenter.default().addObserver(forName: Notification.Name("com.voicelayer.voicebar.uie2e.boundary.\(token).\(kind)"),
                object: nil, queue: .main, using: { [unowned self] _ in self.answer(kind) })
        }
        try! json(["ready": true, "pid": Int(getpid())]).write(to: boundary.appendingPathComponent("ready.json"), options: .atomic)
    }
    func answer(_ kind: String) {
        count += 1
        let candidates = qaCandidates()
        let qaPid = provenQAPid(executable: executable, candidates: candidates)
        let qaProcessCount = candidates.filter { $0.path == executable }.count
        let inventory = modalInventory(LiveModalSource(), qaPids: qaPid.map { [$0] } ?? [])
        let status = latch.decide(inventory)
        var ack: [String: Any] = ["count": count, "kind": kind, "status": status]
        if let stopped = latch.stopped {
            var record = stopped
            record["modals"] = redactedEntries(stopped["modals"] as? [[String: Any]] ?? [])
            record["errors"] = redactedEntries(stopped["errors"] as? [[String: Any]] ?? [])
            if !FileManager.default.fileExists(atPath: latchPath.path) { try? json(record).write(to: latchPath, options: .atomic) }
            ack["latch"] = record
        }
        if kind == "still" {
            if status == "clear" {
                let path = boundary.appendingPathComponent("still-\(count).png")
                let still = captureStill(qaPid: qaPid, qaProcessCount: qaProcessCount, to: path)
                if still.reason == nil {
                    ack["capture"] = ["status": "PROVEN", "path": path.path, "windows": still.windows.map(Int.init), "qaPid": Int(qaPid ?? 0)]
                } else {
                    var capture: [String: Any] = ["status": "NOT_PROVEN", "reason": still.reason!]
                    if let proof = still.proof { capture["absenceProof"] = proof }
                    ack["capture"] = capture
                }
            } else { ack["capture"] = ["status": "NOT_PROVEN", "reason": "foreign-modal-stop"] }
        }
        try? json(ack).write(to: boundary.appendingPathComponent("ack.json"), options: .atomic)
    }
}

let arguments = CommandLine.arguments
if arguments.count == 6, arguments[1] == "--broker" {
    let broker = Broker(token: arguments[2], root: URL(fileURLWithPath: arguments[3]), executable: arguments[4],
                        latchPath: URL(fileURLWithPath: arguments[5]))
    broker.start()
    RunLoop.main.run()
}
let executable = arguments.count == 3 && arguments[1] == "--qa-executable" ? arguments[2] : nil

let owners=Set(["com.apple.UserNotificationCenter","com.apple.SecurityAgent","com.apple.CoreServicesUIAgent","com.apple.coreservices.uiagent","com.apple.coreautha","com.apple.LocalAuthentication.UIAgent","com.voicelayer.voicebar.uie2e"])
var prompts:[[String:Any]]=[]
for app in NSWorkspace.shared.runningApplications where owners.contains(app.bundleIdentifier ?? "") {
 let ax=AXUIElementCreateApplication(app.processIdentifier)
 for w in attr(ax,"AXWindows") as? [AXUIElement] ?? [] {
  let labels=strings(w);let text=labels.joined(separator:" ").lowercased()
  if labels.contains(where:{$0=="Allow" || $0=="Don’t Allow" || $0=="Don't Allow"}) || text.contains("would like to access") || text.contains("to access your microphone") {
   prompts.append(["pid":app.processIdentifier,"owner":app.bundleIdentifier ?? "","labels":labels])
  }
 }
}
let inventory = modalInventory(LiveModalSource(), qaPids: excludedQAPids(executable: executable))
// Raw on stdout only: the supervisor redacts at ingestion before anything is persisted.
print(String(decoding:json(["axTrusted":AXIsProcessTrusted(),"prompts":prompts,"modals":inventory.modals,
    "inventoryErrors":inventory.errors]),as:UTF8.self))
// Exit status keeps its prompt/AX meaning; the supervisor refuses on any modal or inventory error.
exit(prompts.isEmpty && AXIsProcessTrusted() ? 0:2)
