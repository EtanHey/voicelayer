# Prerequisites

Everything VoiceLayer needs, with one-liner installs for each platform.

## Required

### Bun (JavaScript runtime)

VoiceLayer runs on [Bun](https://bun.sh). Install it with:

```bash
curl -fsSL https://bun.sh/install | bash
```

Verify: `bun --version` should print `1.x.x` or higher.

### sox (microphone recording)

sox provides the `rec` command used to capture audio from your microphone.

=== "macOS"

    ```bash
    brew install sox
    ```

=== "Ubuntu/Debian"

    ```bash
    sudo apt install sox
    ```

=== "Fedora/RHEL"

    ```bash
    sudo dnf install sox
    ```

Verify: `rec --version` should print version info.

### edge-tts (text-to-speech)

Microsoft's neural TTS engine. Free, no API key needed.

```bash
pip3 install edge-tts
```

Verify: `python3 -m edge_tts --list-voices` should print a list of voices.

!!! note "Python 3 required"
    edge-tts is a Python package. Most systems have Python 3 pre-installed. If not: `brew install python3` (macOS) or `sudo apt install python3-pip` (Linux).

### Claude Code

VoiceLayer is an MCP server for Claude Code. Install Claude Code from [Anthropic's docs](https://docs.anthropic.com/en/docs/claude-code).

## Recommended

### whisper.cpp (local speech-to-text)

Local transcription — fast on Apple Silicon (~300ms for a 5-second clip), no cloud dependency.

=== "macOS"

    ```bash
    brew install whisper-cpp
    ```

=== "Linux"

    Build from source — see the [whisper.cpp repo](https://github.com/ggerganov/whisper.cpp).

Then download a model:

```bash
mkdir -p ~/.cache/whisper
curl -L -o ~/.cache/whisper/ggml-large-v3-turbo.bin \
  https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin
```

!!! tip "Smaller models available"
    The large-v3-turbo model (~1.5 GB) gives the best accuracy. For faster downloads, use `ggml-base.en.bin` (~142 MB) — English only, slightly less accurate.

VoiceLayer auto-detects models in `~/.cache/whisper/`. No config needed.

### Audio player (Linux only)

macOS uses the built-in `afplay`. Linux needs one of these for MP3 playback:

```bash
sudo apt install mpv    # recommended
# or: sudo apt install mpg123
# or: sudo apt install ffmpeg  (provides ffplay)
```

## Optional

### Wispr Flow (cloud STT fallback)

If you don't install whisper.cpp, VoiceLayer can use [Wispr Flow](https://wisprflow.com) as a cloud-based speech-to-text backend. Requires an API key:

```bash
export QA_VOICE_WISPR_KEY="your-api-key"
```

This is optional — whisper.cpp is preferred for speed and privacy.

## Microphone Access (macOS)

On macOS, your terminal app needs microphone permission:

**System Settings > Privacy & Security > Microphone** — enable your terminal (iTerm2, Terminal.app, Warp, etc.)

!!! warning "First recording may prompt"
    The first time VoiceLayer tries to record, macOS will show a permission dialog. Grant it, then try again.

## Quick Check

Run these to verify everything is ready:

```bash
bun --version          # Should print 1.x.x+
rec --version          # Should print sox version info
python3 -m edge_tts -h # Should print help text
whisper-cpp --help     # Should print help (optional)
```

If all commands work, head to the [Quick Start](quickstart.md) to connect VoiceLayer to Claude Code.
