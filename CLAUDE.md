# VoiceLayer

> Voice I/O layer for AI coding assistants. MCP server with 4 voice modes + silent thinking.

## Architecture

```text
Claude Code session
  ├── Playwright MCP (browser snapshots, --extension for co-browsing)
  ├── VoiceLayer MCP (this repo)
  │   ├── qa_voice_announce(message) → fire-and-forget TTS
  │   ├── qa_voice_brief(message) → one-way explanation TTS
  │   ├── qa_voice_consult(message) → speak + hint user may respond
  │   ├── qa_voice_converse(message) → speak + record mic → local STT → transcription
  │   ├── qa_voice_think(thought) → writes to live thinking log (silent)
  │   ├── qa_voice_say(message) → ALIAS for announce
  │   └── qa_voice_ask(message) → ALIAS for converse
  └── Supabase MCP (data persistence)
```

## STT Backends

Pluggable speech-to-text with auto-detection:

| Backend | Type | Speed (5s clip) | Setup |
|---------|------|-----------------|-------|
| **whisper.cpp** | Local (default) | ~200-400ms on M1 Pro | `brew install whisper-cpp` + download model |
| **Wispr Flow** | Cloud (fallback) | ~500ms + network | Set `QA_VOICE_WISPR_KEY` |

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

## Voice Modes

| Mode | Voice Out | User Response | Blocking | Use Case |
|------|-----------|---------------|----------|----------|
| **announce** | Yes | None | No | Status updates, narration, "task complete" |
| **brief** | Yes | None | No | One-way explanation, reading back decisions |
| **consult** | Yes | None (hint to follow up) | No | Checkpoint: "about to commit, want to review?" |
| **converse** | Yes | Voice (user-controlled stop) | Yes | Full interactive Q&A, drilling sessions |
| **think** | No | None | No | Silent markdown log |

### User-Controlled Stop (converse mode)

- **Primary:** Touch `/tmp/voicelayer-stop` to end recording
- **Fallback:** 5s silence detection (longer than default — users pause to think)
- **Timeout:** 300s default, configurable per call

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
3. edge-tts speaks the question aloud via afplay
4. Mic recording starts via `rec` (sox) — 16kHz 16-bit mono PCM to buffer
5. Stop when: user touches `/tmp/voicelayer-stop`, OR 5s silence detected
6. Recorded audio saved as WAV, sent to STT backend (whisper.cpp or Wispr Flow)
7. STT returns the transcription
8. Claude receives the text and continues

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
| `qa_voice_announce` | Fire-and-forget TTS | Confirmation |
| `qa_voice_brief` | One-way explanation TTS | Confirmation |
| `qa_voice_consult` | Speak + follow-up hint | Confirmation + hint |
| `qa_voice_converse` | Speak + wait for voice | Transcribed text |
| `qa_voice_think` | Silent log to file | Confirmation |
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
| `QA_VOICE_SILENCE_SECONDS` | `2` | Default silence seconds (converse overrides to 5) |
| `QA_VOICE_SILENCE_THRESHOLD` | `500` | RMS energy threshold for silence (0-32767) |
| `QA_VOICE_THINK_FILE` | `/tmp/voicelayer-thinking.md` | Live thinking log path |

## File Structure

```text
voicelayer/
├── src/
│   ├── mcp-server.ts          # MCP server (5 modes + 2 aliases)
│   ├── tts.ts                 # edge-tts (Python CLI) + cross-platform audio player
│   ├── input.ts               # Mic recording + STT transcription pipeline
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
│   └── __tests__/             # 75 tests, 178 expect() calls
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

## Dependencies

- `@modelcontextprotocol/sdk` — MCP server SDK
- `edge-tts` (Python) — Microsoft neural TTS (free, no API key)
- `sox` (system) — Audio recording via `rec` command
- `afplay` (macOS) / `mpv`/`ffplay`/`mpg123` (Linux) — Audio playback
- `whisper-cpp` (system, optional) — Local STT engine
