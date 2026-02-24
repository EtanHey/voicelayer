// SocketClient.swift — Unix domain socket client for Voice Bar.
//
// Connects to VoiceLayer's socket at /tmp/voicelayer.sock using Network.framework.
// Receives NDJSON state events, sends commands. Auto-reconnects on disconnect.
//
// AIDEV-NOTE: NWConnection cannot be reused after .failed or .cancelled.
// Each reconnection creates a brand-new NWConnection instance.

import Foundation
import Network

final class SocketClient {
    private let socketPath: String
    private let queue = DispatchQueue(label: "com.voicelayer.flowbar.socket", qos: .userInitiated)
    private var connection: NWConnection?
    private var buffer = ""
    private var intentionallyClosed = false
    private let state: VoiceState

    // MARK: - Lifecycle

    init(socketPath: String, state: VoiceState) {
        self.socketPath = socketPath
        self.state = state
    }

    func connect() {
        intentionallyClosed = false

        // NWEndpoint.unix(path:) -- confirmed API, macOS 13+.
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

    func disconnect() {
        intentionallyClosed = true
        connection?.cancel()
        connection = nil
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

        // Wait 2 seconds, then create a brand-new NWConnection.
        queue.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self, !self.intentionallyClosed else { return }
            print("[FlowBar] Reconnecting to \(socketPath)...")
            connect()
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
