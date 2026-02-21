# Quick Start

Get VoiceLayer running with Claude Code in 5 minutes.

## 1. Install Prerequisites

=== "macOS (one block)"

    ```bash
    brew install sox whisper-cpp
    pip3 install edge-tts
    curl -fsSL https://bun.sh/install | bash
    ```

=== "Linux (one block)"

    ```bash
    sudo apt install sox mpv
    pip3 install edge-tts
    curl -fsSL https://bun.sh/install | bash
    ```

Need details? See the full [Prerequisites](prerequisites.md) page.

## 2. Download a Whisper Model

whisper.cpp needs a model file for local speech-to-text:

```bash
mkdir -p ~/.cache/whisper
curl -L -o ~/.cache/whisper/ggml-large-v3-turbo.bin \
  https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin
```

!!! tip "This is a ~1.5 GB download"
    For a smaller model (~142 MB, English only): replace `ggml-large-v3-turbo.bin` with `ggml-base.en.bin`.

## 3. Add to Claude Code

Add VoiceLayer to your MCP config. Open (or create) `.mcp.json` in your project root or `~/.claude/.mcp.json` for global access:

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

That's it. The next time you start Claude Code, VoiceLayer will be available.

??? info "Alternative: install from source"
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

    The `args` path must be absolute — MCP servers don't inherit your shell's working directory.

## 4. Grant Microphone Access (macOS)

On macOS, your terminal app needs mic permission:

**System Settings > Privacy & Security > Microphone** — enable your terminal (iTerm2, Terminal.app, Warp, etc.)

## 5. Test It

Start a Claude Code session and try:

```
Claude, announce "VoiceLayer is working"
```

You should hear the message spoken aloud. For full voice conversation:

```
Claude, use converse mode to ask me how the UI looks
```

Claude will speak the question, record your voice response, and continue the conversation.

## What's Next?

- **[What is VoiceLayer?](../what-is-voicelayer.md)** — non-technical overview with examples
- **[Voice Modes](../modes/overview.md)** — when to use announce vs. brief vs. converse
- **[Configuration](configuration.md)** — change the voice, speech rate, STT backend
- **[MCP Tools Reference](../tools-reference.md)** — full tool API with parameters
