# Quick Start

Get VoiceLayer running with Claude Code in under 5 minutes.

## Prerequisites

### macOS

```bash
# Recording (required)
brew install sox

# Text-to-speech (required)
pip3 install edge-tts

# Speech-to-text (recommended — local, fast)
brew install whisper-cpp
```

### Linux

```bash
# Recording
sudo apt install sox  # or: dnf install sox

# Text-to-speech
pip3 install edge-tts

# Audio playback (one of these)
sudo apt install mpv  # or: mpg123, ffplay

# Speech-to-text — build from source
# See https://github.com/ggerganov/whisper.cpp
```

## Download a Whisper Model

whisper.cpp needs a GGML model file for local transcription:

```bash
mkdir -p ~/.cache/whisper

# Large v3 Turbo (recommended — fast + accurate on Apple Silicon)
curl -L -o ~/.cache/whisper/ggml-large-v3-turbo.bin \
  https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin

# Or use a smaller model for faster startup:
# curl -L -o ~/.cache/whisper/ggml-base.en.bin \
#   https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.en.bin
```

VoiceLayer auto-detects models in `~/.cache/whisper/` — no config needed.

## Install VoiceLayer

```bash
git clone https://github.com/EtanHey/voicelayer.git
cd voicelayer
bun install
```

## Configure Claude Code

Add VoiceLayer to your `.mcp.json` (project-level or global `~/.claude/.mcp.json`):

```json
{
  "mcpServers": {
    "qa-voice": {
      "command": "bun",
      "args": ["run", "/absolute/path/to/voicelayer/src/mcp-server.ts"]
    }
  }
}
```

!!! warning "Use absolute paths"
    The `args` path must be absolute — MCP servers don't inherit your shell's working directory.

## Grant Microphone Access

On macOS, grant mic access to your terminal app:

**System Settings > Privacy & Security > Microphone** — enable your terminal (iTerm2, Terminal.app, Warp, etc.)

## Verify It Works

Start a Claude Code session and try:

```
Claude, announce "VoiceLayer is working"
```

You should hear the message spoken aloud through your speakers.

For full voice Q&A:

```
Claude, use converse mode to ask me about the UI
```

## Next Steps

- [Configuration](configuration.md) — environment variables, voice selection, rate tuning
- [Voice Modes](../modes/overview.md) — understand the 5 modes
- [MCP Tools Reference](../tools-reference.md) — full tool API
