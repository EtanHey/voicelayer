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
| **voice_speak** | Non-blocking TTS — auto-selects announce/brief/consult/think from message | No |
| **voice_ask** | Blocking voice Q&A — speak question, record + transcribe response | Yes |

Mode-specific guidance: [Announce](modes/announce.md), [Brief](modes/brief.md), [Consult](modes/consult.md), [Converse](modes/converse.md), [Think](modes/think.md). Old `qa_voice_*` names still work as backward-compat aliases.

## Key Features

- **100% local STT** — whisper.cpp on Apple Silicon, no cloud dependency
- **Session booking** — lockfile mutex prevents mic conflicts between sessions
- **User-controlled stop** — `touch /tmp/voicelayer-stop`, or Silero VAD silence detection (quick 0.5s, standard 1.5s, thoughtful 2.5s)
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

See the full [Quick Start guide](getting-started/quickstart.md) for details, or read [What is VoiceLayer?](what-is-voicelayer.md) for a non-technical overview.

## Platform Support

| Platform | TTS | Audio Player | STT | Recording |
|----------|-----|-------------|-----|-----------|
| **macOS** | edge-tts | afplay (built-in) | whisper.cpp | sox/rec |
| **Linux** | edge-tts | mpv, ffplay, or mpg123 | whisper.cpp | sox/rec |
