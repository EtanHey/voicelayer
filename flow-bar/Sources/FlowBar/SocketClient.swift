// SocketClient.swift — Unix domain socket client for Voice Bar.
//
// Connects to VoiceLayer's per-session socket discovered via
// /tmp/voicelayer-session.json. Receives NDJSON state events,
// sends commands. Auto-reconnects on disconnect.

import Foundation
import Network

final class SocketClient {
    private var socketPath: String?
    private let queue = DispatchQueue(label: "com.voicelayer.flowbar.socket", qos: .userInitiated)
    private var connection: NWConnection?
    private var buffer = ""
    private var intentionallyClosed = false
    private let state: VoiceState

    /// Current backoff delay for reconnection (exponential: 2s → 4s → 8s → 16s → 30s max).
    private var reconnectDelay: TimeInterval = 2.0
    private static let maxReconnectDelay: TimeInterval = 30.0

    // MARK: - Lifecycle

    init(state: VoiceState) {
        self.state = state
    }

    func connect(to path: String) {
        intentionallyClosed = false
        socketPath = path
        startConnection(to: path)
    }

    func disconnect() {
        intentionallyClosed = true
        connection?.cancel()
        connection = nil
    }

    /// Reconnect to a new socket path (e.g., when discovery file changes).
    func reconnect(to newPath: String) {
        queue.async { [weak self] in
            guard let self else { return }
            NSLog("[FlowBar] Reconnecting to new socket: \(newPath)")
            connection?.cancel()
            connection = nil
            buffer = ""
            socketPath = newPath
            reconnectDelay = 2.0 // Reset backoff on explicit reconnect
            intentionallyClosed = false
            startConnection(to: newPath)
        }
    }

    // MARK: - Connection setup

    /// Create a new NWConnection, attach the state handler, and start it.
    /// NWConnection cannot be reused after .failed or .cancelled —
    /// each reconnection must create a new instance.
    private func startConnection(to path: String) {
        let conn = NWConnection(to: .unix(path: path), using: .tcp)
        connection = conn

        conn.stateUpdateHandler = { [weak self] newState in
            guard let self else { return }
            switch newState {
            case .ready:
                NSLog("[FlowBar] Connected to socket")
                setConnected(true)
                receiveLoop()
            case let .failed(error):
                NSLog("[FlowBar] Connection failed: \(error)")
                handleDisconnect()
            case let .waiting(error):
                NSLog("[FlowBar] Waiting: \(error)")
                handleDisconnect()
            case .cancelled:
                setConnected(false)
            default:
                break
            }
        }

        NSLog("[FlowBar] Connecting to %@", path)
        conn.start(queue: queue)
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
                if let error { NSLog("[FlowBar] Send error: \(error)") }
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
            NSLog("[FlowBar] Bad JSON: \(json)")
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
        guard let socketPath else { return } // No path = can't reconnect

        // Exponential backoff: 2s → 4s → 8s → 16s → 30s max (A4 fix)
        let delay = reconnectDelay
        reconnectDelay = min(reconnectDelay * 2, Self.maxReconnectDelay)

        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, !self.intentionallyClosed else { return }
            NSLog("[FlowBar] Reconnecting to %@ (backoff: %.0fs)...", socketPath, delay)
            startConnection(to: socketPath)
        }
    }

    private func setConnected(_ value: Bool) {
        if value {
            reconnectDelay = 2.0 // Reset backoff on successful connection
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            state.isConnected = value
            state.onConnectionChange?(value)
            if value {
                // Transition from disconnected to idle when socket connects.
                // The server doesn't send initial state on connect, so we
                // assume idle until the next state event arrives.
                if state.mode == .disconnected {
                    state.mode = .idle
                }
            } else {
                state.mode = .disconnected
            }
        }
    }
}
