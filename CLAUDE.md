# VoiceLayer

> Voice I/O layer for AI coding assistants. MCP server with 4 voice modes + silent thinking + replay + toggle.

## Architecture

```text
Claude Code session
  ├── Playwright MCP (browser snapshots, --extension for co-browsing)
  ├── VoiceLayer MCP (this repo)
  │   ├── qa_voice_announce(message) → NON-BLOCKING fire-and-forget TTS
  │   ├── qa_voice_brief(message) → NON-BLOCKING one-way explanation TTS
  │   ├── qa_voice_consult(message) → NON-BLOCKING speak + hint user may respond
  │   ├── qa_voice_converse(message) → speak + record mic → Silero VAD → STT → transcription
  │   ├── qa_voice_think(thought) → writes to live thinking log (silent)
  │   ├── qa_voice_replay(index?) → replay from ring buffer (last 20 audio files)
  │   ├── qa_voice_toggle(enabled, scope?) → enable/disable TTS and/or mic
  │   ├── qa_voice_say(message) → ALIAS for announce
  │   └── qa_voice_ask(message) → ALIAS for converse
  └── Supabase MCP (data persistence)
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

Last 20 synthesized audio files are cached in `/tmp/voicelayer-history-{N}.mp3` with metadata in `/tmp/voicelayer-history.json`. Use `qa_voice_replay(index)` to replay (0 = most recent).

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

1. Claude calls `qa_voice_converse("question")` via MCP
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

| Tool | Mode | Returns |
|------|------|---------|
| `qa_voice_announce` | NON-BLOCKING fire-and-forget TTS | Confirmation |
| `qa_voice_brief` | NON-BLOCKING one-way explanation TTS | Confirmation |
| `qa_voice_consult` | NON-BLOCKING speak + follow-up hint | Confirmation + hint |
| `qa_voice_converse` | Speak + Silero VAD + wait for voice | Transcribed text |
| `qa_voice_think` | Silent log to file | Confirmation |
| `qa_voice_replay` | Replay from ring buffer | Confirmation + text |
| `qa_voice_toggle` | Enable/disable TTS and/or mic | Confirmation |
| `qa_voice_say` | ALIAS → announce | Confirmation |
| `qa_voice_ask` | ALIAS → converse | Transcribed text |

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
│   ├── mcp-server.ts          # MCP server (5 modes + replay + toggle + 2 aliases)
│   ├── tts.ts                 # Non-blocking TTS + ring buffer (20 entries)
│   ├── input.ts               # Mic recording + Silero VAD + STT transcription
│   ├── vad.ts                 # Silero VAD integration (onnxruntime-node)
│   ├── stt.ts                 # STT backend abstraction (whisper.cpp + Wispr Flow)
│   ├── audio-utils.ts         # Shared audio utilities (RMS calculation)
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
│   └── __tests__/             # 101 tests, 226 expect() calls
├── models/
│   └── silero_vad.onnx        # Silero VAD v5 model (~2.3MB)
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

## Dependencies

- `@modelcontextprotocol/sdk` — MCP server SDK
- `onnxruntime-node` — ONNX Runtime for Silero VAD inference
- `edge-tts` (Python) — Microsoft neural TTS (free, no API key)
- `sox` (system) — Audio recording via `rec` command
- `afplay` (macOS) / `mpv`/`ffplay`/`mpg123` (Linux) — Audio playback
- `whisper-cpp` (system, optional) — Local STT engine

## Naming Convention Decision

**Tool prefix:** `qa_voice_*` (kept for v2, rename to `voicelayer_*` planned for v3).

The MCP server name is `"voicelayer"` but all 9 tool names use the `qa_voice_*` prefix. This is intentional for v2:

- **Why not rename now:** The golems repo references `mcp__qa-voice__qa_voice_*` in 12+ agent/rule/skill files. Renaming tools requires updating the `.mcp.json` key from `qa-voice` to `voicelayer`, which changes the Claude Code tool namespace and breaks all existing references.
- **v3 migration plan:** Add `voicelayer_*` aliases alongside `qa_voice_*`, update all consumers, then switch defaults with a deprecation period.
- **Environment variables:** Similarly, `QA_VOICE_*` env vars will be aliased to `VOICELAYER_*` in v3.
