# VoiceLayer

> Voice I/O layer for AI coding assistants. MCP server with 4 voice modes + silent thinking + replay + toggle.

## Architecture

```text
Claude Code session
  ├── Playwright MCP (browser snapshots, --extension for co-browsing)
  ├── VoiceLayer MCP (this repo)
  │   ├── voice_speak(message, mode?, voice?) → NON-BLOCKING TTS
  │   │   Three-tier routing:
  │   │     1. Cloned voice (profile.yaml) → Qwen3-TTS daemon (port 8880)
  │   │     2. Preset voice → edge-tts (default)
  │   │     3. Fallback → text-only
  │   │   Also: replay_index, enabled (toggle)
  │   ├── voice_ask(message) → BLOCKING speak + record + transcribe
  │   ├── qa_voice_* → backward-compat aliases
  │   └── Unix socket (/tmp/voicelayer.sock) → Flow Bar IPC
  │       ├── Broadcasts: state, speech, transcription, error events (NDJSON)
  │       └── Receives: stop, replay, toggle commands
  └── Supabase MCP (data persistence)

Flow Bar (separate native macOS app — SwiftUI)
  ├── Connects to /tmp/voicelayer.sock as client
  ├── Shows voice state (idle/speaking/recording/transcribing)
  ├── Animated waveform bars
  └── Controls: stop, replay, toggle
```

## TTS Backends (Three-Tier)

| Tier | Engine | Use Case | Latency | Setup |
|------|--------|----------|---------|-------|
| 1 | **Qwen3-TTS** (MLX 4-bit) | Cloned voices (zero-shot) | 200-500ms | `pip install mlx-audio` + quantize |
| 2 | **edge-tts** | Preset/default voices | 300-800ms | `pip3 install edge-tts` |
| 3 | Text-only | Fallback when no audio | 0ms | — |

### Voice Cloning Setup (Qwen3-TTS)

```bash
pip install mlx-audio fastapi uvicorn
python3 -m mlx_audio.quantize --model "Qwen/Qwen3-TTS" --q-bits 4 \
  --out-path ~/.voicelayer/models/qwen3-tts-4bit
voicelayer daemon  # starts FastAPI on port 8880
```

### Voice Profile (profile.yaml)

Cloned voices store their config at `~/.voicelayer/voices/{name}/profile.yaml`:
```yaml
name: theo
engine: qwen3-tts
reference_clips:
  - path: ~/.voicelayer/voices/theo/samples/clip-003.wav
    text: "transcript of the reference audio"
reference_clip: ~/.voicelayer/voices/theo/samples/clip-003.wav
fallback: en-US-AndrewNeural
```

## STT Backends

Pluggable speech-to-text with auto-detection:

| Backend | Type | Speed (5s clip) | Setup |
|---------|------|-----------------|-------|
| **whisper.cpp** | Local (default, free) | ~200-400ms on M1 Pro | `brew install whisper-cpp` + download model |
| **Wispr Flow** | Cloud (fallback) | ~500ms + network | Set `QA_VOICE_WISPR_KEY` |

**Binary detection:** v1.8.3+ renamed binary from `whisper-cpp` to `whisper-cli`. VoiceLayer checks both names.

Auto-detection priority:
1. `QA_VOICE_STT_BACKEND=whisper` → force whisper.cpp
2. `QA_VOICE_STT_BACKEND=wispr` → force Wispr Flow
3. `QA_VOICE_STT_BACKEND=auto` (default) → whisper.cpp if available, else Wispr Flow

### whisper.cpp Setup

```bash
brew install whisper-cpp
mkdir -p ~/.cache/whisper
curl -L -o ~/.cache/whisper/ggml-large-v3-turbo.bin \
  https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin
```

Model search order: `QA_VOICE_WHISPER_MODEL` env var → `~/.cache/whisper/ggml-large-v3-turbo.bin` → any `ggml-*.bin` in `~/.cache/whisper/`.

## Voice Activity Detection (VAD)

Uses **Silero VAD** (neural network ONNX model, ~2.3MB) instead of energy/amplitude-based silence detection. Benefits:
- Detects actual speech vs. noise (typing, fans, etc.)
- Much more reliable silence detection
- Configurable silence modes:

| Mode | Duration | Use Case |
|------|----------|----------|
| **quick** | 0.5s | Fast responses, short answers |
| **standard** | 1.5s | Normal conversation |
| **thoughtful** | 2.5s | User pauses to think (default for converse) |

Model location: `models/silero_vad.onnx` (included in repo + npm package).

## Voice Modes

| Mode | Voice Out | User Response | Blocking | Use Case |
|------|-----------|---------------|----------|----------|
| **announce** | Yes | None | **No** (non-blocking) | Status updates, narration, "task complete" |
| **brief** | Yes | None | **No** (non-blocking) | One-way explanation, reading back decisions |
| **consult** | Yes | None (hint to follow up) | **No** (non-blocking) | Checkpoint: "about to commit, want to review?" |
| **converse** | Yes | Voice (Silero VAD stop) | Yes | Full interactive Q&A, drilling sessions |
| **think** | No | None | No | Silent markdown log |
| **replay** | Yes (cached) | None | **No** (non-blocking) | Replay last spoken message from ring buffer |
| **toggle** | — | — | No | Enable/disable TTS and/or mic |

### Non-Blocking TTS (Phase 2)

All TTS modes (announce, brief, consult) return **instantly** after synthesis. Audio plays in a detached background process. Stop with `pkill afplay` or skhd hotkey `ctrl+alt-s`.

### Ring Buffer Replay

Last 20 synthesized audio files are cached in `/tmp/voicelayer-history-{N}.mp3` with metadata in `/tmp/voicelayer-history.json`. Use `voice_speak(replay_index=N)` to replay (0 = most recent).

### User-Controlled Stop (converse mode)

- **Primary:** Touch `/tmp/voicelayer-stop` to end recording
- **Fallback:** Silero VAD silence detection (configurable: quick/standard/thoughtful)
- **Timeout:** 300s default, configurable per call
- **skhd hotkey:** `ctrl+alt-s` → kills afplay (stops TTS playback)

### Session Booking

Voice sessions use a lockfile (`/tmp/voicelayer-session.lock`) to prevent mic conflicts between multiple Claude sessions.

- `converse` mode auto-books on first call
- Other sessions see "line busy" and fall back to text
- Stale locks (dead PID) are auto-cleaned
- Lock released on: process exit, SIGTERM, SIGINT

## Two Use Modes

### QA Mode
Systematic website testing: browse with Playwright, speak questions about each page, record findings in structured checklist, generate markdown report.

- Schema: `src/schemas/checklist.ts`
- Categories: `src/schemas/qa-categories.ts` (6 categories, 31 checks)
- Report: `src/report.ts` → `~/.voicelayer/reports/qa-{date}-{id}.md`

### Discovery Mode
Client call assistant: track unknowns, whisper follow-up suggestions, detect red flags, generate project brief.

- Schema: `src/schemas/discovery.ts`
- Categories: `src/schemas/discovery-categories.ts` (7 categories, 23 questions)
- Brief: `src/brief.ts` → `~/.voicelayer/briefs/discovery-{date}-{id}.md`

## How It Works

Single terminal — no companion script needed.

1. Claude calls `voice_ask("question")` via MCP
2. Session booking checked/acquired (lockfile)
3. edge-tts speaks the question aloud via afplay (blocking for converse, non-blocking for others)
4. Audio saved to ring buffer (last 20 entries) for replay
5. Mic recording starts via `rec` (sox) — 16kHz 16-bit mono PCM to buffer
6. Silero VAD processes 32ms chunks, detects real speech vs noise
7. Stop when: user touches `/tmp/voicelayer-stop`, OR VAD-confirmed silence (configurable mode)
8. Recorded audio saved as WAV, sent to STT backend (whisper.cpp or Wispr Flow)
9. STT returns the transcription
10. Claude receives the text and continues

## Quick Start

### Prerequisites

```bash
brew install sox          # Provides `rec` command for mic recording
pip3 install edge-tts     # Python TTS engine
# For local STT (recommended):
brew install whisper-cpp
mkdir -p ~/.cache/whisper
curl -L -o ~/.cache/whisper/ggml-large-v3-turbo.bin \
  https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin
```

### For Voice Extraction (CLI only)

```bash
brew install yt-dlp ffmpeg                    # System dependencies
pip3 install silero-vad torch soundfile       # Required Python packages
# Optional: vocal separation + speaker diarization
pip3 install demucs pyannote.audio
```

### Setup

Add to `.mcp.json` (via npm/bunx — recommended):
```json
{
  "voicelayer": {
    "command": "bunx",
    "args": ["voicelayer-mcp"]
  }
}
```

Or from source:
```json
{
  "voicelayer": {
    "command": "bun",
    "args": ["run", "/path/to/voicelayer/src/mcp-server.ts"]
  }
}
```

For Wispr Flow cloud STT (only if whisper.cpp not installed), add env:
```json
{
  "voicelayer": {
    "command": "bunx",
    "args": ["voicelayer-mcp"],
    "env": {
      "QA_VOICE_WISPR_KEY": "your-api-key-here"
    }
  }
}
```

Grant microphone access to your terminal app (System Settings > Privacy > Microphone).

## MCP Tools

| Tool | What It Does | Returns |
|------|--------------|---------|
| `voice_speak` | NON-BLOCKING TTS — auto-selects announce/brief/consult/think from message | Confirmation |
| `voice_ask` | BLOCKING — speak question, record + transcribe response | Transcribed text |

Old `qa_voice_*` names still work as backward-compat aliases.

## CLI Tools

### Voice Extraction

Extract voice samples from YouTube for zero-shot voice cloning:

```bash
voicelayer extract --source "https://youtube.com/@t3dotgg" --name theo --count 20
```

Pipeline: yt-dlp (WAV 48kHz) → [optional Demucs vocal separation] → Silero VAD segmentation (6-30s clips) → FFmpeg normalization (24kHz mono s16) → `~/.voicelayer/voices/{name}/`

Key flags:
- `--source` — YouTube URL (video, channel, or playlist)
- `--name` — Speaker name (output directory + file prefix)
- `--count` — Max videos to download (default: 20)
- `--demucs` — Force vocal separation (for music-heavy audio)
- `--no-single-speaker` — Enable speaker diarization (multi-speaker)
- `--check-deps` — Verify dependencies and exit

Output: `~/.voicelayer/voices/{name}/samples/*.wav` + `metadata.json` + `profile.yaml`

### Voice Cloning

Create a voice profile from extracted samples (zero-shot, no training):

```bash
voicelayer clone --name theo --source "https://youtube.com/@t3dotgg"
```

Selects best 3 reference clips (~18.5s total), transcribes them via whisper.cpp, writes `profile.yaml`.

### TTS Daemon

Start the Qwen3-TTS voice cloning daemon:

```bash
voicelayer daemon --port 8880
```

## Scripts

| Script | Purpose |
|--------|---------|
| `scripts/speak.sh` | Standalone TTS command (Python edge-tts + afplay). Usage: `speak.sh "text" [rate]` |
| `scripts/test-wispr-ws.ts` | Standalone Wispr Flow WebSocket test |

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `QA_VOICE_STT_BACKEND` | `auto` | STT backend: `whisper` (local), `wispr` (cloud), `auto` (prefer local) |
| `QA_VOICE_WHISPER_MODEL` | (auto-detected) | Path to whisper.cpp GGML model file |
| `QA_VOICE_WISPR_KEY` | — | Wispr Flow API key (cloud fallback only) |
| `QA_VOICE_TTS_VOICE` | `en-US-JennyNeural` | edge-tts voice ID |
| `QA_VOICE_TTS_RATE` | `+0%` | Base speech rate (per-mode defaults: announce +10%, brief -10%, consult +5%, converse +0%). Auto-slows for long text. |
| `QA_VOICE_THINK_FILE` | `/tmp/voicelayer-thinking.md` | Live thinking log path |

## File Structure

```text
voicelayer/
├── src/
│   ├── mcp-server.ts          # MCP server (voice_speak + voice_ask + aliases)
│   ├── tts.ts                 # Three-tier TTS routing + ring buffer (20 entries)
│   ├── tts/
│   │   └── qwen3.ts           # Qwen3-TTS HTTP bridge (daemon client + profile.yaml loader)
│   ├── tts_daemon.py          # Python FastAPI daemon for Qwen3-TTS (port 8880)
│   ├── input.ts               # Mic recording + Silero VAD + STT transcription
│   ├── vad.ts                 # Silero VAD integration (onnxruntime-node)
│   ├── stt.ts                 # STT backend abstraction (whisper.cpp + Wispr Flow)
│   ├── audio-utils.ts         # Shared audio utilities (RMS calculation)
│   ├── socket-server.ts       # Unix domain socket server for Flow Bar IPC
│   ├── socket-protocol.ts     # Socket protocol types + serialization (NDJSON)
│   ├── paths.ts               # Centralized /tmp path constants
│   ├── session-booking.ts     # Lockfile-based voice session mutex
│   ├── session.ts             # Session lifecycle (save/load/generate)
│   ├── report.ts              # QA report renderer (JSON → markdown)
│   ├── brief.ts               # Discovery brief renderer (JSON → markdown)
│   ├── schemas/
│   │   ├── checklist.ts       # QA session schema + helpers
│   │   ├── qa-categories.ts   # 6 QA categories (31 checks)
│   │   ├── discovery.ts       # Discovery session schema + helpers
│   │   └── discovery-categories.ts  # 7 discovery categories (23 questions)
│   ├── cli/
│   │   ├── extract.py         # Voice extraction pipeline (yt-dlp → VAD → FFmpeg)
│   │   ├── clone.py           # Voice profile builder (reference clip selection + transcription)
│   │   └── voicelayer.sh      # CLI wrapper (routes subcommands: extract, clone, daemon)
│   └── __tests__/             # 166 tests, 367 expect() calls
├── flow-bar/                    # SwiftUI macOS floating pill app
│   ├── Package.swift            # SPM executable, macOS 14+
│   ├── Sources/FlowBar/
│   │   ├── FlowBarApp.swift     # @main, AppDelegate, MenuBarExtra
│   │   ├── FloatingPanel.swift  # NSPanel subclass (non-focus-stealing)
│   │   ├── BarView.swift        # Main pill view with vibrancy
│   │   ├── WaveformView.swift   # 7-bar 60fps waveform animation
│   │   ├── VoiceState.swift     # @Observable state model
│   │   ├── SocketClient.swift   # NWConnection Unix socket client
│   │   └── Theme.swift          # Colors, sizes, animation constants
│   └── mock_server.py           # Python test harness
├── models/
│   └── silero_vad.onnx        # Silero VAD v5 model (~2.3MB)
├── com.golems.tts-daemon.plist  # macOS launchd plist for TTS daemon
├── scripts/
│   ├── speak.sh               # Standalone TTS command
│   └── test-wispr-ws.ts       # Wispr Flow WebSocket test
├── package.json
├── tsconfig.json
├── LICENSE
├── CONTRIBUTING.md
├── CLAUDE.md                  # This file
└── README.md
```

## Output Paths

| Type | Path |
|------|------|
| Sessions (JSON) | `~/.voicelayer/sessions/{id}.json` |
| QA Reports (MD) | `~/.voicelayer/reports/{id}.md` |
| Discovery Briefs (MD) | `~/.voicelayer/briefs/{id}.md` |
| Thinking Log | `/tmp/voicelayer-thinking.md` |
| Session Lock | `/tmp/voicelayer-session.lock` |
| Stop Signal | `/tmp/voicelayer-stop` |
| Recording (temp) | `/tmp/voicelayer-recording-{pid}-{ts}.wav` |
| Ring Buffer History | `/tmp/voicelayer-history.json` |
| Ring Buffer Audio | `/tmp/voicelayer-history-{0-19}.mp3` |
| TTS Disabled Flag | `/tmp/.claude_tts_disabled` |
| Mic Disabled Flag | `/tmp/.claude_mic_disabled` |
| Voice Samples | `~/.voicelayer/voices/{name}/samples/*.wav` |
| Voice Metadata | `~/.voicelayer/voices/{name}/metadata.json` |
| Voice Profile | `~/.voicelayer/voices/{name}/profile.yaml` |
| yt-dlp Archive | `~/.voicelayer/voices/{name}/.archive` |
| Qwen3-TTS Model | `~/.voicelayer/models/qwen3-tts-4bit/` |
| Flow Bar Socket | `/tmp/voicelayer.sock` |
| TTS Daemon Logs | `/tmp/voicelayer-tts-daemon.{stdout,stderr}.log` |

## Dependencies

- `@modelcontextprotocol/sdk` — MCP server SDK
- `onnxruntime-node` — ONNX Runtime for Silero VAD inference
- `edge-tts` (Python) — Microsoft neural TTS (free, no API key)
- `mlx-audio` (Python, for cloning) — MLX-native TTS (Qwen3-TTS + Kokoro)
- `fastapi` + `uvicorn` (Python, for cloning) — TTS daemon HTTP server
- `sox` (system) — Audio recording via `rec` command
- `afplay` (macOS) / `mpv`/`ffplay`/`mpg123` (Linux) — Audio playback
- `whisper-cpp` (system, optional) — Local STT engine
- `yt-dlp` (system, for extract) — YouTube audio downloader
- `ffmpeg` (system, for extract) — Audio normalization
- `silero-vad` (Python, for extract) — Speech segmentation
- `torch` (Python, for extract) — Silero VAD dependency
- `soundfile` (Python, for extract) — Audio I/O
- `demucs` (Python, optional) — Vocal separation for music-heavy audio
- `pyannote.audio` (Python, optional) — Speaker diarization

## Naming Convention

**Primary tools:** `voice_speak` (output), `voice_ask` (input).

**Backward compat:** Old `qa_voice_*` names (announce, brief, consult, converse, think, say, ask, replay, toggle) still work as aliases.

**Environment variables:** `QA_VOICE_*` env vars (aliasing to `VOICELAYER_*` planned for v3).
