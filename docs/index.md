# VoiceLayer

> Voice I/O layer for AI coding assistants — local TTS, STT, session booking.

VoiceLayer adds **voice input and output** to [Claude Code](https://docs.anthropic.com/en/docs/claude-code) sessions via the [Model Context Protocol (MCP)](https://modelcontextprotocol.io). Speak questions aloud, record voice responses, and transcribe locally with whisper.cpp — all inside your terminal.

## Why VoiceLayer?

AI coding assistants are text-only. But some tasks are faster with voice:

- **QA testing** — browse a page, speak what you see, let the agent take notes
- **Discovery calls** — hands-free client interviews with automatic briefs
- **Code review** — explain your reasoning while the agent captures it
- **Drilling sessions** — interactive Q&A with voice responses

VoiceLayer bridges the gap between your terminal and your microphone.

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

## 5 Voice Modes

| Mode | Tool | What It Does | Blocking |
|------|------|-------------|----------|
| **[Announce](modes/announce.md)** | `qa_voice_announce` | Fire-and-forget TTS (status updates) | No |
| **[Brief](modes/brief.md)** | `qa_voice_brief` | One-way explanation (reading back decisions) | No |
| **[Consult](modes/consult.md)** | `qa_voice_consult` | Speak checkpoint, user may respond | No |
| **[Converse](modes/converse.md)** | `qa_voice_converse` | Full voice Q&A — speak + record + transcribe | Yes |
| **[Think](modes/think.md)** | `qa_voice_think` | Silent notes to markdown log | No |

## Key Features

- **100% local STT** — whisper.cpp on Apple Silicon, no cloud dependency
- **Session booking** — lockfile mutex prevents mic conflicts between sessions
- **User-controlled stop** — `touch /tmp/voicelayer-stop` ends recording or playback
- **Per-mode speech rates** — announce is snappy (+10%), brief is slow (-10%)
- **Auto-slowdown** — long text automatically gets slower speech rate
- **Cross-platform** — macOS and Linux support

## Quick Start

```bash
brew install sox whisper-cpp
pip3 install edge-tts
```

Then add to your `.mcp.json`:

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

See the full [Quick Start guide](getting-started/quickstart.md) for details.

## Platform Support

| Platform | TTS | Audio Player | STT | Recording |
|----------|-----|-------------|-----|-----------|
| **macOS** | edge-tts | afplay (built-in) | whisper.cpp | sox/rec |
| **Linux** | edge-tts | mpv, ffplay, or mpg123 | whisper.cpp | sox/rec |
