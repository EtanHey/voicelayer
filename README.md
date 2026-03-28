# VoiceLayer

> Singleton MCP daemon that adds voice I/O to AI coding assistants. One process serves every session — no orphans, no contention, no hangs.

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![MCP](https://img.shields.io/badge/MCP-compatible-blue.svg)](https://modelcontextprotocol.io)
[![Tests](https://img.shields.io/badge/tests-359%20passing-brightgreen.svg)](#testing)
[![TypeScript](https://img.shields.io/badge/TypeScript-Bun-black.svg)](https://bun.sh)
[![Swift](https://img.shields.io/badge/Swift-SwiftUI-orange.svg)](https://developer.apple.com/swiftui/)

VoiceLayer gives Claude Code (and any MCP client) two tools: **`voice_speak`** for text-to-speech and **`voice_ask`** for speech-to-text. It runs as a persistent singleton daemon on a Unix socket — every Claude session connects through a lightweight `socat` shim instead of spawning its own process.

**Local-first. Free. Open-source.** TTS via edge-tts (Microsoft neural voices, free). STT via whisper.cpp (runs on-device). No cloud APIs required.

## Architecture

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

## Quick Start

```bash
# Prerequisites
brew install sox socat
pip3 install edge-tts
brew install whisper-cpp  # optional — local STT

# Download a whisper model (recommended)
mkdir -p ~/.cache/whisper
curl -L -o ~/.cache/whisper/ggml-large-v3-turbo.bin \
  https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin

# Clone and install
git clone https://github.com/EtanHey/voicelayer.git
cd voicelayer && bun install
```

### Start the Daemon

```bash
# Option A: LaunchAgent (auto-start on login, auto-restart on crash)
./launchd/install.sh

# Option B: Manual
bun run src/mcp-server-daemon.ts
```

### Configure MCP Clients

Add to your `.mcp.json` (in any repo where you use Claude Code):

```json
{
  "mcpServers": {
    "voicelayer": {
      "command": "socat",
      "args": ["STDIO", "UNIX-CONNECT:/tmp/voicelayer-mcp.sock"]
    }
  }
}
```

Or migrate all repos at once:

```bash
bash scripts/migrate-to-daemon.sh         # migrates every .mcp.json under ~/Gits
bash scripts/migrate-to-daemon.sh --dry-run  # preview without changes
```

Grant microphone access to your terminal (macOS: System Settings > Privacy > Microphone).

## Voice Tools

| Tool | Behavior | Blocking |
|------|----------|----------|
| **`voice_speak(message)`** | TTS with auto-mode detection. Announce (short), brief (long), consult (question), think (silent log). | No |
| **`voice_ask(message)`** | Speaks question, records mic, transcribes response. Auto-waits for prior audio. 30s default timeout. | Yes |

### How voice_ask Works

1. Waits for any playing `voice_speak` audio to finish
2. Speaks the question via edge-tts (with retry on failure)
3. Records mic at device native rate, resamples to 16kHz
4. Silero VAD detects speech onset and silence end
5. whisper.cpp transcribes locally (~200-400ms on Apple Silicon)
6. Returns transcription to the AI agent

### Reliability Features

- **PID lockfile** (`/tmp/voicelayer-mcp.pid`): On startup, detects and kills any orphan MCP server from a previous session
- **edge-tts retry**: Health check (cached 60s) + automatic retry with 30s hard timeout per attempt
- **Outer timeout guard**: `Promise.race` wrapper around the entire voice_ask flow — if anything hangs, returns an error instead of blocking forever
- **Session booking**: Lockfile mutex prevents mic conflicts between concurrent sessions

### Recording Controls

| Method | How |
|--------|-----|
| Stop signal | `touch /tmp/voicelayer-stop-{token}` |
| VAD silence | Configurable: quick (0.5s), standard (1.5s), thoughtful (2.5s) |
| Timeout | 30s default, configurable 5-3600s per call |
| Push-to-talk | `press_to_talk: true` — no VAD, stop on signal only |

## STT Backends

| Backend | Type | Latency | Setup |
|---------|------|---------|-------|
| **whisper.cpp** | Local (default) | ~200-400ms | `brew install whisper-cpp` + model download |
| **Wispr Flow** | Cloud (fallback) | ~500ms + network | Set `QA_VOICE_WISPR_KEY` env var |

Auto-detected. Override with `QA_VOICE_STT_BACKEND=whisper|wispr|auto`.

## Voice Bar (macOS)

Floating SwiftUI widget providing visual feedback during voice interactions. Connects to the daemon via NDJSON over `/tmp/voicelayer.sock`.

- Teleprompter with word-level highlighting and auto-scroll
- Waveform visualization during recording
- Expandable pill UI — collapses to dot after 5s idle
- Draggable, position persisted across launches

```bash
cd flow-bar && ./build-app.sh   # Build, codesign, install to /Applications
```

### Advanced: Voice Cloning

Three-tier TTS engine cascade for cloned voices:

1. **XTTS-v2** fine-tuned (cadence + timbre)
2. **F5-TTS MLX** zero-shot (local, no daemon)
3. **Qwen3-TTS** daemon (HTTP-based)
4. **edge-tts** fallback (always available)

```bash
voicelayer extract <youtube-url>   # Extract voice samples
voicelayer clone <name>            # Build voice profile
voicelayer daemon --port 8880      # Run Qwen3-TTS server
```

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `QA_VOICE_STT_BACKEND` | `auto` | STT backend: `whisper`, `wispr`, or `auto` |
| `QA_VOICE_WHISPER_MODEL` | auto-detected | Path to whisper.cpp GGML model |
| `QA_VOICE_WISPR_KEY` | -- | Wispr Flow API key (cloud fallback) |
| `QA_VOICE_TTS_VOICE` | `en-US-JennyNeural` | edge-tts voice ID |
| `QA_VOICE_TTS_RATE` | `+0%` | Base speech rate |

## Testing

```bash
bun test   # 359 tests, 1241 assertions, 36 test files
```

Test coverage includes: MCP protocol framing, tool handlers, TTS synthesis + retry, VAD speech detection, session booking, process lock lifecycle, socket client reconnection, edge-tts health checks, schema validation, Hebrew STT eval baselines, and daemon resilience.

## Project Structure

```
voicelayer/
├── src/                          # TypeScript/Bun (18K lines, 69 files)
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
│   └── __tests__/                # 359 tests across 36 files
├── flow-bar/                     # SwiftUI macOS app (1.9K lines, 9 files)
│   ├── Sources/VoiceBar/         # App source
│   └── Tests/                    # Swift tests
├── scripts/
│   ├── migrate-to-daemon.sh      # Batch .mcp.json migration
│   └── edge-tts-words.py         # Word-level TTS with timestamps
├── launchd/                      # macOS LaunchAgent auto-start
├── models/                       # Silero VAD ONNX model
└── package.json                  # v2.0.0
```

## Platform Support

| Platform | TTS | STT | Recording | Voice Bar |
|----------|-----|-----|-----------|-----------|
| **macOS** | edge-tts + afplay | whisper.cpp (CoreML) | sox | SwiftUI app |
| **Linux** | edge-tts + mpv/ffplay | whisper.cpp | sox | -- |

## License

[MIT](LICENSE)
