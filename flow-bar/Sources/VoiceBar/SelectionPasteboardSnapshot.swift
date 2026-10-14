import AppKit
import Darwin

/// Read-only child exits before app/daemon startup, singleton election, sockets or event taps.
/// AppKit reads use the child's main thread; the utility parent bounds promised-data IPC.
enum SelectionPasteboardSnapshot {
    static let argument = "--selection-pasteboard-snapshot"
    private static let maximumBytes = 8 * 1024 * 1024

    private struct Value: Codable {
        let type: String
        let data: Data
    }

    static func runIfRequested(arguments: [String] = CommandLine.arguments) -> Bool {
        guard arguments.count == 3, arguments[1] == argument else { return false }
        guard let snapshot = readOnMain(name: arguments[2]),
              let data = try? JSONEncoder().encode(snapshot.map { values in
                  values.map { Value(type: $0.0.rawValue, data: $0.1) }
              }) else { exit(EXIT_FAILURE) }
        do { try FileHandle.standardOutput.write(contentsOf: data) }
        catch { exit(EXIT_FAILURE) }
        exit(EXIT_SUCCESS)
    }

    static func readOnMain(name: String) -> SpeakSelectionCapture.Snapshot? {
        precondition(Thread.isMainThread)
        let board = NSPasteboard(name: .init(name))
        let count = board.changeCount
        guard let items = board.pasteboardItems else {
            return (board.types ?? []).isEmpty ? [] : nil
        }
        guard items.count <= 64 else { return nil }
        var saved: SpeakSelectionCapture.Snapshot = []
        var bytes = 0
        for item in items {
            guard item.types.count <= 64 else { return nil }
            var values: [(NSPasteboard.PasteboardType, Data)] = []
            for type in item.types {
                guard let data = item.data(forType: type) else { return nil }
                bytes += data.count + type.rawValue.utf8.count
                guard bytes <= maximumBytes else { return nil }
                values.append((type, data))
            }
            saved.append(values)
        }
        return board.changeCount == count ? saved : nil
    }

    static func readInHelper(name: String, executable: URL? = Bundle.main.executableURL,
                             arguments: [String]? = nil, timeout: TimeInterval = 1)
        -> SpeakSelectionCapture.Snapshot? {
        precondition(!Thread.isMainThread)
        guard let executable else { return nil }
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments ?? [argument, name]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
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
                guard data.count <= 12 * 1024 * 1024 else {
                    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                    process.waitUntilExit()
                    return nil
                }
            }
        } catch {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            return nil
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let items = try? JSONDecoder().decode([[Value]].self, from: data) else { return nil }
        return items.map { $0.map { (NSPasteboard.PasteboardType($0.type), $0.data) } }
    }
}
