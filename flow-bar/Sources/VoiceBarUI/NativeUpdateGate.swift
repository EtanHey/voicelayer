import Darwin
import Foundation
import CoreFoundation

/// G1's mkdir lock and G2's readable-ledger predicate. Never repairs or reaps evidence.
@MainActor public final class NativeUpdateGate {
    public static let shared = NativeUpdateGate()
    public static let busyMessage = "Update in progress. Try Play again when it finishes."
    public enum Fault: Error { case busy, unknown }
    private let path: String
    private let tryLock: (String) -> Bool
    private let monotonicNow: () -> UInt64
    private let incarnation = UUID().uuidString
    private var degraded = false
    private var lastDiagnostic = Date.distantPast

    public init(path: String? = nil,
                tryLock: @escaping (String) -> Bool = { mkdir($0, 0o700) == 0 },
                monotonicNow: @escaping () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }) {
        self.tryLock = tryLock
        self.monotonicNow = monotonicNow
        let env = ProcessInfo.processInfo.environment
        func trimmed(_ key: String) -> String? {
            guard let value = env[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
            return value
        }
        let resolved = path ?? trimmed("VOICELAYER_UPDATE_GATE_PATH") ??
            (trimmed("VOICELAYER_STATE_DIR") ?? NSHomeDirectory() + "/.local/state/voicelayer") + "/update-gate.json"
        self.path = URL(fileURLWithPath: resolved).standardizedFileURL.path
    }

    private static func number(_ value: Any?, minimum: Double = 0) -> Bool {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return false }
        let d = n.doubleValue
        return d.isFinite && d >= minimum && d <= 9_007_199_254_740_991 && d.rounded() == d
    }
    private static func keys(_ value: [String: Any], _ expected: String) -> Bool {
        Set(value.keys) == Set(expected.split(separator: " ").map(String.init))
    }
    public static func validLease(_ value: Any?) -> [String: Any]? {
        guard let l = value as? [String: Any], keys(l, "generation operationId ownerId targetSha"), number(l["generation"], minimum: 1),
              ["operationId", "ownerId"].allSatisfy({ key in
                  guard let s = l[key] as? String else { return false }
                  return s.range(of: "^(?:[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-8][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}|00000000-0000-0000-0000-000000000000|ffffffff-ffff-ffff-ffff-ffffffffffff)$", options: .regularExpression) != nil
              }), let sha = l["targetSha"] as? String,
              sha.range(of: "^[0-9a-f]{40}$", options: .regularExpression) != nil else { return nil }
        return l
    }
    public static func validState(_ s: [String: Any]) -> [String: Any]? {
        guard number(s["version"]), (s["version"] as? NSNumber)?.intValue == 1, let kind = s["kind"] as? String else { return nil }
        if kind == "OPEN" {
            guard keys(s, "version kind generation released"), number(s["generation"]) else { return nil }
            if s["released"] is NSNull { return (s["generation"] as? NSNumber)?.intValue == 0 ? s : nil }
            guard let l = validLease(s["released"]), (s["generation"] as? NSNumber) == (l["generation"] as? NSNumber) else { return nil }
        } else {
            guard let l = validLease(s["lease"]) else { return nil }
            if kind == "DRAINING" { return keys(s, "version kind lease") ? s : nil }
            guard ["PREPARED", "COMMITTED"].contains(kind), keys(s, "version kind lease native daemon") else { return nil }
            for key in ["native", "daemon"] {
                guard let a = s[key] as? [String: Any], keys(a, "lease activeOperations openArchives"),
                      number(a["activeOperations"]), number(a["openArchives"]),
                      (a["activeOperations"] as? NSNumber)?.intValue == 0, (a["openArchives"] as? NSNumber)?.intValue == 0,
                      let al = validLease(a["lease"]), NSDictionary(dictionary: al).isEqual(to: l) else { return nil }
            }
        }
        return s
    }
    private func stat(_ name: String) throws -> Darwin.stat {
        var s = Darwin.stat()
        guard lstat(name, &s) == 0 else { throw Fault.unknown }
        return s
    }
    private func absent(_ name: String) -> Bool {
        var s = Darwin.stat()
        return lstat(name, &s) != 0 && errno == ENOENT
    }
    private func state() throws -> [String: Any] {
        guard !degraded, absent(path + ".voice-diag.json"), try stat(path).st_mode & S_IFMT == S_IFREG,
              let json = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as? [String: Any],
              let state = Self.validState(json), try stat(path + ".admissions").st_mode & S_IFMT == S_IFDIR else { throw Fault.unknown }
        return state
    }
    private func readLedger() throws -> [String] {
        guard let directory = opendir(path + ".admissions") else { throw Fault.unknown }
        defer { closedir(directory) }
        var names: [String] = []
        while true {
            errno = 0
            guard let entry = readdir(directory) else {
                guard errno == 0 else { throw Fault.unknown }
                return names
            }
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                String(cString: UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self))
            }
            if name != ".", name != ".." { names.append(name) }
        }
    }
    private func snapshot() throws -> (state: [String: Any], active: [String]) {
        (try state(), try readLedger())
    }
    @discardableResult private func diagnose() -> Bool {
        degraded = true
        if Date().timeIntervalSince(lastDiagnostic) >= 60 {
            lastDiagnostic = Date()
            NSLog("[update-gate] UNKNOWN gate fault; updates REFUSED; voice fail-open; recovery required")
        }
        let marker = path + ".voice-diag.json"
        let fd = open(marker, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        if fd >= 0 {
            let data = Data("{\"kind\":\"UNKNOWN\",\"pid\":\(getpid()),\"at\":\"\(ISO8601DateFormatter().string(from: Date()))\"}\n".utf8)
            _ = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
            _ = close(fd)
        } else { _ = mkdir(marker, 0o700) }
        guard let s = try? stat(marker) else { return false }
        return [S_IFREG, S_IFDIR].contains(s.st_mode & S_IFMT)
    }
    private func locked<T>(voice: Bool = false, _ work: () throws -> T) throws -> T {
        if voice {
            do { try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
            catch { diagnose(); throw Fault.unknown }
        }
        let deadline = monotonicNow() + 2_000_000
        while !tryLock(path + ".lock") {
            guard errno == EEXIST, monotonicNow() < deadline else {
                if voice { diagnose() }; throw Fault.unknown
            }
        }
        let result: T
        do { result = try work() }
        catch {
            if voice, diagnose() { _ = rmdir(path + ".lock") }
            else if !voice { _ = rmdir(path + ".lock") }
            throw error
        }
        guard rmdir(path + ".lock") == 0 else { if voice { diagnose() }; throw Fault.unknown }
        return result
    }
    /// Returned release is held through confirmed stop, finish, or failed start (including queued clips).
    public func acquire() throws -> () -> Void {
        if degraded || !absent(path + ".voice-diag.json") { diagnose(); return {} }
        // The daemon bootstraps. Its absence already makes updater evidence UNKNOWN.
        if absent(path) { return {} }
        let token = UUID().uuidString
        let file = path + ".admissions/" + token
        let admission: (() -> Void)?
        do {
            admission = try locked(voice: true) {
                if absent(path) { return {} }
                let current = try state()
                if current["kind"] as? String != "OPEN" {
                    // Match TS readLedger: only readable closed evidence can refuse voice.
                    _ = try readLedger()
                    return nil
                }
                // UUIDs and validated integers need no escaping. Match TS insertion order and newline.
                let generation = (current["generation"] as! NSNumber).int64Value
                let bytes = Data("{\"token\":\"\(token)\",\"pid\":\(getpid()),\"incarnation\":\"\(incarnation)\",\"generation\":\(generation)}\n".utf8)
                let staged = path + ".lock/admission.json"
                let fd = open(staged, O_WRONLY | O_CREAT | O_EXCL, 0o600)
                guard fd >= 0 else { throw Fault.unknown }
                defer { _ = unlink(staged) }
                let written = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
                let closed = close(fd)
                guard written == bytes.count, closed == 0, rename(staged, file) == 0 else { throw Fault.unknown }
                var released = false
                return { [self] in
                    guard !released else { return }; released = true
                    release(file: file, bytes: bytes)
                }
            }
        } catch { diagnose(); return {} }
        guard let admission else { throw Fault.busy }
        return admission
    }
    private func release(file: String, bytes: Data, delay: Double = 0.01) {
        guard mkdir(path + ".lock", 0o700) == 0 else {
            if errno == EEXIST {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [self] in release(file: file, bytes: bytes, delay: min(delay * 2, 1)) }
            } else { diagnose() }
            return
        }
        do {
            guard try stat(file).st_mode & S_IFMT == S_IFREG,
                  try Data(contentsOf: URL(fileURLWithPath: file)) == bytes, unlink(file) == 0 else { throw Fault.unknown }
        } catch { diagnose() }
        if rmdir(path + ".lock") != 0 { diagnose() }
    }
    public func acknowledge(lease: [String: Any], idle: Bool) -> [String: Any]? {
        try? locked {
            let current = try snapshot()
            guard idle, current.active.isEmpty, let actual = current.state["lease"] as? [String: Any],
                  NSDictionary(dictionary: actual).isEqual(to: lease) else { throw Fault.unknown }
            return ["lease": actual, "activeOperations": 0, "openArchives": 0]
        }
    }
    public func permitsTermination(controlledLease: [String: Any]? = nil) -> Bool {
        (try? locked {
            let current = try state()
            return current["kind"] as? String == "OPEN" ||
                (current["kind"] as? String == "COMMITTED" && controlledLease.map {
                    NSDictionary(dictionary: current["lease"] as? [String: Any] ?? [:]).isEqual(to: $0)
                } == true)
        }) ?? true // Faults block updates, never ordinary quit; live activity is checked separately.
    }
}
