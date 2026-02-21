# STT Backends

VoiceLayer supports two speech-to-text backends with automatic detection. Local processing via whisper.cpp is preferred; Wispr Flow provides a cloud fallback.

## Backend Comparison

| Feature | whisper.cpp | Wispr Flow |
|---------|-------------|------------|
| **Type** | Local | Cloud |
| **Speed** | ~200-400ms (Apple Silicon) | ~500ms + network latency |
| **Privacy** | Audio never leaves your machine | Audio sent to Wispr API |
| **Cost** | Free | Requires API key |
| **Setup** | `brew install whisper-cpp` + model | Set `QA_VOICE_WISPR_KEY` |
| **Quality** | Excellent (large-v3-turbo) | Good |
| **Offline** | Yes | No |

## whisper.cpp (Recommended)

### Installation

```bash
# macOS (Homebrew)
brew install whisper-cpp

# Linux — build from source
git clone https://github.com/ggerganov/whisper.cpp
cd whisper.cpp && make
sudo cp main /usr/local/bin/whisper-cpp
```

### Model Download

```bash
mkdir -p ~/.cache/whisper

# Large v3 Turbo — best balance of speed and accuracy
curl -L -o ~/.cache/whisper/ggml-large-v3-turbo.bin \
  https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin
```

**Model comparison:**

| Model | Size | Speed (M1 Pro) | Accuracy |
|-------|------|----------------|----------|
| `ggml-large-v3-turbo` | 1.6 GB | ~200-400ms | Best |
| `ggml-large-v3-turbo-q5_0` | ~1 GB | ~150-300ms | Very good |
| `ggml-base.en` | 148 MB | ~50-100ms | Good (English only) |
| `ggml-small.en` | 488 MB | ~100-200ms | Better (English only) |

### Auto-Detection

VoiceLayer scans `~/.cache/whisper/` for GGML model files in priority order:

1. `ggml-large-v3-turbo.bin`
2. `ggml-large-v3-turbo-q5_0.bin`
3. `ggml-base.en.bin`
4. `ggml-base.bin`
5. `ggml-small.en.bin`
6. `ggml-small.bin`
7. Any other `ggml-*.bin` file

Override with `QA_VOICE_WHISPER_MODEL=/path/to/model.bin`.

### Metal Acceleration

On macOS with Apple Silicon, whisper.cpp automatically uses Metal (GPU) acceleration. VoiceLayer detects the Homebrew prefix and sets `GGML_METAL_PATH_RESOURCES` so Metal shaders are found correctly.

### Transcription Flags

VoiceLayer runs whisper.cpp with:

- `--no-timestamps` — clean text output without `[00:00.000 --> 00:05.000]` markers
- `-l en` — English language
- `--no-prints` — suppress progress output (stderr only)

## Wispr Flow (Cloud Fallback)

### Setup

1. Get an API key from Wispr Flow
2. Set the environment variable:

```bash
export QA_VOICE_WISPR_KEY="your-api-key"
```

Or in your MCP config:

```json
{
  "mcpServers": {
    "qa-voice": {
      "env": {
        "QA_VOICE_WISPR_KEY": "your-api-key"
      }
    }
  }
}
```

### How It Works

1. Recorded WAV audio is read into memory
2. WAV header is stripped (44 bytes) to get raw PCM
3. PCM is sent in 1-second chunks over WebSocket to Wispr API
4. Each chunk includes base64 audio + RMS volume level
5. A `commit` message signals end of audio
6. Wispr returns transcribed text
7. 30-second timeout prevents hangs

!!! warning "Privacy consideration"
    Wispr Flow sends audio data to their cloud API. For sensitive conversations, use whisper.cpp (local) instead.

## Backend Selection

### Automatic (Default)

```bash
# No config needed — whisper.cpp if available, else Wispr Flow
QA_VOICE_STT_BACKEND=auto  # this is the default
```

### Force whisper.cpp

```bash
QA_VOICE_STT_BACKEND=whisper
```

Fails with a clear error if whisper.cpp binary or model isn't found.

### Force Wispr Flow

```bash
QA_VOICE_STT_BACKEND=wispr
```

Fails with a clear error if `QA_VOICE_WISPR_KEY` isn't set.

## STT Result Format

Both backends return the same structure:

```typescript
interface STTResult {
  text: string;       // Transcribed text
  backend: string;    // "whisper.cpp" or "wispr-flow"
  durationMs: number; // Transcription time in milliseconds
}
```

The backend name and duration are logged to stderr for debugging.
