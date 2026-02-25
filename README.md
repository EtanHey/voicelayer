# VoiceLayer

> Voice I/O layer for AI coding assistants — local TTS, STT, session booking. MCP server.

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![MCP](https://img.shields.io/badge/MCP-compatible-blue.svg)](https://modelcontextprotocol.io)
[![Tests](https://img.shields.io/badge/tests-168%20passing-brightgreen.svg)](#testing)
[![Docs](https://img.shields.io/badge/docs-GitHub%20Pages-blue.svg)](https://etanhey.github.io/voicelayer/)

VoiceLayer adds **voice input and output** to Claude Code sessions via the Model Context Protocol (MCP). Speak questions aloud, record voice responses, and transcribe locally with whisper.cpp — all inside your terminal.

**Local-first, free, open-source.** All processing happens on your machine — no cloud APIs required. TTS via edge-tts (free), STT via whisper.cpp (local). Optional cloud fallback via Wispr Flow for machines without whisper.cpp.

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

# 3. Add to your Claude Code .mcp.json
```

```json
{
  "mcpServers": {
    "voicelayer": {
      "command": "bunx",
      "args": ["voicelayer-mcp"]
    }
  }
}
```

> **Requires [Bun](https://bun.sh).** Install with: `curl -fsSL https://bun.sh/install | bash`

<details>
<summary>Alternative: install from source</summary>

```bash
git clone https://github.com/EtanHey/voicelayer.git
cd voicelayer && bun install
```

Then use this MCP config instead:

```json
{
  "mcpServers": {
    "voicelayer": {
      "command": "bun",
      "args": ["run", "/absolute/path/to/voicelayer/src/mcp-server.ts"]
    }
  }
}
```

</details>

Grant microphone access to your terminal (macOS: System Settings > Privacy > Microphone).

## How It Works

```
Claude Code  ─── MCP ───>  VoiceLayer
                            ├── Waits for any playing voice_speak audio
                            ├── edge-tts speaks question (speakers)
                            ├── sox records mic (native rate → resample to 16kHz)
                            ├── Silero VAD detects speech/silence
                            ├── whisper.cpp transcribes locally (~300ms)
                            └── Returns transcription to Claude
```

1. Claude calls `voice_ask("How does the nav look on mobile?")`
2. VoiceLayer waits for any prior `voice_speak` audio to finish (no overlap)
3. Speaks the question aloud via edge-tts
4. Mic recording starts at device's native sample rate (auto-detected)
5. Audio resampled to 16kHz in real-time, fed to Silero VAD for speech detection
6. Recording ends on user stop signal, VAD silence detection, or timeout
7. Audio transcribed by whisper.cpp (local) or Wispr Flow (cloud fallback)
8. Claude receives the transcribed text and continues

## Voice Tools

| Tool | What It Does | Blocking |
|------|-------------|----------|
| **voice_speak** | Non-blocking TTS — auto-selects announce/brief/consult/think from message content | No |
| **voice_ask** | Blocking voice Q&A — auto-waits for playing audio, speaks question, records + transcribes response | Yes |

Old `qa_voice_*` names still work as backward-compat aliases.

### User-Controlled Stop

- **Primary:** `touch /tmp/voicelayer-stop` to end recording or playback
- **Fallback:** Silero VAD silence detection (configurable: quick 0.5s, standard 1.5s, thoughtful 2.5s)
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
| `QA_VOICE_THINK_FILE` | `/tmp/voicelayer-thinking.md` | Live thinking log path |

## Platform Support

| Platform | TTS | Audio Player | STT | Recording |
|----------|-----|-------------|-----|-----------|
| **macOS** | edge-tts | afplay (built-in) | whisper.cpp | sox/rec |
| **Linux** | edge-tts | mpv, ffplay, or mpg123 | whisper.cpp | sox/rec |

## Testing

```bash
bun test    # 168 tests, 371 assertions
```

## Project Structure

```
voicelayer/
├── src/
│   ├── mcp-server.ts          # MCP server (voice_speak + voice_ask + aliases)
│   ├── tts.ts                 # edge-tts + cross-platform audio player
│   ├── input.ts               # Mic recording + STT pipeline
│   ├── stt.ts                 # STT backend abstraction (whisper.cpp + Wispr Flow)
│   ├── audio-utils.ts         # Audio utilities (RMS, native rate detection, resampling)
│   ├── paths.ts               # Centralized /tmp path constants
│   ├── session-booking.ts     # Lockfile-based session mutex
│   ├── session.ts             # Session lifecycle (save/load/generate)
│   ├── report.ts              # QA report renderer (JSON → markdown)
│   ├── brief.ts               # Discovery brief renderer (JSON → markdown)
│   ├── schemas/               # QA + discovery schemas
│   └── __tests__/             # 168 tests
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
