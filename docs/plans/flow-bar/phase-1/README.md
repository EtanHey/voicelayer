# Phase 1: Socket Server (Bun)

> [Back to main plan](../README.md)

## Goal

Add a Unix domain socket server to VoiceLayer that broadcasts JSON state events and receives commands from the Flow Bar.

## Research Source

`docs.local/logs/research-3-bun-unix-socket.md` — Complete `Bun.listen({ unix })` API reference with production-ready broadcast server code, backpressure handling, and MCP coexistence patterns.

## Key Technical Decisions

- **API:** `Bun.listen<ClientData>({ unix: SOCKET_PATH })` — native Bun, no `node:net` fallback needed
- **Path:** `/tmp/voicelayer.sock` (single-user macOS for now)
- **Protocol:** Newline-delimited JSON (NDJSON) — one JSON object per line, `\n` terminated
- **Backpressure:** `socket.write()` returns bytes written, `-1` if dead. Queue in `pendingWrite`, flush in `drain` handler
- **MCP coexistence:** Socket server runs alongside StdioServerTransport on same event loop. All socket logging → `console.error()` (stderr only — stdout reserved for MCP JSON-RPC)
- **Cleanup:** Unlink socket file on startup (stale from crash) and on SIGINT/SIGTERM/exit

## Protocol Spec (v1)

### Events (VoiceLayer → Bar)

```json
{"type": "state", "state": "idle"}
{"type": "state", "state": "speaking", "text": "What do you think about...", "voice": "jenny"}
{"type": "state", "state": "recording", "mode": "vad", "silence_mode": "quick"}
{"type": "state", "state": "recording", "mode": "ptt"}
{"type": "state", "state": "transcribing"}
{"type": "speech", "detected": true}
{"type": "speech", "detected": false}
{"type": "transcription", "text": "The user said this"}
{"type": "error", "message": "Mic not available", "recoverable": true}
```

### Commands (Bar → VoiceLayer)

```json
{"cmd": "stop"}
{"cmd": "replay"}
{"cmd": "toggle", "scope": "all"|"tts"|"mic", "enabled": boolean}
```

## Tools

- **Code:** Claude Code (Bun/TypeScript)
- **Tests:** `bun test`

## Steps

1. Define TypeScript types for socket protocol (events + commands) in `src/socket-protocol.ts`
2. Write tests for protocol serialization/deserialization
3. Create `src/socket-server.ts` — `Bun.listen({ unix })` with client tracking, broadcast, backpressure, NDJSON framing
4. Write tests for socket server: connect, receive broadcast, send command, disconnect handling, stale socket cleanup
5. Create `broadcast()` and `handleCommand()` exports that other modules will call
6. Wire socket server startup into `src/mcp-server.ts` — start alongside MCP, shut down on exit
7. Add socket path to `src/paths.ts` constants
8. Verify MCP + socket coexistence (both running, no stdout pollution)
9. Update CLAUDE.md with socket server section

## Depends On

- None (first phase)

## Status

- [ ] Protocol types (`src/socket-protocol.ts`)
- [ ] Protocol serialization tests
- [ ] Socket server (`src/socket-server.ts`)
- [ ] Socket server tests (connect, broadcast, command, disconnect, cleanup)
- [ ] Wire into MCP server startup
- [ ] Path constants in `src/paths.ts`
- [ ] MCP coexistence verification
- [ ] CLAUDE.md update
