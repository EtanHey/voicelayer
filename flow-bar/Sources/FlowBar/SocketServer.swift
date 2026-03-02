// SocketServer.swift — Unix domain socket server for Voice Bar.
//
// POSIX socket server on /tmp/voicelayer.sock. Accepts connections from
// MCP server instances (clients). Receives NDJSON state events, forwards
// commands back. NWListener does NOT support Unix domain sockets, so we
// use POSIX sockets + GCD DispatchSource.
//
// AIDEV-NOTE: Architecture inversion (Phase 0) — FlowBar is the persistent
// server. MCP servers connect as clients. This replaces SocketClient.swift.

import Foundation

final class SocketServer {
    private let socketPath = "/tmp/voicelayer.sock"
    private let queue = DispatchQueue(label: "com.voicelayer.flowbar.server", qos: .userInitiated)
    private let state: VoiceState

    /// Listening socket file descriptor.
    private var listenFD: Int32 = -1
    /// GCD source watching the listen socket for incoming connections.
    private var listenSource: DispatchSourceRead?

    /// Connected clients: fd → (readSource, NDJSON buffer).
    private var clients: [Int32: (source: DispatchSourceRead, buffer: String)] = [:]

    // MARK: - Lifecycle

    init(state: VoiceState) {
        self.state = state
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
            NSLog("[FlowBar] Failed to create socket: errno %d", errno)
            return
        }

        // Bind to path
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = socketPath.utf8CString
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
            NSLog("[FlowBar] Socket path too long: %@", socketPath)
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
            NSLog("[FlowBar] Failed to bind socket: errno %d", errno)
            close(fd)
            return
        }

        // Restrict to current user (0600)
        chmod(socketPath, 0o600)

        // Listen with a small backlog
        guard listen(fd, 5) == 0 else {
            NSLog("[FlowBar] Failed to listen: errno %d", errno)
            close(fd)
            unlink(socketPath)
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

        NSLog("[FlowBar] Server listening on %@", socketPath)
        updateConnectionState()
    }

    // MARK: - Accept

    private func acceptClient() {
        let clientFD = accept(listenFD, nil, nil)
        guard clientFD >= 0 else {
            if errno != EWOULDBLOCK, errno != EAGAIN {
                NSLog("[FlowBar] accept() failed: errno %d", errno)
            }
            return
        }

        // Set non-blocking
        let flags = fcntl(clientFD, F_GETFL)
        _ = fcntl(clientFD, F_SETFL, flags | O_NONBLOCK)

        NSLog("[FlowBar] Client connected (fd: %d, total: %d)", clientFD, clients.count + 1)

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

        clients[clientFD] = (source: readSource, buffer: "")
        updateConnectionState()
    }

    // MARK: - Read

    private func readFromClient(fd: Int32) {
        var buf = [UInt8](repeating: 0, count: 65536)
        let bytesRead = read(fd, &buf, buf.count)

        if bytesRead <= 0 {
            // EOF or error — client disconnected
            NSLog("[FlowBar] Client disconnected (fd: %d)", fd)
            clients[fd]?.source.cancel()
            return
        }

        guard var entry = clients[fd] else { return }

        let chunk = String(bytes: buf[0 ..< bytesRead], encoding: .utf8) ?? ""
        entry.buffer.append(chunk)

        // NDJSON framing: split on newlines
        while let idx = entry.buffer.firstIndex(of: "\n") {
            let line = String(entry.buffer[entry.buffer.startIndex ..< idx])
            entry.buffer = String(entry.buffer[entry.buffer.index(after: idx)...])
            if !line.isEmpty {
                parseLine(line)
            }
        }

        clients[fd] = entry
    }

    private func parseLine(_ json: String) {
        guard let data = json.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            NSLog("[FlowBar] Bad JSON from client: %@", json)
            return
        }

        DispatchQueue.main.async { [weak self] in
            self?.state.handleEvent(dict)
        }
    }

    // MARK: - Send to all clients

    /// Send a command (JSON + newline) to all connected MCP clients.
    func sendToAll(command: [String: Any]) {
        queue.async { [weak self] in
            guard let self else { return }
            guard let jsonData = try? JSONSerialization.data(withJSONObject: command),
                  var jsonString = String(data: jsonData, encoding: .utf8)
            else { return }
            jsonString.append("\n")
            let bytes = Array(jsonString.utf8)

            for (fd, _) in clients {
                var totalWritten = 0
                while totalWritten < bytes.count {
                    let n = bytes.withUnsafeBufferPointer { ptr in
                        write(fd, ptr.baseAddress!.advanced(by: totalWritten), bytes.count - totalWritten)
                    }
                    if n <= 0 { break }
                    totalWritten += n
                }
            }
        }
    }

    // MARK: - Client management

    private func removeClient(fd: Int32) {
        clients.removeValue(forKey: fd)
        NSLog("[FlowBar] Client removed (fd: %d, remaining: %d)", fd, clients.count)
        updateConnectionState()
    }

    private func updateConnectionState() {
        let count = clients.count
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let wasConnected = state.isConnected
            state.isConnected = count > 0
            // AIDEV-NOTE: FlowBar is a persistent server — never show "disconnected".
            // When MCP clients leave, stay in idle. MCP connection status is in the menu bar.
            if wasConnected != state.isConnected {
                state.onConnectionChange?(state.isConnected)
            }
        }
    }

    // MARK: - Cleanup

    private func cleanup() {
        listenSource?.cancel()
        listenSource = nil

        for (_, entry) in clients {
            entry.source.cancel()
        }
        clients.removeAll()

        if listenFD >= 0 {
            // fd is closed by the cancel handler
            listenFD = -1
        }

        unlink(socketPath)
        NSLog("[FlowBar] Server stopped")

        updateConnectionState()
    }

    deinit {
        cleanup()
    }
}
