import AppKit
import Darwin

/// Read-only child exits before app/daemon startup, singleton election, sockets or event taps.
/// AppKit reads use the child's main thread; the utility parent bounds promised-data IPC.
enum SelectionPasteboardSnapshot {
    static let argument = "--selection-pasteboard-snapshot"
    private static let maximumBytes = 8 * 1024 * 1024

    enum ReadFailure: UInt8 {
        case itemsUnavailable = 1, tooManyItems, tooManyTypes, representationUnavailable
        case maximumBytes, generationChanged, encodingFailed
    }

    private struct Value: Codable {
        let type: String
        let data: Data
    }

    static func runIfRequested(arguments: [String] = CommandLine.arguments) -> Bool {
        guard arguments.count == 3, arguments[1] == argument else { return false }
        var failure = ReadFailure.encodingFailed
        guard let snapshot = readOnMain(name: arguments[2], onFailure: { failure = $0 }),
              let data = try? JSONEncoder().encode(snapshot.map { values in
                  values.map { Value(type: $0.0.rawValue, data: $0.1) }
              }) else {
            try? FileHandle.standardOutput.write(contentsOf: Data([failure.rawValue]))
            exit(EXIT_FAILURE)
        }
        do { try FileHandle.standardOutput.write(contentsOf: data) }
        catch { exit(EXIT_FAILURE) }
        exit(EXIT_SUCCESS)
    }

    static func readOnMain(name: String, onFailure: (ReadFailure) -> Void = { _ in })
        -> SpeakSelectionCapture.Snapshot? {
        precondition(Thread.isMainThread)
        let board = NSPasteboard(name: .init(name))
        let count = board.changeCount
        guard let items = board.pasteboardItems else {
            if (board.types ?? []).isEmpty { return [] }
            onFailure(.itemsUnavailable)
            return nil
        }
        guard items.count <= 64 else { onFailure(.tooManyItems); return nil }
        var saved: SpeakSelectionCapture.Snapshot = []
        var bytes = 0
        for item in items {
            guard item.types.count <= 64 else { onFailure(.tooManyTypes); return nil }
            var values: [(NSPasteboard.PasteboardType, Data)] = []
            for type in item.types {
                guard let data = item.data(forType: type) else { onFailure(.representationUnavailable); return nil }
                bytes += data.count + type.rawValue.utf8.count
                guard bytes <= maximumBytes else { onFailure(.maximumBytes); return nil }
                values.append((type, data))
            }
            saved.append(values)
        }
        guard board.changeCount == count else { onFailure(.generationChanged); return nil }
        return saved
    }

    static func readInHelper(name: String, executable: URL? = Bundle.main.executableURL,
                             arguments: [String]? = nil, timeout: TimeInterval = 1,
                             onFailure: (String) -> Void = { reason in
                                 NSLog("[selection_snapshot] failed reason=%@", reason)
                             })
        -> SpeakSelectionCapture.Snapshot? {
        precondition(!Thread.isMainThread)
        let began = ProcessInfo.processInfo.systemUptime
        var launchedAt: TimeInterval?
        var responseBytes = 0
        defer {
            let end = ProcessInfo.processInfo.systemUptime
            NSLog("[selection_snapshot] metrics launch_ms=%.1f after_launch_ms=%.1f bytes=%d",
                  launchedAt.map { ($0 - began) * 1000 } ?? -1,
                  launchedAt.map { (end - $0) * 1000 } ?? -1, responseBytes)
        }
        guard let executable else { onFailure("missing_executable"); return nil }
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments ?? [argument, name]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run(); launchedAt = ProcessInfo.processInfo.systemUptime }
        catch { onFailure("launch_failed"); return nil }
        // SIGKILL bounds a stuck provider and targets only this owned child.
        let timeoutJob = DispatchWorkItem {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: timeoutJob)
        defer { timeoutJob.cancel() }
        var data = Data()
        do {
            while let chunk = try pipe.fileHandleForReading.read(upToCount: 64 * 1024), !chunk.isEmpty {
                data.append(chunk)
                responseBytes = data.count
                guard data.count <= 12 * 1024 * 1024 else {
                    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                    process.waitUntilExit()
                    onFailure("output_limit")
                    return nil
                }
            }
        } catch {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            onFailure("read_failed")
            return nil
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            if data.count == 1, let byte = data.first, let failure = ReadFailure(rawValue: byte) {
                onFailure("snapshot_\(failure)")
            }
            onFailure("helper_termination_\(process.terminationReason.rawValue)_\(process.terminationStatus)")
            return nil
        }
        guard let items = try? JSONDecoder().decode([[Value]].self, from: data) else {
            onFailure("decode_failed")
            return nil
        }
        return items.map { $0.map { (NSPasteboard.PasteboardType($0.type), $0.data) } }
    }
}
