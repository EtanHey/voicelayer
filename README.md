# VoiceLayer

> Voice I/O layer for AI coding assistants — local TTS, STT, session booking. MCP server.

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![MCP](https://img.shields.io/badge/MCP-compatible-blue.svg)](https://modelcontextprotocol.io)

VoiceLayer adds **voice input and output** to Claude Code sessions via the Model Context Protocol (MCP). Speak questions aloud, record voice responses, and transcribe locally with whisper.cpp — all inside your terminal.

## Features

- **5 voice modes** — announce, brief, consult, converse, think
- **Local-first STT** — whisper.cpp (200-400ms on Apple Silicon), Wispr Flow cloud fallback
- **Session booking** — lockfile prevents mic conflicts between parallel sessions
- **User-controlled stop** — touch a file to end recording (no awkward silence timers)
- **QA mode** — systematic website testing with structured checklists (31 checks across 6 categories)
- **Discovery mode** — client call assistant with red flag detection (22 questions across 7 categories)

## How It Works

```
Claude Code → MCP → VoiceLayer
                     ├── edge-tts speaks question via speakers
                     ├── sox records mic input (16kHz mono PCM)
                     ├── whisper.cpp transcribes locally (~300ms)
                     └── Returns transcription to Claude
```

1. Claude calls `qa_voice_converse("How does the nav look on mobile?")`
2. VoiceLayer speaks the question aloud via edge-tts + afplay
3. Mic recording starts — user speaks their response
4. Recording ends when user touches `/tmp/voicelayer-stop` or after 5s silence
5. Audio transcribed by whisper.cpp (local) or Wispr Flow (cloud fallback)
6. Claude receives the transcribed text and continues

## Prerequisites

```bash
brew install sox              # Mic recording (provides `rec` command)
pip3 install edge-tts         # Microsoft neural TTS (free, no API key)

# Local STT (recommended):
brew install whisper-cpp
mkdir -p ~/.cache/whisper
curl -L -o ~/.cache/whisper/ggml-large-v3-turbo.bin \
  https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin
```

Grant microphone access to your terminal app (System Settings > Privacy > Microphone).

## Setup

Clone the repo:

```bash
git clone https://github.com/EtanHey/voicelayer.git ~/Gits/voicelayer
cd ~/Gits/voicelayer
bun install
```

Add to your project's `.mcp.json`:

```json
{
  "mcpServers": {
    "qa-voice": {
      "command": "bun",
      "args": ["run", "/path/to/voicelayer/src/mcp-server.ts"],
      "env": {
        "QA_VOICE_WISPR_KEY": "your-key-here"
      }
    }
  }
}
```

> `QA_VOICE_WISPR_KEY` is only needed if whisper.cpp is not installed (cloud fallback).

## Voice Modes

| Mode | Tool | What It Does |
|------|------|-------------|
| **announce** | `qa_voice_announce` | Fire-and-forget TTS (status updates, narration) |
| **brief** | `qa_voice_brief` | One-way explanation (reading back decisions) |
| **consult** | `qa_voice_consult` | Speak + hint user may respond |
| **converse** | `qa_voice_converse` | Full Q&A — speak + record + transcribe |
| **think** | `qa_voice_think` | Silent notes to markdown log |

**Aliases:** `qa_voice_say` → announce, `qa_voice_ask` → converse

## STT Backends

| Backend | Type | Speed | Setup |
|---------|------|-------|-------|
| **whisper.cpp** | Local (default) | ~200-400ms | `brew install whisper-cpp` + model download |
| **Wispr Flow** | Cloud (fallback) | ~500ms + network | `QA_VOICE_WISPR_KEY` env var |

Auto-detection: whisper.cpp if available, else Wispr Flow. Override with `QA_VOICE_STT_BACKEND=whisper|wispr|auto`.

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `QA_VOICE_STT_BACKEND` | `auto` | STT backend: `whisper`, `wispr`, or `auto` |
| `QA_VOICE_WHISPER_MODEL` | auto-detected | Path to whisper.cpp GGML model file |
| `QA_VOICE_WISPR_KEY` | — | Wispr Flow API key (cloud fallback only) |
| `QA_VOICE_TTS_VOICE` | `en-US-JennyNeural` | edge-tts voice ID |
| `QA_VOICE_TTS_RATE` | `+0%` | Base speech rate (per-mode rates applied on top) |
| `QA_VOICE_SILENCE_SECONDS` | `2` | Silence seconds before end (converse uses 5) |
| `QA_VOICE_SILENCE_THRESHOLD` | `500` | RMS energy threshold (0-32767) |
| `QA_VOICE_THINK_FILE` | `/tmp/voicelayer-thinking.md` | Live thinking log path |

## Testing

```bash
bun test    # 75 tests, 178 assertions
```

## Project Structure

```
voicelayer/
├── src/
│   ├── mcp-server.ts          # MCP server entry point
│   ├── tts.ts                 # edge-tts + afplay
│   ├── input.ts               # Mic recording + STT pipeline
│   ├── stt.ts                 # STT backend abstraction
│   ├── session-booking.ts     # Lockfile-based session mutex
│   ├── session.ts             # Session lifecycle
│   ├── report.ts              # QA report renderer
│   ├── brief.ts               # Discovery brief renderer
│   ├── schemas/               # QA + discovery schemas
│   └── __tests__/             # Tests
├── scripts/
│   ├── speak.sh               # Standalone TTS command
│   └── test-wispr-ws.ts       # Wispr Flow WebSocket test
├── package.json
├── tsconfig.json
├── CLAUDE.md
└── README.md
```

## License

MIT
