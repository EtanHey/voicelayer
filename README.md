# VoiceLayer

> Your AI agent can't hear you. VoiceLayer gives it ears and a voice.

[![npm](https://img.shields.io/npm/v/voicelayer-mcp.svg)](https://www.npmjs.com/package/voicelayer-mcp)
[![License: Apache-2.0](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](https://www.apache.org/licenses/LICENSE-2.0)
[![MCP](https://img.shields.io/badge/MCP-compatible-blue.svg)](https://modelcontextprotocol.io)
[![Tools](https://img.shields.io/badge/MCP%20tools-2%20core%20%2B%209%20aliases-38BDF8.svg)](#voice-tools)
[![Tests](https://img.shields.io/badge/tests-585%20Bun%20%2B%20144%20Swift-brightgreen.svg)](#testing)

**Voice I/O for AI coding assistants.** Press F5, speak to Claude Code, get on-device transcription in under 1.5 seconds. Your AI speaks back. Works with any MCP client.

```
  You ──🎤──> whisper.cpp ──> Claude Code ──> edge-tts ──🔊──> You
         STT (local)           MCP tools         TTS (free)
```

**Local-first. Free. Open-source.** No cloud APIs, no API keys, no data leaves your machine. Part of the [Golems](https://etanheyman.com) ecosystem.

**[Website](https://voicelayer.etanheyman.com)** | **[Docs](https://etanhey.github.io/voicelayer/docs/)** | **[npm](https://www.npmjs.com/package/voicelayer-mcp)**

VoiceLayer runs as a persistent singleton daemon on a Unix socket — every Claude session connects through a lightweight `socat` shim instead of spawning its own process. 2 canonical MCP tools plus 9 backward-compatible aliases ship with full [ToolAnnotations](https://spec.modelcontextprotocol.io/specification/2025-03-26/server/tools/#annotations).

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

`launchd/install.sh` prefers the installed VoiceBar bundle at
`/Applications/VoiceBar.app/Contents/Resources` and falls back to the checkout
when the bundle is not present. LaunchAgent logs are written to
`~/Library/Logs/VoiceLayer/`. Launchd keeps the daemon alive while
`/tmp/.voicelayer-daemon-disabled` is absent.

### Disabling VoiceLayer
`DISABLE_VOICELAYER=1` is a hard kill-switch for the MCP daemon.

```bash
# Install the LaunchAgent in a disabled state and sync the runtime daemon flag
DISABLE_VOICELAYER=1 ./launchd/install.sh

# Re-enable the LaunchAgent
./launchd/install.sh
```

If the daemon is already running, `DISABLE_VOICELAYER=1 ./launchd/install.sh`
creates `/tmp/.voicelayer-daemon-disabled`, stops the current agent, and leaves
launchd idle. Plain `./launchd/install.sh` removes the flag and bootstraps the
agent again. For manual non-launchd runs, creating the flag still makes the
daemon shut down within 5 seconds. If the plist is already loaded and only needs
a manual nudge:

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
- **Global hotkey:** F5 (hold for push-to-talk)

```bash
bun add -g voicelayer-mcp
voicelayer hotkey install       # Install F5/Dictation -> F18 relay
voicelayer bar                  # Build and launch Voice Bar
```

**Hotkey Notes:**
- Requires Input Monitoring permission (System Settings > Privacy & Security)
- On keyboards where the physical key is Apple's Dictation key, `voicelayer hotkey install` installs a `hidutil` LaunchAgent to map F5/Dictation to VoiceBar's internal F18 relay.
- The installer preserves non-VoiceBar `hidutil` mappings and is safe to rerun. `Shift+F5` re-pastes the latest transcript.

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

The Qwen3 daemon now uses bearer auth from `~/.voicelayer/daemon.secret`
(created on first launch with mode `0600`). The TypeScript bridge reads the
same file automatically. Override the location with
`VOICELAYER_TTS_DAEMON_SECRET_FILE`,
`VOICELAYER_TTS_AUTH_TOKEN_FILE`, or
`voicelayer daemon --daemon-secret-file ...` if you need a custom launcher
path. The daemon only accepts `Host: 127.0.0.1:8880` /
`Host: localhost:8880`, rejects non-local `Origin` headers, and only reads
`reference_wav` files that resolve under `~/.voicelayer/voices/`.

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `QA_VOICE_STT_BACKEND` | `auto` | STT backend: `whisper`, `wispr`, or `auto` |
| `QA_VOICE_WHISPER_MODEL` | auto-detected | Path to whisper.cpp GGML model |
| `QA_VOICE_WISPR_KEY` | -- | Wispr Flow API key (cloud fallback) |
| `QA_VOICE_TTS_VOICE` | `en-US-JennyNeural` | edge-tts voice ID |
| `QA_VOICE_TTS_RATE` | `+0%` | Base speech rate |
| `VOICELAYER_TTS_DAEMON_SECRET_FILE` | `~/.voicelayer/daemon.secret` | Preferred override for the shared Qwen3 daemon bearer secret file |
| `VOICELAYER_TTS_AUTH_TOKEN_FILE` | `~/.voicelayer/daemon.secret` | Backward-compatible override for the shared Qwen3 daemon bearer secret file |

## Testing

```bash
bun test                              # 585 Bun tests + 1 skip (latest verified on PR #190 pre-push gate)
bash flow-bar/run_tests.sh            # 144 Swift tests for VoiceBar
git config core.hooksPath .githooks   # install repo pre-push hook once per clone (#181, #182)
```

Test coverage includes: MCP protocol framing, tool handlers, TTS synthesis + retry, VAD speech detection, session booking, process lock lifecycle, socket client reconnection, edge-tts health checks, schema validation, Hebrew STT eval baselines, daemon resilience, ToolAnnotations, SSML sanitization, and secure path hardening.

## Recent Hardening (2026-04-27 → 2026-05-02)

One-week sprint focused on VoiceBar reliability and a recording corpus to fight STT regressions. Every line below traces to a merged PR.

**Recording reliability**
- Recording control clickability restored — F6 socket controls remained interactive while the pill animated ([#188](https://github.com/EtanHey/voicelayer/pull/188)).
- Pill bottom anchor preserved during resize so the UI doesn't drift off-screen ([#187](https://github.com/EtanHey/voicelayer/pull/187)).
- Waveform animates again on real audio input + redundant "listening" copy removed ([#184](https://github.com/EtanHey/voicelayer/pull/184)).
- Waveform dynamic range restored above the silence gate ([#185](https://github.com/EtanHey/voicelayer/pull/185)).
- Custom VoiceBar install paths supported (no more hard-coded `/Applications/VoiceBar.app`) ([#186](https://github.com/EtanHey/voicelayer/pull/186)).
- VoiceBar transcription preserved through the recording RMS gate so quiet speech survives ([#177](https://github.com/EtanHey/voicelayer/pull/177)).
- Stale daemon restart detection — VoiceBar transcription resumes automatically after the daemon restarts ([#183](https://github.com/EtanHey/voicelayer/pull/183)).

**STT quality**
- No-input STT hallucinations suppressed ([#189](https://github.com/EtanHey/voicelayer/pull/189)).
- Zero-RMS audio ingestion watchdog catches a silent mic before whisper.cpp guesses ([#178](https://github.com/EtanHey/voicelayer/pull/178)).

**VoiceBar dictation corpus (Phase 1)** — [#190](https://github.com/EtanHey/voicelayer/pull/190)
- Every successful VoiceBar dictation is archived under `~/.local/share/voicelayer/recordings/YYYY-MM-DD/<timestamp-id>/` with `audio.wav` + `voicelayer-transcript.txt` + `metadata.json` (schema v1, SHA-256 over WAV bytes).
- Atomic rename + fsync so partial writes never appear in the corpus.
- Cancelled or empty transcriptions are skipped — only real dictations land on disk.
- Re-paste hotkey moved to `Shift+F5`; plain `F5` is now the default record-start/stop activation through VoiceBar's F18 relay.

**Test infrastructure**
- VoiceLayer pre-push regression gate ([#181](https://github.com/EtanHey/voicelayer/pull/181)) plus exit-0 fix on the success path ([#182](https://github.com/EtanHey/voicelayer/pull/182)).
- `voicelayer run_tests.sh` orchestrator script unifies Bun + Swift + daemon-boot + Karabiner smoke runs ([#180](https://github.com/EtanHey/voicelayer/pull/180)).
- VoiceBar audio fixtures for golden-path STT regressions ([#179](https://github.com/EtanHey/voicelayer/pull/179)).


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
| **[VoiceLayer](https://voicelayer.etanheyman.com)** | Voice I/O — local STT, neural TTS, F5 push-to-talk | 11 |
| **[cmuxLayer](https://cmuxlayer.etanheyman.com)** | Terminal orchestration — spawn panes, read screens, coordinate agents | 22 |

Pair with BrainLayer to remember voice conversations across sessions.

## License

[Apache-2.0](LICENSE)
