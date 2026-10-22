import AppKit
import ApplicationServices
import CryptoKit
import ScreenCaptureKit
// Read-only: CG/AX reads and ScreenCaptureKit window-isolated stills. Nothing here presses,
// raises, activates, posts events to or dismisses any window, foreign or QA.
func attr(_ e:AXUIElement,_ key:String)->CFTypeRef?{var v:CFTypeRef?;return AXUIElementCopyAttributeValue(e,key as CFString,&v) == .success ? v:nil}
func strings(_ e:AXUIElement,_ depth:Int=0)->[String]{guard depth<12 else{return []};let own=["AXTitle","AXDescription","AXValue"].compactMap{attr(e,$0) as? String};let children=attr(e,"AXChildren") as? [AXUIElement] ?? [];return own+children.flatMap{strings($0,depth+1)}}

// BEGIN FOREIGN MODALS
// BEGIN CANONICAL PATH
/// The one path form compared on both sides of every QA executable check: realpath(3), which keeps
/// /private (Foundation's resolvingSymlinksInPath strips it). An unresolvable path stays exact.
func canonicalPath(_ path: String) -> String {
    guard let resolved = realpath(path, nil) else { return path }
    defer { free(resolved) }
    return String(cString: resolved)
}
// END CANONICAL PATH
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
func provenQAPid(executable: String, candidates: [(pid: Int32, read: QAIdentityRead)]) -> Int32? {
    var matches: [QAIdentity] = []
    for candidate in candidates {
        switch candidate.read {
        case .gone: continue
        case .failed: return nil
        case .live(let identity):
            guard identity.pid == candidate.pid else { return nil }
            if identity.path == executable { matches.append(identity) }
        }
    }
    return matches.count == 1 ? matches[0].pid : nil
}
/// The proven QA process's visible windows, front to back; anything else is never captured.
func provenQAWindows(_ rows: [CGRow], qaPid: Int32?) -> [CGRow] {
    guard let qaPid else { return [] }
    return rows.filter { $0.pid == qaPid && $0.alpha > 0 && !($0.bounds?.isEmpty ?? true) }
}
struct QAIdentity: Equatable { let pid: Int32; let path: String; let birth: [UInt64] }
enum BirthRead { case live([UInt64]), absent, failed }
enum QAIdentityRead { case live(QAIdentity), gone, failed }
/// Never trust a bundle/name or a bare PID. Re-read the lifetime before excluding each modal.
/// CG owners participate in QA discovery: NSWorkspace can lag behind a just-launched alert.
func runModalInventory<S: ModalSource>(_ source: S, binding: inout QARunBinding, executable: String,
    launchBirth: [UInt64], registered: [QAIdentity], candidates: [Int32], requireQA: Bool,
    read: (Int32) -> QAIdentityRead) -> ModalInventory {
    let identity = binding.prove(executable: executable, candidates: candidates, rows: source.windows(), read: read)
    let qa = identity.flatMap { $0.birth.lexicographicallyPrecedes(launchBirth) ? nil : $0 }
    var result = modalInventory(source, qaPids: [])
    var unresolved: [[String: Any]] = []
    func retain(_ modal: [String: Any]) -> Bool {
        guard let pid = modal["pid"] as? Int, let value = Int32(exactly: pid) else { return true }
        func unproven() -> Bool {
            unresolved.append(["kind": "own-identity", "owner": modal["owner"] ?? "unknown", "pid": pid])
            return false
        }
        guard case .live(let current) = read(value), current.pid == value else { return unproven() }
        if let registered = registered.first(where: { $0.pid == value }) {
            return current.birth == registered.birth ? false : unproven()
        }
        if current.path == executable { return current == qa ? false : unproven() }
        return true
    }
    result.modals = result.modals.filter(retain)
    result.errors = result.errors.filter(retain) + unresolved
    if requireQA && qa == nil { result.errors.append(["kind": "qa-binding", "owner": qaBundle]) }
    return result
}
/// Resolve transient launch/read races BEFORE latching. A real foreign modal stops immediately.
func retryModalProof(seconds: Double = 2, now: () -> Double = { ProcessInfo.processInfo.systemUptime },
    pause: (Double) -> Void = { Thread.sleep(forTimeInterval: $0) }, attempt: () -> ModalInventory) -> ModalInventory {
    let deadline = now() + seconds
    while true {
        let result = attempt()
        guard result.modals.isEmpty, !result.errors.isEmpty,
              result.errors.allSatisfy({ ["own-identity", "qa-binding"].contains($0["kind"] as? String ?? "") }),
              now() < deadline else { return result }
        pause(min(0.05, max(0, deadline - now())))
    }
}
/// Bind a QA launch once. A failed read is retained as failure, never dropped from candidates.
struct QARunBinding {
    private(set) var identity: QAIdentity?
    private var ended = false
    mutating func proveTermination(_ rows: [CGRow]?, birth: BirthRead, readPath: (Int32) -> String?) -> [String: Any]? {
        let proof = terminationProof(rows, identity: identity, birth: birth, readPath: readPath)
        if proof != nil { ended = true }
        return proof
    }
    mutating func prove(executable: String, candidates: [Int32], rows: [CGRow]?, read: (Int32) -> QAIdentityRead) -> QAIdentity? {
        guard let rows else { return nil }
        let owners = Set(rows.map(\.pid))
        var found: [QAIdentity] = []
        for pid in Set(candidates).union(owners) {
            guard pid > 0 else { return nil }
            switch read(pid) {
            case .gone where !owners.contains(pid): continue // stale NSWorkspace candidate only
            case .gone, .failed: return nil                  // a CG row still needs a readable owner
            case .live(let value):
                guard value.pid == pid else { return nil }
                if value.path == executable { found.append(value) }
            }
        }
        guard found.count == 1, let current = found.first else { return nil }
        if let identity, identity != current, !ended { return nil }
        identity = current; ended = false
        return current
    }
}
func inventoryProof(_ identity: QAIdentity) -> [String: Any] {
    ["cgInventory": "ok", "qaPid": Int(identity.pid), "qaBirth": identity.birth.map(Int.init), "onScreenQAWindows": 0]
}
/// Caller must freshly prove the bound identity is alive, including every CG row's identity read.
func expectedAbsentProof(_ rows: [CGRow]?, identity: QAIdentity?) -> [String: Any]? {
    guard let rows, let identity else { return nil }
    let owned = rows.filter { $0.pid == identity.pid && $0.alpha > 0 }
    guard owned.allSatisfy({ $0.bounds.map { $0.isEmpty } ?? false }) else { return nil }
    return inventoryProof(identity).merging(["pidLifetime": "alive"]) { _, new in new }
}
/// Distinct termination contract: kernel-ended lifetime, no bound-PID window, every visible path non-QA.
func terminationProof(_ rows: [CGRow]?, identity: QAIdentity?, birth: BirthRead,
                      readPath: (Int32) -> String?) -> [String: Any]? {
    guard let rows, let identity, !rows.contains(where: { $0.pid == identity.pid }) else { return nil }
    switch birth {
    case .absent: break
    case .live(let current): if current == identity.birth { return nil }
    case .failed: return nil
    }
    for row in rows where row.alpha > 0 {
        guard let bounds = row.bounds else { return nil }
        if bounds.isEmpty { continue }
        guard let path = readPath(row.pid), path != identity.path else { return nil }
    }
    return inventoryProof(identity).merging(["pidLifetime": "ended", "visibleOwnerPaths": "non-qa"]) { _, new in new }
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
// One independent key per helper/broker process; never exported or serialized.
private let redactionKey = SymmetricKey(size: .bits256)
func redact(_ text: String) -> String {
    let digest = HMAC<SHA256>.authenticationCode(for: Data(text.utf8), using: redactionKey)
        .map { String(format: "%02x", $0) }.joined()
    return "<redacted len=\(text.count) hmac-sha256=\(digest.prefix(32))>"
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
// BEGIN QA IDENTITY READ
func qaBirth(_ pid: Int32) -> BirthRead {
    guard pid > 0 else { return .failed }
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.size
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    errno = 0
    guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0 else {
        return errno == ESRCH ? .absent : .failed
    }
    if size == 0 { return .absent }
    let start = info.kp_proc.p_un.__p_starttime // p_starttime macro in sys/proc.h
    guard size == MemoryLayout<kinfo_proc>.size, start.tv_sec > 0,
          (0..<1_000_000).contains(start.tv_usec) else { return .failed }
    return .live([UInt64(start.tv_sec), UInt64(start.tv_usec)])
}
func qaIdentityRead(_ pid: Int32) -> QAIdentityRead {
    let before: [UInt64]
    switch qaBirth(pid) {
    case .absent: return .gone
    case .failed: return .failed
    case .live(let birth): before = birth
    }
    var buffer = [CChar](repeating: 0, count: 4096)
    let pathSize = proc_pidpath(pid, &buffer, UInt32(buffer.count))
    switch qaBirth(pid) {
    case .absent: return .gone
    case .failed: return .failed
    case .live(let after): guard pathSize > 0, before == after else { return .failed }
    }
    return .live(QAIdentity(pid: pid, path: canonicalPath(String(cString: buffer)), birth: before))
}
func qaIdentity(_ pid: Int32) -> QAIdentity? {
    if case .live(let identity) = qaIdentityRead(pid) { return identity }
    return nil
}
// END QA IDENTITY READ
func qaCandidates() -> [(pid: Int32, read: QAIdentityRead)] {
    qaCandidatePids().map { ($0, qaIdentityRead($0)) }
}
func qaCandidatePids() -> [Int32] { NSWorkspace.shared.runningApplications.filter { $0.bundleIdentifier == qaBundle }.map(\.processIdentifier) }
/// Supervisor publishes only lifetime-proven run identities. Missing/malformed context fails closed.
// BEGIN RUN MODAL PROOF
func runInventory(output: URL?, executable: String?, binding: inout QARunBinding, requireQA: Bool = false) -> ModalInventory {
    guard let output, let executable else { return modalInventory(LiveModalSource(), qaPids: []) }
    return retryModalProof {
        guard let data = try? Data(contentsOf: output.appendingPathComponent("modal-run-proof.json")),
              let proof = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              (proof["executable"] as? String).map(canonicalPath) == executable,
              let birth = proof["launchBirth"] as? [UInt64], birth.count == 2, birth[0] > 0, birth[1] < 1_000_000,
              let owned = proof["owned"] as? [[String: Any]] else {
            var failed = ModalInventory(); failed.errors = [["kind": "run-proof", "owner": "unknown"]]; return failed
        }
        var registered: [QAIdentity] = []
        for row in owned {
            guard let pid = row["pid"] as? Int32, pid > 0, let b = row["birth"] as? [UInt64],
                  b.count == 2, b[0] > 0, b[1] < 1_000_000, let path = row["path"] as? String else {
                var failed = ModalInventory(); failed.errors = [["kind": "run-proof", "owner": "unknown"]]; return failed
            }
            registered.append(QAIdentity(pid: pid, path: path, birth: b))
        }
        return runModalInventory(LiveModalSource(), binding: &binding, executable: executable, launchBirth: birth,
            registered: registered, candidates: qaCandidatePids(), requireQA: requireQA, read: qaIdentityRead)
    }
}
// END RUN MODAL PROOF
func json(_ object: Any) -> Data { try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) }

/// Window-ID capture of the proven QA process only (ScreenCaptureKit desktop-independent window,
/// the equivalent of `screencapture -l<id> -o`), composited on black. nil reason = captured.
func captureStill(binding: inout QARunBinding, executable: String, to path: URL) -> (windows: [UInt32], reason: String?, proof: [String: Any]?) {
    let candidates = qaCandidatePids()
    let before = binding.prove(executable: executable, candidates: candidates, rows: [], read: qaIdentityRead)
    let rows = LiveModalSource().windows()   // one fresh CG read at this step, for capture and proof
    let identity = before == nil ? nil : binding.prove(executable: executable, candidates: candidates, rows: rows, read: qaIdentityRead)
    let proof = expectedAbsentProof(rows, identity: identity)
    guard let identity else {
        let birth = binding.identity.map { qaBirth($0.pid) } ?? .failed
        let ended = binding.proveTermination(rows, birth: birth, readPath: { qaIdentity($0)?.path })
        return ([], "no-proven-qa-process", ended)
    }
    let qaPid = identity.pid
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
// BEGIN BOUNDARY BROKER
final class Broker {
    let token: String, boundary: URL, executable: String, latchPath: URL
    var latch = BoundaryLatch(), count = 0
    var binding = QARunBinding()
    init(token: String, root: URL, executable: String, latchPath: URL) {
        self.token = token; boundary = root.appendingPathComponent("boundary")
        self.executable = canonicalPath(executable); self.latchPath = latchPath
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
        // Establish the QA lifetime before the first fixture command, even without an alert.
        let inventory = runInventory(output: latchPath.deletingLastPathComponent(), executable: executable,
                                     binding: &binding, requireQA: kind == "command")
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
                let still = captureStill(binding: &binding, executable: executable, to: path)
                if still.reason == nil {
                    ack["capture"] = ["status": "PROVEN", "path": path.path, "windows": still.windows.map(Int.init), "qaPid": Int(binding.identity?.pid ?? 0)]
                } else {
                    var capture: [String: Any] = ["status": "NOT_PROVEN", "reason": still.reason!]
                    if let proof = still.proof {
                        capture[proof["pidLifetime"] as? String == "ended" ? "terminationProof" : "absenceProof"] = proof
                    }
                    ack["capture"] = capture
                }
            } else { ack["capture"] = ["status": "NOT_PROVEN", "reason": "foreign-modal-stop"] }
        }
        try? json(ack).write(to: boundary.appendingPathComponent("ack.json"), options: .atomic)
    }
}
// END BOUNDARY BROKER

let arguments = CommandLine.arguments
if arguments.count == 6, arguments[1] == "--broker" {
    let broker = Broker(token: arguments[2], root: URL(fileURLWithPath: arguments[3]), executable: arguments[4],
                        latchPath: URL(fileURLWithPath: arguments[5]))
    broker.start()
    RunLoop.main.run()
}
func argument(_ flag: String) -> String? {
    guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}
let executable = argument("--qa-executable").map(canonicalPath)
let output = argument("--run-output").map { URL(fileURLWithPath: $0) }

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
var modalBinding = QARunBinding()
let inventory = runInventory(output: output, executable: executable, binding: &modalBinding)
// Raw on stdout only: the supervisor redacts at ingestion before anything is persisted.
print(String(decoding:json(["axTrusted":AXIsProcessTrusted(),"prompts":prompts,"modals":inventory.modals,
    "inventoryErrors":inventory.errors]),as:UTF8.self))
// Exit status keeps its prompt/AX meaning; the supervisor refuses on any modal or inventory error.
exit(prompts.isEmpty && AXIsProcessTrusted() ? 0:2)
