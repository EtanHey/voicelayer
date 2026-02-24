# Phase 4: Socket Client + State Flow

> [Back to main plan](../README.md)

## Goal

Implement the Unix domain socket client in Swift using Network.framework, connecting the Flow Bar to VoiceLayer's socket server with auto-reconnection and state updates.

## Research Source

`docs.local/logs/research-2-swiftui-window-socket.md` — Complete `NWConnection` + `NWEndpoint.unix()` implementation with NDJSON framing and reconnection logic.

## Key Technical Decisions

- **Framework:** Network.framework (`NWConnection` + `NWEndpoint.unix(path:)`) — confirmed working on macOS 13+ by Apple DTS
- **Transport:** `.tcp` parameter provides stream-oriented semantics over Unix socket
- **Framing:** Buffer incoming data, split on `\n`, parse each line as JSON (TCP delivers arbitrary chunks)
- **Reconnection:** Fixed 2-second delay, create NEW `NWConnection` each attempt (connections in `.failed`/`.cancelled` cannot restart)
- **Thread safety:** Socket callbacks on `DispatchQueue`, state updates dispatched to main thread via `DispatchQueue.main.async`
- **Command format:** `{"cmd": "stop"}` — matches Phase 1 protocol spec
- **Console noise:** Expect harmless `nw_socket_set_common_sockopts` log — safe to ignore per Apple DTS

## Tools

- **Code:** Claude Code (Swift)
- **Build:** `swift build` / `swift run`
- **Test:** Mock server (Python) from Phase 3

## Steps

1. Implement `SocketClient.swift` — `NWConnection` to `/tmp/voicelayer.sock`, state update handler, receive loop
2. Implement NDJSON receive buffer — accumulate chunks, split on `\n`, parse JSON lines
3. Implement `parseLine()` — map JSON fields to VoiceState properties (mode, transcript, error, speech detected)
4. Implement `send(command:)` — serialize JSON command + `\n`, send via connection
5. Implement reconnection — on `.failed`/`.waiting`, cancel connection, wait 2s, create new `NWConnection`
6. Implement `disconnect()` — set `intentionallyClosed = true`, cancel connection, skip reconnect
7. Wire into AppDelegate — create SocketClient, inject `sendCommand` closure into VoiceState, call `connect()` on launch, `disconnect()` on terminate
8. Wire `VoiceState.stop()`/`toggle()`/`replay()` → `SocketClient.send()` via the closure
9. Update `BarView.swift` — connect buttons to VoiceState actions, show disconnected state when `!isConnected`
10. Test with mock_server.py — verify state transitions, button commands, reconnection on server restart
11. Test with actual VoiceLayer (Phase 1+2 must be merged) — full end-to-end

## Protocol Mapping (JSON → VoiceState)

| JSON Field | VoiceState Property |
|------------|-------------------|
| `type: "state"`, `state: "idle"` | `mode = .idle` |
| `type: "state"`, `state: "speaking"`, `text: "..."` | `mode = .speaking`, `responseText = text` |
| `type: "state"`, `state: "recording"` | `mode = .recording` |
| `type: "state"`, `state: "transcribing"` | `mode = .transcribing` |
| `type: "speech"`, `detected: true/false` | `speechDetected = detected` (drives waveform) |
| `type: "transcription"`, `text: "..."` | `transcript = text` |
| `type: "error"`, `message: "..."` | `mode = .error`, `errorMessage = message` |
| Connection state `.ready` | `isConnected = true` |
| Connection `.failed`/`.cancelled` | `isConnected = false` |

## Depends On

- Phase 3 (SwiftUI app must exist)
- Phase 1 (socket server for end-to-end testing — but mock_server.py works for development)

## Status

- [ ] SocketClient NWConnection setup
- [ ] NDJSON receive buffer + line parsing
- [ ] JSON → VoiceState mapping
- [ ] Command sending
- [ ] Auto-reconnection (2s delay)
- [ ] Clean disconnect
- [ ] AppDelegate wiring
- [ ] Button → command wiring
- [ ] Disconnected state UI
- [ ] Mock server testing
- [ ] End-to-end testing with VoiceLayer
