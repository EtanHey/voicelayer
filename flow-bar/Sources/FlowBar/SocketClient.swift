// SocketClient.swift — Unix domain socket client for Voice Bar.
//
// Discovers the VoiceLayer socket by reading /tmp/voicelayer-session.json,
// which contains the per-session socket path, token, and PID.
// Watches the discovery file for changes so it reconnects immediately
// when a new VoiceLayer session starts.
//
// AIDEV-NOTE: NWConnection cannot be reused after .failed or .cancelled.
// Each reconnection creates a brand-new NWConnection instance.

import Foundation
import Network

final class SocketClient {
    /// Well-known path where VoiceLayer writes session info.
    static let discoveryPath = "/tmp/voicelayer-session.json"

    private let queue = DispatchQueue(label: "com.voicelayer.flowbar.socket", qos: .userInitiated)
    private var connection: NWConnection?
    private var buffer = ""
    private var intentionallyClosed = false
    private let state: VoiceState

    /// The socket path we're currently connected to (from discovery file).
    private var currentSocketPath: String?

    /// File system watcher for the discovery file.
    private var discoverySource: DispatchSourceFileSystemObject?

    // MARK: - Lifecycle

    init(state: VoiceState) {
        self.state = state
    }

    /// Start the connection loop. Reads the discovery file for the socket path.
    func connect() {
        intentionallyClosed = false
        startWatchingDiscoveryFile()
        attemptConnection()
    }

    func disconnect() {
        intentionallyClosed = true
        stopWatchingDiscoveryFile()
        connection?.cancel()
        connection = nil
    }

    // MARK: - Discovery

    /// Read the discovery file and return the socket path, or nil if unavailable.
    private func discoverSocketPath() -> String? {
        let url = URL(fileURLWithPath: Self.discoveryPath)
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let path = json["socketPath"] as? String
        else { return nil }
        return path
    }

    /// Attempt to connect using the discovered socket path.
    private func attemptConnection() {
        guard !intentionallyClosed else { return }

        guard let socketPath = discoverSocketPath() else {
            print("[FlowBar] No discovery file at \(Self.discoveryPath) — waiting...")
            setConnected(false)
            scheduleReconnect()
            return
        }

        // Log when we discover a new or changed socket path
        if socketPath != currentSocketPath {
            if currentSocketPath != nil {
                print("[FlowBar] Session changed — new socket: \(socketPath)")
            } else {
                print("[FlowBar] Discovered socket: \(socketPath)")
            }
            currentSocketPath = socketPath
        }

        let conn = NWConnection(to: .unix(path: socketPath), using: .tcp)
        connection = conn

        conn.stateUpdateHandler = { [weak self] newState in
            guard let self else { return }
            switch newState {
            case .ready:
                setConnected(true)
                receiveLoop()

            case let .failed(error):
                print("[FlowBar] Connection failed: \(error)")
                handleDisconnect()

            case let .waiting(error):
                print("[FlowBar] Waiting: \(error)")
                handleDisconnect()

            case .cancelled:
                setConnected(false)

            default:
                break
            }
        }

        conn.start(queue: queue)
    }

    // MARK: - File watching

    /// Watch the discovery file for changes. When VoiceLayer writes a new
    /// session file (atomic rename), the old inode gets a delete/rename event
    /// which triggers re-discovery and reconnection.
    private func startWatchingDiscoveryFile() {
        stopWatchingDiscoveryFile()

        let fd = open(Self.discoveryPath, O_EVTONLY)
        guard fd >= 0 else {
            // File doesn't exist yet — reconnect timer will poll
            return
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename, .attrib],
            queue: queue
        )
        source.setEventHandler { [weak self] in
            self?.handleDiscoveryFileChanged()
        }
        source.setCancelHandler {
            close(fd)
        }
        source.resume()
        discoverySource = source
    }

    private func stopWatchingDiscoveryFile() {
        discoverySource?.cancel()
        discoverySource = nil
    }

    /// Called when the discovery file changes on disk.
    private func handleDiscoveryFileChanged() {
        guard !intentionallyClosed else { return }

        guard let newPath = discoverSocketPath() else {
            // Discovery file was deleted — VoiceLayer shut down
            print("[FlowBar] Discovery file removed — disconnecting")
            connection?.cancel()
            connection = nil
            buffer = ""
            currentSocketPath = nil
            setConnected(false)
            // Re-establish watcher (old fd is now invalid)
            startWatchingDiscoveryFile()
            scheduleReconnect()
            return
        }

        if newPath != currentSocketPath {
            // New session — drop old connection and reconnect
            print("[FlowBar] Discovery file updated — reconnecting to \(newPath)")
            connection?.cancel()
            connection = nil
            buffer = ""
            currentSocketPath = nil
            // Re-establish watcher on the new file inode
            startWatchingDiscoveryFile()
            attemptConnection()
        }
    }

    // MARK: - Send

    func send(command: [String: Any]) {
        guard let connection else { return }
        guard let jsonData = try? JSONSerialization.data(withJSONObject: command),
              var jsonString = String(data: jsonData, encoding: .utf8) else { return }
        jsonString.append("\n")
        connection.send(
            content: Data(jsonString.utf8),
            completion: .contentProcessed { error in
                if let error { print("[FlowBar] Send error: \(error)") }
            }
        )
    }

    // MARK: - Receive

    private func receiveLoop() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 65536) {
            [weak self] data, _, isDone, error in
            guard let self else { return }

            if let data, !data.isEmpty {
                buffer.append(String(decoding: data, as: UTF8.self))
                drainLines()
            }
            if error != nil || isDone {
                handleDisconnect()
                return
            }
            receiveLoop()
        }
    }

    /// TCP delivers arbitrary byte chunks. Buffer and split on newlines.
    private func drainLines() {
        while let idx = buffer.firstIndex(of: "\n") {
            let line = String(buffer[buffer.startIndex ..< idx])
            buffer = String(buffer[buffer.index(after: idx)...])
            if !line.isEmpty { parseLine(line) }
        }
    }

    private func parseLine(_ json: String) {
        guard let data = json.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            print("[FlowBar] Bad JSON: \(json)")
            return
        }

        DispatchQueue.main.async { [weak self] in
            self?.state.handleEvent(dict)
        }
    }

    // MARK: - Reconnection

    private func handleDisconnect() {
        connection?.cancel()
        connection = nil
        buffer = ""
        setConnected(false)

        guard !intentionallyClosed else { return }

        // Clear current path so next attempt re-reads discovery file
        currentSocketPath = nil
        // Re-establish watcher (old fd may be invalid after disconnect)
        startWatchingDiscoveryFile()
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        queue.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self, !self.intentionallyClosed else { return }
            print("[FlowBar] Reconnecting...")
            attemptConnection()
        }
    }

    private func setConnected(_ value: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            state.isConnected = value
            if !value {
                state.mode = .disconnected
            }
        }
    }
}
