# VoiceLayer

> Your AI agent can't hear you and respond to you. VoiceLayer gives it ears and a voice.

[![npm](https://img.shields.io/npm/v/voicelayer-mcp.svg)](https://www.npmjs.com/package/voicelayer-mcp)
[![License: Apache-2.0](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](https://www.apache.org/licenses/LICENSE-2.0)
[![MCP](https://img.shields.io/badge/MCP-compatible-blue.svg)](https://modelcontextprotocol.io)
[![Tools](https://img.shields.io/badge/MCP%20tools-2-38BDF8.svg)](#the-two-tools)

**Voice I/O for AI coding assistants.** Press F5, speak to Claude Code, get on-device
transcription in under 1.5 seconds. Your AI speaks back. Works with any MCP client.

```
  You ──🎤──> whisper.cpp ──> Claude Code ──> edge-tts ──🔊──> You
         STT (local)           MCP tools         TTS (free)
```

**Local-first. Free. Open-source.** No cloud APIs, no API keys, no data leaves your machine.

**[Website](https://voicelayer.etanheyman.com)** · **[Docs](https://etanhey.github.io/voicelayer/docs/)** · **[npm](https://www.npmjs.com/package/voicelayer-mcp)**

## Install

**macOS (recommended)** — the tap ships the CLI/MCP package and the notarized notch app:

```bash
brew tap etanhey/layers
brew install etanhey/layers/voicelayer         # CLI + MCP server
brew install --cask etanhey/layers/voicebar    # VoiceBar notch app (owns the mic)
voicelayer setup                               # one-time runtime setup
```

Install the cask too — the formula alone gives you the CLI/MCP but no notch UI.

**npm** — if you only want the MCP server:

```bash
bun add -g voicelayer-mcp        # or: npm i -g voicelayer-mcp
brew install sox socat && pip3 install edge-tts
brew install whisper-cpp         # optional, for local STT

# whisper model (~1.5 GB) — needed for local STT
mkdir -p ~/.cache/whisper && curl -L -o ~/.cache/whisper/ggml-large-v3-turbo.bin \
  https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin
```

### Point your MCP client at the daemon

VoiceLayer runs as one persistent daemon on a Unix socket; every session connects through a
lightweight `socat` shim instead of spawning its own process. Add to `.mcp.json`:

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

Or migrate every repo at once: `bash scripts/migrate-to-daemon.sh` (`--dry-run` to preview).
On macOS, grant your terminal microphone access (System Settings → Privacy → Microphone).

Updates, kill-switches, and cross-machine setup:
**[docs/install-and-update.md](docs/install-and-update.md)**.

## The two tools

| Tool | Behavior | Blocking |
|------|----------|:--------:|
| **`voice_speak`** | TTS with auto-mode (announce/brief/consult/think), replay, toggle | No |
| **`voice_ask`** | Speak a question, record the mic, transcribe the answer | Yes |

Both ship full MCP [ToolAnnotations](https://spec.modelcontextprotocol.io/specification/2025-03-26/server/tools/#annotations).
Neither is destructive; both set `openWorldHint: false`.

**How `voice_ask` works:** waits for any playing audio to finish → speaks the question via
edge-tts → records the mic and resamples to 16kHz → Silero VAD detects when you stop talking →
whisper.cpp transcribes locally (~200-400ms on Apple Silicon) → returns the text to your agent.

Full tool parameters: **[docs/tools-reference.md](docs/tools-reference.md)**.

## VoiceBar — the notch surface (macOS)

The canonical UI (SwiftUI + AppKit). It tucks around the MacBook camera housing instead of
floating over your work:

- **Liquid-Glass wings** flank the camera housing, with a graceful fallback on older macOS.
- **Teleprompter** with word-by-word karaoke highlighting as your agent speaks.
- **Idle-hover to summon** — collapsed it draws no pixels; hovering reveals recent transcripts,
  the dictionary, and replay.
- **Morph animations** between idle ↔ recording ↔ speaking, Reduce-Motion aware.

## STT backends

| Backend | Type | Latency | Setup |
|---------|------|---------|-------|
| **whisper.cpp** | Local (default) | ~200-400ms | `brew install whisper-cpp` + model |
| **Wispr Flow** | Cloud (fallback) | ~500ms + network | Set `QA_VOICE_WISPR_KEY` |

Auto-detected. Override with `QA_VOICE_STT_BACKEND=whisper|wispr|auto`.

## Platform support

| Platform | TTS | STT | Recording | VoiceBar |
|----------|-----|-----|-----------|----------|
| **macOS** | edge-tts + afplay | whisper.cpp (CoreML) | sox | SwiftUI app |
| **Linux** | edge-tts + mpv/ffplay | whisper.cpp | sox | — |

## Part of Golems

| Server | What it does | Tools |
|--------|-------------|:-----:|
| **[BrainLayer](https://brainlayer.etanheyman.com)** | Persistent memory — knowledge graph + hybrid search | 12 |
| **[VoiceLayer](https://voicelayer.etanheyman.com)** | Voice I/O — local STT, neural TTS, notch VoiceBar, F5 recording | 2 |
| **[cmuxLayer](https://cmuxlayer.etanheyman.com)** | Terminal orchestration — spawn panes, read screens, coordinate agents | 22 |

Pair with BrainLayer to remember voice conversations across sessions.

## More

- **[Architecture](docs/architecture.md)** — why one daemon instead of a process per session
- **[Configuration](docs/configuration.md)** — environment variables and test commands
- **[Contributing](docs/contributing.md)**

## License

[Apache-2.0](LICENSE)
