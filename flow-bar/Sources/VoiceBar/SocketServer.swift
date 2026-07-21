// SocketServer.swift — Unix domain socket server for Voice Bar.
//
// POSIX socket server on VoiceLayerPaths.socketPath. Accepts connections from
// MCP server instances (clients). Receives NDJSON state events, forwards
// commands back. NWListener does NOT support Unix domain sockets, so we
// use POSIX sockets + GCD DispatchSource.
//
// AIDEV-NOTE: Architecture inversion (Phase 0) — VoiceBar is the persistent
// server. MCP servers connect as clients. This replaces SocketClient.swift.

import Foundation
import VoiceBarUI

enum SocketWriteResult: Equatable {
    case wrote(Int)
    case retry
    case peerClosed(Int32)
    case failed(Int32)
}

func classifySocketWriteResult(bytesWritten: Int, errnoCode: Int32) -> SocketWriteResult {
    if bytesWritten > 0 {
        return .wrote(bytesWritten)
    }
    if bytesWritten == 0 {
        return .peerClosed(0)
    }

    switch errnoCode {
    case EINTR, EAGAIN, EWOULDBLOCK:
        return .retry
    case EPIPE, ECONNRESET:
        return .peerClosed(errnoCode)
    default:
        return .failed(errnoCode)
    }
}

private struct ClientConnection {
    let source: DispatchSourceRead
    var buffer: String
    var role: String?
    var pid: Int?
    var acceptsCommands: Bool

    init(source: DispatchSourceRead) {
        self.source = source
        buffer = ""
        acceptsCommands = false
    }
}

final class SocketServer {
    private let socketPath: String
    private let queue = DispatchQueue(label: "com.voicelayer.voicebar.server", qos: .userInitiated)
    private let state: VoiceState
    var onControlCommand: ((VoiceBarLocalControlCommand) -> Void)?
    var onCaptureFailure: ((String) -> Void)?

    /// Listening socket file descriptor.
    private var listenFD: Int32 = -1
    /// GCD source watching the listen socket for incoming connections.
    private var listenSource: DispatchSourceRead?
    /// True only after this instance successfully binds the socket path.
    private var ownsSocketPath = false

    /// Connected clients: fd → read source, NDJSON buffer, and command eligibility.
    private var clients: [Int32: ClientConnection] = [:]
    /// Playback can belong to a passive per-tool MCP process rather than the
    /// command daemon. Retain the latest speaking owner across playback idle so
    /// replay after completion returns to the process that owns its history.
    private var lastPlaybackClientFD: Int32?
    private var activePlaybackClientFD: Int32?

    // MARK: - Lifecycle

    init(state: VoiceState, socketPath: String = VoiceLayerPaths.socketPath) {
        self.state = state
        self.socketPath = socketPath
    }

    /// Start the server: bind, listen, accept loop.
    func start() {
        queue.async { [weak self] in
            self?.startOnQueue()
        }
    }

    /// Stop the server: close all clients, close listen socket, unlink.
    func stop() {
        queue.async { [weak self] in
            self?.cleanup()
        }
    }

    // MARK: - Server setup (runs on queue)

    private func startOnQueue() {
        // Clean up stale socket from previous crash
        unlink(socketPath)

        // Create POSIX Unix domain socket
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            NSLog("[VoiceBar] Failed to create socket: errno %d", errno)
            return
        }

        // Bind to path
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = socketPath.utf8CString
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
            NSLog("[VoiceBar] Socket path too long: %@", socketPath)
            close(fd)
            return
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { dest in
                pathBytes.withUnsafeBufferPointer { src in
                    _ = memcpy(dest, src.baseAddress!, src.count)
                }
            }
        }

        let bindResult = withUnsafePointer(to: &addr) { addrPtr in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { ptr in
                bind(fd, ptr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            NSLog("[VoiceBar] Failed to bind socket: errno %d", errno)
            close(fd)
            return
        }
        ownsSocketPath = true

        // Restrict to current user (0600)
        chmod(socketPath, 0o600)

        // Listen with a small backlog
        guard listen(fd, 5) == 0 else {
            NSLog("[VoiceBar] Failed to listen: errno %d", errno)
            close(fd)
            unlinkOwnedSocketPath()
            return
        }

        listenFD = fd

        // Accept loop via GCD
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            self?.acceptClient()
        }
        source.setCancelHandler { [weak self] in
            guard let self else { return }
            close(fd)
            listenFD = -1
        }
        source.resume()
        listenSource = source

        NSLog("[VoiceBar] Server listening on %@", socketPath)
        updateConnectionState()
    }

    // MARK: - Accept

    private func acceptClient() {
        let clientFD = accept(listenFD, nil, nil)
        guard clientFD >= 0 else {
            if errno != EWOULDBLOCK, errno != EAGAIN {
                NSLog("[VoiceBar] accept() failed: errno %d", errno)
            }
            return
        }

        // Set non-blocking
        let flags = fcntl(clientFD, F_GETFL)
        _ = fcntl(clientFD, F_SETFL, flags | O_NONBLOCK)

        // Prevent SIGPIPE crash when writing to a disconnecting client
        var nosigpipe: Int32 = 1
        setsockopt(clientFD, SOL_SOCKET, SO_NOSIGPIPE, &nosigpipe, socklen_t(MemoryLayout<Int32>.size))

        NSLog("[VoiceBar] Client connected (fd: %d, total: %d)", clientFD, clients.count + 1)

        // Read source for this client
        let readSource = DispatchSource.makeReadSource(fileDescriptor: clientFD, queue: queue)
        readSource.setEventHandler { [weak self] in
            self?.readFromClient(fd: clientFD)
        }
        readSource.setCancelHandler { [weak self] in
            close(clientFD)
            self?.removeClient(fd: clientFD)
        }
        readSource.resume()

        clients[clientFD] = ClientConnection(source: readSource)
        updateConnectionState()
    }

    // MARK: - Read

    private func readFromClient(fd: Int32) {
        var buf = [UInt8](repeating: 0, count: 65536)
        let bytesRead = read(fd, &buf, buf.count)

        if bytesRead <= 0 {
            if bytesRead == -1, errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR {
                // Spurious GCD/kqueue wake-up — no data available yet.
                // Can happen on the first DispatchSource resume() on macOS,
                // or when read() is interrupted by a signal (EINTR).
                // Not a disconnect; just ignore and wait for the next event.
                return
            }
            // True EOF (bytesRead == 0) or real error — client disconnected
            NSLog("[VoiceBar] Client disconnected (fd: %d)", fd)
            clients[fd]?.source.cancel()
            return
        }

        guard clients[fd] != nil else { return }

        let chunk = String(bytes: buf[0 ..< bytesRead], encoding: .utf8) ?? ""
        clients[fd]?.buffer.append(chunk)

        // NDJSON framing: split on newlines
        while let buffer = clients[fd]?.buffer,
              let idx = buffer.firstIndex(of: "\n") {
            let line = String(buffer[buffer.startIndex ..< idx])
            clients[fd]?.buffer = String(buffer[buffer.index(after: idx)...])
            if !line.isEmpty {
                parseLine(line, from: fd)
            }
        }
    }

    func parseLine(_ json: String, from fd: Int32? = nil) {
        guard let data = json.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            NSLog("[VoiceBar] Bad JSON from client: %@", json)
            return
        }

        if let controlCommand = VoiceBarLocalControlCommand(payload: dict) {
            DispatchQueue.main.async { [weak self] in
                self?.onControlCommand?(controlCommand)
            }
            return
        }

        if dict["type"] as? String == "client_hello" {
            handleClientHello(dict, from: fd)
            return
        }

        if dict["type"] as? String == "state", let stateName = dict["state"] as? String {
            if stateName == "speaking", let fd, clients[fd] != nil {
                lastPlaybackClientFD = fd
                activePlaybackClientFD = fd
            } else if stateName == "idle",
                      dict["source"] as? String == "playback",
                      activePlaybackClientFD == fd {
                activePlaybackClientFD = nil
            } else if stateName == "recording" || stateName == "transcribing" {
                activePlaybackClientFD = nil
            }
        }

        let playbackAmplitude = SocketPlaybackAmplitudeParser.parse(event: dict)

        DispatchQueue.main.async { [weak self] in
            if dict["type"] as? String == "error",
               let captureFailure = dict["capture_failure"] as? String {
                self?.onCaptureFailure?(captureFailure)
            }
            self?.state.handleEvent(dict, playbackAmplitude: playbackAmplitude)
        }
    }

    private func handleClientHello(_ payload: [String: Any], from fd: Int32?) {
        guard let fd, clients[fd] != nil else {
            return
        }

        let role = payload["role"] as? String
        let acceptsCommands = payload["accepts_commands"] as? Bool ?? false
        let pid = payload["pid"] as? Int ?? (payload["pid"] as? NSNumber)?.intValue

        if acceptsCommands {
            for otherFD in clients.keys where otherFD != fd {
                clients[otherFD]?.acceptsCommands = false
            }
        }

        clients[fd]?.role = role
        clients[fd]?.pid = pid
        clients[fd]?.acceptsCommands = acceptsCommands

        NSLog(
            "[VoiceBar] Client hello (fd: %d, role: %@, pid: %@, acceptsCommands: %@)",
            fd,
            role ?? "unknown",
            pid.map(String.init) ?? "unknown",
            acceptsCommands ? "true" : "false"
        )
        updateConnectionState()
    }

    // MARK: - Send to command client

    /// Send normal commands to the command-owning daemon. Stop/cancel also go
    /// to legacy direct MCP clients because a long-lived session may own the
    /// active playback process.
    func sendCommandToOwner(command: [String: Any]) {
        queue.async { [weak self] in
            self?.sendCommandToOwnerOnQueue(command: command)
        }
    }

    private func sendCommandToOwnerOnQueue(command: [String: Any]) {
        let commandName = command["cmd"] as? String

        guard let jsonData = try? JSONSerialization.data(withJSONObject: command),
              var jsonString = String(data: jsonData, encoding: .utf8)
        else { return }
        jsonString.append("\n")
        let bytes = Array(jsonString.utf8)

        let commandFDs = clients
            .filter(\.value.acceptsCommands)
            .map(\.key)
            .sorted()

        let isInterrupt = commandName == "stop" || commandName == "cancel"
        let legacyPlaybackFDs = isInterrupt
            ? clients.filter { $0.value.role == "mcp-server" }.map(\.key)
            : []
        let targetFDs: [Int32] = if isInterrupt,
                                    let playbackFD = activePlaybackClientFD,
                                    clients[playbackFD] != nil {
            [playbackFD]
        } else if commandName == "replay",
                  let playbackFD = lastPlaybackClientFD,
                  clients[playbackFD] != nil {
            [playbackFD]
        } else {
            Array(Set(
                isInterrupt ? commandFDs + legacyPlaybackFDs : Array(commandFDs.prefix(1))
            )).sorted()
        }

        guard !targetFDs.isEmpty else {
            NSLog(
                "[VoiceBar] No command client registered; dropping command %@",
                jsonString.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            notifyCommandDeliveryFailed(command: command, reason: "VoiceLayer is starting")
            return
        }

        if isInterrupt, targetFDs.count > 1 {
            NSLog("[VoiceBar] Broadcasting interrupt to %d playback-capable clients", targetFDs.count)
        }

        var deadFDs: [Int32] = []
        var deliveredCount = 0
        for targetFD in targetFDs {
            var totalWritten = 0
            var transientRetryCount = 0
            var deliveryFailed = false
            while totalWritten < bytes.count {
                switch writeToClient(fd: targetFD, bytes: bytes, offset: totalWritten) {
                case let .wrote(count):
                    totalWritten += count
                    transientRetryCount = 0
                case .retry:
                    transientRetryCount += 1
                    if transientRetryCount >= 3 {
                        NSLog(
                            "[VoiceBar] Socket write stalled (fd: %d) after %d retries",
                            targetFD,
                            transientRetryCount
                        )
                        deadFDs.append(targetFD)
                        deliveryFailed = true
                        totalWritten = bytes.count
                    }
                case let .peerClosed(errnoCode):
                    NSLog("[VoiceBar] Socket peer closed during write (fd: %d, errno: %d)", targetFD, errnoCode)
                    deadFDs.append(targetFD)
                    deliveryFailed = true
                    totalWritten = bytes.count
                case let .failed(errnoCode):
                    NSLog("[VoiceBar] Socket write failed (fd: %d, errno: %d)", targetFD, errnoCode)
                    deadFDs.append(targetFD)
                    deliveryFailed = true
                    totalWritten = bytes.count
                }
            }
            if !deliveryFailed { deliveredCount += 1 }
        }
        // Clean up clients that failed on write
        for fd in deadFDs {
            clients[fd]?.source.cancel()
        }
        if deliveredCount == 0 {
            notifyCommandDeliveryFailed(command: command, reason: "VoiceLayer is reconnecting")
        }
    }

    private func notifyCommandDeliveryFailed(command: [String: Any], reason: String) {
        DispatchQueue.main.async { [weak self] in
            self?.state.handleCommandDeliveryFailure(command, reason: reason)
        }
    }

    private func writeToClient(fd: Int32, bytes: [UInt8], offset: Int) -> SocketWriteResult {
        let result = bytes.withUnsafeBufferPointer { ptr in
            write(fd, ptr.baseAddress!.advanced(by: offset), bytes.count - offset)
        }
        let errnoCode = errno
        return classifySocketWriteResult(bytesWritten: result, errnoCode: errnoCode)
    }

    // MARK: - Client management

    private func removeClient(fd: Int32) {
        if lastPlaybackClientFD == fd { lastPlaybackClientFD = nil }
        if activePlaybackClientFD == fd { activePlaybackClientFD = nil }
        clients.removeValue(forKey: fd)
        NSLog("[VoiceBar] Client removed (fd: %d, remaining: %d)", fd, clients.count)
        updateConnectionState()
    }

    private func updateConnectionState() {
        let hasCommandClient = clients.values.contains { $0.acceptsCommands }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            state.setConnectionStatus(hasCommandClient)
        }
    }

    // MARK: - Cleanup

    private func cleanup() {
        cleanupOnQueue()
        NSLog("[VoiceBar] Server stopped")
        updateConnectionState()
    }

    deinit {
        // AIDEV-NOTE: Do NOT use queue.sync here — deinit can fire on the
        // queue itself (e.g., from a cancel handler) causing a deadlock.
        // Direct cleanup is safe in deinit because no other code holds a
        // reference to self at this point.
        cleanupOnQueue()
    }

    private func cleanupOnQueue() {
        listenSource?.cancel()
        listenSource = nil

        for (_, entry) in clients {
            entry.source.cancel()
        }
        clients.removeAll()

        if listenFD >= 0 {
            // listenSource's cancelHandler already calls close(fd), but guard
            // against the case where listenSource was nil (never started).
            listenFD = -1
        }

        unlinkOwnedSocketPath()
    }

    private func unlinkOwnedSocketPath() {
        guard ownsSocketPath else { return }
        unlink(socketPath)
        ownsSocketPath = false
    }
}
