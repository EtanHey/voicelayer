# Configuration

VoiceLayer is configured entirely via environment variables. All settings have sensible defaults — zero config required for basic usage.

## Environment Variables

### STT (Speech-to-Text)

| Variable | Default | Description |
|----------|---------|-------------|
| `QA_VOICE_STT_BACKEND` | `auto` | Backend selection: `whisper`, `wispr`, or `auto` |
| `QA_VOICE_WHISPER_MODEL` | auto-detected | Absolute path to a whisper.cpp GGML model file |
| `QA_VOICE_WISPR_KEY` | — | Wispr Flow API key (cloud fallback only) |
| `VOICELAYER_STT_PAUSE_PARAGRAPHS` | `1` | Insert blank lines at existing sentence ends supported by long pauses; `0` disables |
| `VOICELAYER_STT_COHERENT_PARAGRAPHS` | unset | `1` gives text-only paragraphs priority over acoustic boundaries; `0` or unset uses the pause setting first. The deterministic paragraph floor still formats an otherwise unformatted long final; see below. |
| `VOICELAYER_STT_AGGRESSIVE_FILLERS` | `0` | Default cleanup removes pure acoustic fillers while preserving repeated words. `1` additionally enables the legacy aggressive policy; `QA_VOICE_STT_AGGRESSIVE_FILLERS` is an alias. |

**Auto-detection** (`auto` mode) checks for whisper.cpp first, falls back to Wispr Flow if `QA_VOICE_WISPR_KEY` is set.

**Model auto-detection** scans `~/.cache/whisper/` for GGML files in this order:

1. `ggml-large-v3-turbo.bin`
2. `ggml-large-v3-turbo-q5_0.bin`
3. `ggml-base.en.bin`
4. `ggml-base.bin`
5. `ggml-small.en.bin`
6. `ggml-small.bin`
7. Any other `ggml-*.bin` file

Pause paragraphs also accept the boolean `pause_paragraphs` key in the processing settings file. Precedence is environment > file > default. The VoiceBar Settings row is planned separately. This step preserves every non-whitespace character, existing line breaks and numbered-list item lines, and keeps existing paragraphs. It needs audio-bound segment times: providers without them, the live streaming path, decodes with both segment-producing controls disabled, and empty acoustic pause maps keep their existing output. The longest sentence-end pauses are ranked toward one break per 450 characters, with at least 200 characters per paragraph and a 0.6-second pause floor.

With pause paragraphs enabled by default, long dictations automatically type Shift+Return between paragraphs, the same delivery path as spoken “new paragraph”. VoiceBar sends newlines as Shift+Return; a bare shell can treat these as submit, just as it does for explicitly spoken line breaks.

Every otherwise unformatted long final gets a deterministic text-only paragraph fallback, regardless of whether model polish is off, skipped, shadowed, unavailable, timed out, rejected or returns no paragraphs. Calls without a polish surface use the same floor. Code is vetoed before either paragraph stage; existing paragraphs and list layout stay intact. Safe acoustic boundaries take priority unless the explicit coherent setting selects text-only paragraphing. Paragraph flags select that primary stage rather than disabling the final floor. The floor changes only whitespace at existing sentence boundaries: every non-whitespace byte, retraction, struck-through word and fragment is preserved.

The default fallback can also paragraph one long list item on a single unwrapped line. It keeps the original marker and indents continuation paragraphs within that item. When prose meets the initial 80-word and four-sentence-unit floors but preferred paragraph sizes prevent a split, the floor uses the most balanced safe sentence boundary. Existing multi-line lists, paragraphs and code spans retain their layout; text without safe sentence boundaries stays unchanged.

Default transcription cleanup removes pure acoustic fillers such as “um”, “uh” and “er”, while retaining retractions, cut-off fragments and repeated speech. The explicit aggressive-filler option additionally removes legacy discourse expressions. Dictionary, numeric and spoken-command transformations remain distinct.

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

Recording uses Silero VAD (neural network) for speech detection. The device's native sample rate is auto-detected — no configuration needed for any microphone (built-in, AirPods, USB, etc.).

Silence detection is configured per-call via the `silence_mode` parameter on `voice_ask`:

| Mode | Silence Duration | Use Case |
|------|-----------------|----------|
| `quick` | 0.5s | Fast responses, short answers |
| `standard` | 1.5s | Normal conversation |
| `thoughtful` | 2.5s (default) | User pauses to think |

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
    "voicelayer": {
      "command": "bunx",
      "args": ["voicelayer-mcp"]
    }
  }
}
```

### With Environment Overrides

```json
{
  "mcpServers": {
    "voicelayer": {
      "command": "bunx",
      "args": ["voicelayer-mcp"],
      "env": {
        "QA_VOICE_TTS_VOICE": "en-GB-SoniaNeural",
        "QA_VOICE_STT_BACKEND": "whisper"
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
