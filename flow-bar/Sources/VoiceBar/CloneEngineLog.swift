import Darwin
import Foundation

/// Drain stdout/stderr off-main into a current file and one rotated file.
/// Both are capped independently, including output from a long-lived engine.
final class CloneEngineLog {
    let url: URL
    private let maxBytes: Int
    private let queue = DispatchQueue(label: "com.voicelayer.clone-engine.log", qos: .utility)

    init(url: URL, maxBytes: Int = 1024 * 1024) {
        precondition(maxBytes > 0)
        self.url = url; self.maxBytes = maxBytes
    }

    func attach(to process: Process) {
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [self] reader in
            let data = reader.availableData
            if data.isEmpty { reader.readabilityHandler = nil; try? reader.close(); return }
            append(data)
        }
    }

    func appendLine(_ text: String) {
        append(Data("[\(ISO8601DateFormatter().string(from: Date()))] \(text)\n".utf8))
    }

    func append(_ data: Data) {
        queue.async { [self] in
            do { try appendBounded(data) }
            catch { NSLog("[VoiceBar] clone-engine log write failed: %@", String(describing: error)) }
        }
    }

    /// A barrier for bounded fake-output tests; never used by UI commands.
    func flush() { queue.sync {} }

    private func appendBounded(_ data: Data) throws {
        let files = FileManager.default
        try files.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                  attributes: [.posixPermissions: 0o700])
        var offset = 0
        while offset < data.count {
            let count = min(maxBytes, data.count - offset)
            let currentSize: Int
            if files.fileExists(atPath: url.path) {
                let info = try files.attributesOfItem(atPath: url.path)
                guard info[.type] as? FileAttributeType == .typeRegular else { throw POSIXError(.ELOOP) }
                currentSize = (info[.size] as? NSNumber)?.intValue ?? 0
            } else { currentSize = 0 }
            if currentSize + count > maxBytes {
                let backup = url.appendingPathExtension("1")
                if files.fileExists(atPath: backup.path) {
                    let info = try files.attributesOfItem(atPath: backup.path)
                    guard info[.type] as? FileAttributeType == .typeRegular else { throw POSIXError(.ELOOP) }
                    try files.removeItem(at: backup)
                }
                try files.moveItem(at: url, to: backup)
                try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
                // An oversized legacy log is bounded too; keep its newest bytes.
                if currentSize > maxBytes {
                    let reader = try FileHandle(forReadingFrom: backup)
                    try reader.seek(toOffset: UInt64(currentSize - maxBytes))
                    let tail = try reader.read(upToCount: maxBytes) ?? Data()
                    try reader.close()
                    try tail.write(to: backup)
                }
            }
            let fd = open(url.path, O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW, 0o600)
            guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            defer { try? handle.close() }
            guard fchmod(fd, 0o600) == 0 else { throw POSIXError(.EACCES) }
            try handle.write(contentsOf: data.subdata(in: offset..<(offset + count)))
            offset += count
        }
    }
}
