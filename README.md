# VoiceLayer

> Voice I/O layer for AI coding assistants — local TTS, STT, session booking. MCP server.

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![MCP](https://img.shields.io/badge/MCP-compatible-blue.svg)](https://modelcontextprotocol.io)
[![Tests](https://img.shields.io/badge/tests-75%20passing-brightgreen.svg)](#testing)
[![Docs](https://img.shields.io/badge/docs-GitHub%20Pages-blue.svg)](https://etanhey.github.io/voicelayer/)

VoiceLayer adds **voice input and output** to Claude Code sessions via the Model Context Protocol (MCP). Speak questions aloud, record voice responses, and transcribe locally with whisper.cpp — all inside your terminal.

## Quick Start

```bash
# 1. Install prerequisites
brew install sox                    # Mic recording
pip3 install edge-tts               # Microsoft neural TTS (free)
brew install whisper-cpp            # Local STT (recommended)

# 2. Download a whisper model
mkdir -p ~/.cache/whisper
curl -L -o ~/.cache/whisper/ggml-large-v3-turbo.bin \
  https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin

# 3. Clone and install
git clone https://github.com/EtanHey/voicelayer.git
cd voicelayer && bun install

# 4. Add to your .mcp.json
```

```json
{
  "mcpServers": {
    "qa-voice": {
      "command": "bun",
      "args": ["run", "/path/to/voicelayer/src/mcp-server.ts"]
    }
  }
}
```

Grant microphone access to your terminal (macOS: System Settings > Privacy > Microphone).

## How It Works

```
Claude Code  ─── MCP ───>  VoiceLayer
                            ├── edge-tts speaks question (speakers)
                            ├── sox records mic (16kHz mono PCM)
                            ├── whisper.cpp transcribes locally (~300ms)
                            └── Returns transcription to Claude
```

1. Claude calls `qa_voice_converse("How does the nav look on mobile?")`
2. VoiceLayer speaks the question aloud via edge-tts
3. Mic recording starts — user speaks their response
4. Recording ends when user touches `/tmp/voicelayer-stop` or after 5s silence
5. Audio transcribed by whisper.cpp (local) or Wispr Flow (cloud fallback)
6. Claude receives the transcribed text and continues

## Voice Modes

| Mode | Tool | What It Does | Blocking |
|------|------|-------------|----------|
| **announce** | `qa_voice_announce` | Fire-and-forget TTS (status updates, narration) | No |
| **brief** | `qa_voice_brief` | One-way explanation (reading back decisions) | No |
| **consult** | `qa_voice_consult` | Speak + hint user may respond | No |
| **converse** | `qa_voice_converse` | Full Q&A — speak + record + transcribe | Yes |
| **think** | `qa_voice_think` | Silent notes to markdown log | No |

**Aliases:** `qa_voice_say` -> announce, `qa_voice_ask` -> converse

### User-Controlled Stop

- **Primary:** `touch /tmp/voicelayer-stop` to end recording or playback
- **Fallback:** 5s silence detection (converse mode)
- **Timeout:** 300s default, configurable per call (10-3600)

### Session Booking

Converse mode uses a lockfile (`/tmp/voicelayer-session.lock`) to prevent mic conflicts:
- Auto-books on first `converse` call
- Other sessions see "line busy" (returns `isError: true`)
- Stale locks (dead PID) are auto-cleaned

## STT Backends

| Backend | Type | Speed | Setup |
|---------|------|-------|-------|
| **whisper.cpp** | Local (default) | ~200-400ms on Apple Silicon | `brew install whisper-cpp` + model |
| **Wispr Flow** | Cloud (fallback) | ~500ms + network | `QA_VOICE_WISPR_KEY` env var |

Auto-detection: whisper.cpp if available, else Wispr Flow. Override with `QA_VOICE_STT_BACKEND=whisper|wispr|auto`.

## Use Modes

### QA Mode
Systematic website testing with Playwright: browse pages, speak questions, record findings in structured checklists, generate markdown reports.
- 6 categories, 31 checks
- Reports saved to `~/.voicelayer/reports/`

### Discovery Mode
Client call assistant: track unknowns, suggest follow-up questions, detect red flags, generate project briefs.
- 7 categories, 23 questions
- Briefs saved to `~/.voicelayer/briefs/`

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `QA_VOICE_STT_BACKEND` | `auto` | STT backend: `whisper`, `wispr`, or `auto` |
| `QA_VOICE_WHISPER_MODEL` | auto-detected | Path to whisper.cpp GGML model file |
| `QA_VOICE_WISPR_KEY` | — | Wispr Flow API key (cloud fallback only) |
| `QA_VOICE_TTS_VOICE` | `en-US-JennyNeural` | edge-tts voice ID |
| `QA_VOICE_TTS_RATE` | `+0%` | Base speech rate (per-mode defaults applied on top) |
| `QA_VOICE_SILENCE_SECONDS` | `2` | Silence seconds before end (converse uses 5) |
| `QA_VOICE_SILENCE_THRESHOLD` | `500` | RMS energy threshold (0-32767) |
| `QA_VOICE_THINK_FILE` | `/tmp/voicelayer-thinking.md` | Live thinking log path |

## Platform Support

| Platform | TTS | Audio Player | STT | Recording |
|----------|-----|-------------|-----|-----------|
| **macOS** | edge-tts | afplay (built-in) | whisper.cpp | sox/rec |
| **Linux** | edge-tts | mpv, ffplay, or mpg123 | whisper.cpp | sox/rec |

## Testing

```bash
bun test    # 75 tests, 178 assertions
```

## Project Structure

```
voicelayer/
├── src/
│   ├── mcp-server.ts          # MCP server (5 modes + 2 aliases)
│   ├── tts.ts                 # edge-tts + cross-platform audio player
│   ├── input.ts               # Mic recording + STT pipeline
│   ├── stt.ts                 # STT backend abstraction (whisper.cpp + Wispr Flow)
│   ├── audio-utils.ts         # Shared audio utilities (RMS calculation)
│   ├── paths.ts               # Centralized /tmp path constants
│   ├── session-booking.ts     # Lockfile-based session mutex
│   ├── session.ts             # Session lifecycle (save/load/generate)
│   ├── report.ts              # QA report renderer (JSON → markdown)
│   ├── brief.ts               # Discovery brief renderer (JSON → markdown)
│   ├── schemas/               # QA + discovery schemas
│   └── __tests__/             # 75 tests
├── scripts/
│   ├── speak.sh               # Standalone TTS command
│   └── test-wispr-ws.ts       # Wispr Flow WebSocket test
├── package.json
├── tsconfig.json
├── LICENSE
├── CLAUDE.md
└── README.md
```

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for development setup, testing, and PR process.

## License

[MIT](LICENSE)
