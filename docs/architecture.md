# VoiceLayer Architecture

Why VoiceLayer runs as a single daemon instead of a process per session, and how the pieces fit.

## The daemon

```
                  ┌─────────────────────────────────────┐
                  │         VoiceLayer Daemon            │
                  │     /tmp/voicelayer-mcp.sock         │
                  │                                      │
                  │  MCP JSONRPC ──> Tool Handlers       │
                  │  (Content-Length     ├── voice_speak  │
                  │   framing)          └── voice_ask    │
                  │                                      │
                  │  TTS: edge-tts (retry + 30s timeout) │
                  │  STT: whisper.cpp / Wispr Flow       │
                  │  VAD: Silero ONNX (speech detection)  │
                  │  IPC: Voice Bar ← NDJSON events      │
                  └──────────┬──────────────────────────┘
                             │ Unix socket
              ┌──────────────┼──────────────┐
              │              │              │
         Claude Code    Claude Code    Cursor/Codex
         (socat shim)  (socat shim)   (socat shim)
```

**Why a daemon?** The original design spawned a new Bun process per Claude session. With 17+ repos open, that meant 17 competing processes (700+ MB RAM), fighting over one Voice Bar socket, crashing edge-tts with PATH issues, and leaving orphans that never died. The daemon architecture — shipped in PRs #67-72 — replaced all of that with a single process and `socat` shims.

| Metric | Before (spawn-per-session) | After (daemon) |
|--------|---------------------------|----------------|
| Processes | N per session (17+ typical) | 1 daemon + socat shims |
| RAM | ~700 MB (17 x 41 MB) | ~50 MB |
| Orphan cleanup | Manual `pkill` | PID lockfile auto-kills stale |
| edge-tts failures | Random (PATH, contention) | Retry with 30s hard timeout |
| voice_ask hang | Up to 300s (5 min!) | 30s default + outer guard |


## Reliability

- **PID lockfile** (`/tmp/voicelayer-mcp.pid`) — on startup, detects and kills any orphan MCP
  server left by a previous session.
- **edge-tts retry** — health check (cached 60s) plus automatic retry with a 30s hard timeout
  per attempt.
- **Outer timeout guard** — a `Promise.race` wrapper around the whole `voice_ask` flow, so a
  hang returns an error instead of blocking the agent forever.
- **Session booking** — a lockfile mutex prevents microphone conflicts between concurrent
  sessions (see [Session Booking](architecture/session-booking.md)).

## Recording controls

| Method | How |
|--------|-----|
| Stop signal | `touch ~/.local/state/voicelayer/stop-{token}` |
| VAD silence | quick (0.5s), standard (1.5s), thoughtful (2.5s) |
| Timeout | 30s default, configurable 5-3600s per call |
| MCP manual stop | `push_to_end: true` with `VOICELAYER_ALLOW_PUSH_TO_END=1` — disables VAD, requires an explicit stop |
| VoiceBar F5/tap | Trusted socket field `press_to_talk: true` — deliberately unchanged and not MCP-gated |

## Project Structure

```
voicelayer/
├── src/                          # TypeScript/Bun (~80 non-test source files)
│   ├── mcp-server-daemon.ts      # Singleton daemon entry point
│   ├── mcp-server.ts             # Stdio MCP server (legacy)
│   ├── mcp-daemon.ts             # Unix socket server (dual-protocol)
│   ├── mcp-framing.ts            # Content-Length + NDJSON framing
│   ├── mcp-handler.ts            # JSONRPC request router
│   ├── process-lock.ts           # PID lockfile (orphan prevention)
│   ├── handlers.ts               # Tool handler implementations
│   ├── tts.ts                    # Multi-engine TTS with playback queue
│   ├── tts-health.ts             # edge-tts health check + retry
│   ├── input.ts                  # Mic recording + STT pipeline
│   ├── vad.ts                    # Silero VAD (ONNX inference)
│   ├── stt.ts                    # STT backend abstraction
│   ├── socket-client.ts          # Voice Bar IPC (auto-reconnect)
│   ├── session-booking.ts        # Lockfile mutex
│   ├── paths.ts                  # Centralized path constants
│   └── __tests__/                # ~95 test files
├── flow-bar/                     # SwiftUI/AppKit macOS app (~62 Swift files)
│   ├── Sources/VoiceBar/         # App + daemon-owner source
│   ├── Sources/VoiceBarUI/       # Notch UI — VoiceBarNotch* suite (glass,
│   │                             #   morph motion, hit region, context menu)
│   └── Tests/                    # Swift tests
├── scripts/
│   ├── migrate-to-daemon.sh      # Batch .mcp.json migration
│   └── edge-tts-words.py         # Word-level TTS with timestamps
├── launchd/                      # VoiceBar LaunchAgent + retired daemon cleanup
├── models/                       # Silero VAD ONNX model
└── package.json                  # version source of truth
```

