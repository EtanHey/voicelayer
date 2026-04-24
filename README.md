# VoiceLayer

> Your AI agent can't hear you. VoiceLayer gives it ears and a voice.

[![npm](https://img.shields.io/npm/v/voicelayer-mcp.svg)](https://www.npmjs.com/package/voicelayer-mcp)
[![License: Apache-2.0](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](https://www.apache.org/licenses/LICENSE-2.0)
[![MCP](https://img.shields.io/badge/MCP-compatible-blue.svg)](https://modelcontextprotocol.io)
[![Tools](https://img.shields.io/badge/MCP%20tools-11-38BDF8.svg)](#voice-tools)
[![Tests](https://img.shields.io/badge/tests-536%20passing-brightgreen.svg)](#testing)

**Voice I/O for AI coding assistants.** Press F6, speak to Claude Code, get on-device transcription in under 1.5 seconds. Your AI speaks back. Works with any MCP client.

```
  You ──🎤──> whisper.cpp ──> Claude Code ──> edge-tts ──🔊──> You
         STT (local)           MCP tools         TTS (free)
```

**Local-first. Free. Open-source.** No cloud APIs, no API keys, no data leaves your machine. Part of the [Golems](https://etanheyman.com) ecosystem.

**[Website](https://voicelayer.etanheyman.com)** | **[Docs](https://etanhey.github.io/voicelayer/docs/)** | **[npm](https://www.npmjs.com/package/voicelayer-mcp)**

VoiceLayer runs as a persistent singleton daemon on a Unix socket — every Claude session connects through a lightweight `socat` shim instead of spawning its own process. 11 MCP tools with full [ToolAnnotations](https://spec.modelcontextprotocol.io/specification/2025-03-26/server/tools/#annotations).

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
# Install from npm
bun add -g voicelayer-mcp

# Prerequisites
brew install sox socat
pip3 install edge-tts
brew install whisper-cpp  # optional — local STT

# Download a whisper model (recommended)
mkdir -p ~/.cache/whisper
curl -L -o ~/.cache/whisper/ggml-large-v3-turbo.bin \
  https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin
```

Or install from source:

```bash
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

### Disabling VoiceLayer

`DISABLE_VOICELAYER=1` is a hard kill-switch for the MCP daemon.

```bash
# Install the LaunchAgent in a disabled state
DISABLE_VOICELAYER=1 ./launchd/install.sh

# Or edit the template-generated plist and add:
# <key>DISABLE_VOICELAYER</key>
# <string>1</string>
```

If the daemon is already running, create `/tmp/.claude_voice_disabled` and it will shut down within 5 seconds. To re-enable it, remove the env var from `~/Library/LaunchAgents/com.voicelayer.mcp-daemon.plist`, delete `/tmp/.claude_voice_disabled` if present, and restart the agent:

```bash
launchctl kickstart -k "gui/$(id -u)/com.voicelayer.mcp-daemon"
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

### Primary tools

| Tool | Behavior | Blocking | readOnly | destructive | idempotent |
|------|----------|:--------:|:--------:|:-----------:|:----------:|
| **`voice_speak`** | TTS with auto-mode (announce/brief/consult/think), replay, toggle | No | false | false | true |
| **`voice_ask`** | Speak question + record mic + transcribe response | Yes | false | false | false |

### Backward-compatible aliases

| Alias | Maps to | idempotent |
|-------|---------|:----------:|
| `qa_voice_announce` | `voice_speak(mode='announce')` | true |
| `qa_voice_brief` | `voice_speak(mode='brief')` | true |
| `qa_voice_consult` | `voice_speak(mode='consult')` | true |
| `qa_voice_say` | `voice_speak(mode='announce')` | true |
| `qa_voice_think` | `voice_speak(mode='think')` | false |
| `qa_voice_replay` | `voice_speak(replay_index=N)` | true |
| `qa_voice_toggle` | `voice_speak(enabled=bool)` | true |
| `qa_voice_converse` | `voice_ask` | false |
| `qa_voice_ask` | `voice_ask` | false |

All 11 tools include MCP [ToolAnnotations](https://spec.modelcontextprotocol.io/specification/2025-03-26/server/tools/#annotations). No VoiceLayer tools are destructive. All have `openWorldHint: false`.

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
| Stop signal | `touch ~/.local/state/voicelayer/stop-{token}` |
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
- **Global hotkey:** Cmd+F6 (hold for push-to-talk, double-tap to toggle hands-free)

```bash
cd flow-bar && ./build-app.sh   # Build, codesign, install to /Applications
```

**Hotkey Notes:**
- Requires Input Monitoring permission (System Settings > Privacy & Security)
- Cmd+F6 is chosen to avoid conflicts with VoiceOver (Cmd+F5) — if conflicts occur, the hotkey can be reconfigured via `HotkeyManager.configure()`
- Supports both F6 keyboard modes (function-key and media-key)

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
bun test   # 536 tests, 1638 assertions, 48 test files
```

Test coverage includes: MCP protocol framing, tool handlers, TTS synthesis + retry, VAD speech detection, session booking, process lock lifecycle, socket client reconnection, edge-tts health checks, schema validation, Hebrew STT eval baselines, daemon resilience, ToolAnnotations, SSML sanitization, and secure path hardening.

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
│   └── __tests__/                # 536 tests across 48 files
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

## Part of Golems

VoiceLayer is one of three open-source MCP servers in the [Golems](https://etanheyman.com) ecosystem:

| Server | What it does | Tools |
|--------|-------------|:-----:|
| **[BrainLayer](https://brainlayer.etanheyman.com)** | Persistent memory for AI agents — knowledge graph + hybrid search | 12 |
| **[VoiceLayer](https://voicelayer.etanheyman.com)** | Voice I/O — local STT, neural TTS, F6 push-to-talk | 11 |
| **[cmuxLayer](https://cmuxlayer.etanheyman.com)** | Terminal orchestration — spawn panes, read screens, coordinate agents | 22 |

Pair with BrainLayer to remember voice conversations across sessions.

## License

[Apache-2.0](LICENSE)
