# Configuration

VoiceLayer is configured entirely via environment variables. All settings have sensible defaults — zero config required for basic usage.

## Environment Variables

### STT (Speech-to-Text)

| Variable | Default | Description |
|----------|---------|-------------|
| `QA_VOICE_STT_BACKEND` | `auto` | Backend selection: `whisper`, `wispr`, or `auto` |
| `QA_VOICE_WHISPER_MODEL` | auto-detected | Absolute path to a whisper.cpp GGML model file |
| `QA_VOICE_WISPR_KEY` | — | Wispr Flow API key (cloud fallback only) |

**Auto-detection** (`auto` mode) checks for whisper.cpp first, falls back to Wispr Flow if `QA_VOICE_WISPR_KEY` is set.

**Model auto-detection** scans `~/.cache/whisper/` for GGML files in this order:

1. `ggml-large-v3-turbo.bin`
2. `ggml-large-v3-turbo-q5_0.bin`
3. `ggml-base.en.bin`
4. `ggml-base.bin`
5. `ggml-small.en.bin`
6. `ggml-small.bin`
7. Any other `ggml-*.bin` file

### TTS (Text-to-Speech)

| Variable | Default | Description |
|----------|---------|-------------|
| `QA_VOICE_TTS_VOICE` | `en-US-JennyNeural` | Microsoft edge-tts voice ID |
| `QA_VOICE_TTS_RATE` | `+0%` | Base speech rate (per-mode defaults layer on top) |

**Available voices** — run `edge-tts --list-voices` for the full list. Popular choices:

| Voice | Language | Style |
|-------|----------|-------|
| `en-US-JennyNeural` | English (US) | Default, clear female |
| `en-US-GuyNeural` | English (US) | Male |
| `en-GB-SoniaNeural` | English (UK) | British female |
| `en-US-AriaNeural` | English (US) | Expressive female |

### Recording

| Variable | Default | Description |
|----------|---------|-------------|
| `QA_VOICE_SILENCE_SECONDS` | `2` | Seconds of silence before auto-stop (converse mode uses 5s override) |
| `QA_VOICE_SILENCE_THRESHOLD` | `500` | RMS energy threshold for silence detection (0-32767) |

### Output

| Variable | Default | Description |
|----------|---------|-------------|
| `QA_VOICE_THINK_FILE` | `/tmp/voicelayer-thinking.md` | Path for the think mode markdown log |

## Per-Mode Speech Rates

Each voice mode has a default rate that balances speed with clarity:

| Mode | Default Rate | Rationale |
|------|-------------|-----------|
| **announce** | `+10%` | Quick status updates — snappy delivery |
| **brief** | `-10%` | Long explanations — slower for digestion |
| **consult** | `+5%` | Checkpoints — slightly fast, user may respond |
| **converse** | `+0%` | Conversational — natural speed |

Rates are auto-adjusted for long text:

| Text Length | Adjustment |
|------------|------------|
| < 300 chars | No change |
| 300-599 chars | -5% |
| 600-999 chars | -10% |
| 1000+ chars | -15% |

You can override per-call by passing the `rate` parameter to any TTS tool.

## MCP Server Configuration

### Basic Setup

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

### With Environment Overrides

```json
{
  "mcpServers": {
    "qa-voice": {
      "command": "bun",
      "args": ["run", "/path/to/voicelayer/src/mcp-server.ts"],
      "env": {
        "QA_VOICE_TTS_VOICE": "en-GB-SoniaNeural",
        "QA_VOICE_STT_BACKEND": "whisper",
        "QA_VOICE_SILENCE_THRESHOLD": "300"
      }
    }
  }
}
```

## File Paths

VoiceLayer uses `/tmp` for all runtime files:

| File | Purpose |
|------|---------|
| `/tmp/voicelayer-session.lock` | Session booking lockfile |
| `/tmp/voicelayer-stop` | User stop signal (touch to end) |
| `/tmp/voicelayer-tts-*.mp3` | Temporary TTS audio (auto-cleaned) |
| `/tmp/voicelayer-recording-*.wav` | Temporary recording (auto-cleaned) |
| `/tmp/voicelayer-thinking.md` | Think mode log (persistent until cleared) |
