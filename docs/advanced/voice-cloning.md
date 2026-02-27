# Voice Cloning

VoiceLayer supports **zero-shot voice cloning** using Qwen3-TTS. Clone any voice from YouTube samples — no model training required.

## How It Works

```text
YouTube URL → yt-dlp (WAV 48kHz) → Silero VAD segmentation → FFmpeg normalization
→ voicelayer clone (select best 3 clips) → profile.yaml → Qwen3-TTS daemon
```

Three-tier TTS routing at runtime:

1. **Qwen3-TTS** — cloned voice (if daemon running + profile exists)
2. **edge-tts** — Microsoft neural voice (free, always available)
3. **Text-only** — fallback when no audio output possible

## Prerequisites

```bash
# Required
brew install yt-dlp ffmpeg
pip3 install silero-vad torch soundfile

# Optional (better quality)
pip3 install demucs            # Source separation (removes background music)
pip3 install pyannote.audio    # Speaker diarization (multi-speaker videos)

# TTS daemon
pip3 install mlx-audio fastapi uvicorn
```

## Step 1: Extract Voice Samples

Pull clean voice clips from YouTube videos:

```bash
voicelayer extract \
  --source "https://youtube.com/@channel" \
  --name "speaker-name" \
  --count 20
```

The extraction pipeline:

1. Downloads audio via `yt-dlp` (WAV 48kHz)
2. Optionally runs Demucs source separation (`--demucs`)
3. Segments speech using Silero VAD
4. Optionally diarizes speakers (`--diarize`)
5. Normalizes audio (highpass 80Hz, loudnorm -16 LUFS)
6. Saves clips to `~/.voicelayer/voices/{name}/samples/`

### Options

| Flag | Default | Description |
|------|---------|-------------|
| `--source` | required | YouTube URL (channel, video, or playlist) |
| `--name` | required | Voice profile name |
| `--count` | `20` | Number of clips to extract |
| `--demucs` | off | Enable source separation |
| `--diarize` | off | Enable speaker diarization |

## Step 2: Build a Voice Profile

Select the best reference clips and generate a profile:

```bash
voicelayer clone --name "speaker-name"
```

This command:

1. Reads all samples from `~/.voicelayer/voices/{name}/samples/`
2. Analyzes audio quality (duration, RMS level, SNR estimate)
3. Selects the best 3 clips (~18.5s total — Qwen3-TTS sweet spot: 3-30s)
4. Generates transcripts via whisper.cpp
5. Writes `~/.voicelayer/voices/{name}/profile.yaml`

### Profile Format

```yaml
name: speaker-name
engine: qwen3-tts
model_path: ~/.voicelayer/models/qwen3-tts-4bit
reference_clips:
  - path: ~/.voicelayer/voices/speaker-name/samples/clip_007.wav
    text: "Transcribed text of this clip..."
  - path: ~/.voicelayer/voices/speaker-name/samples/clip_012.wav
    text: "Another transcribed clip..."
  - path: ~/.voicelayer/voices/speaker-name/samples/clip_003.wav
    text: "Third reference clip..."
reference_clip: ~/.voicelayer/voices/speaker-name/samples/clip_007.wav
fallback: en-US-GuyNeural
created: "2026-02-27"
source: "https://youtube.com/@channel"
```

## Step 3: Run the TTS Daemon

Start the Qwen3-TTS daemon for runtime synthesis:

```bash
voicelayer daemon --port 8880
```

The daemon:

- Loads the Qwen3-TTS 4-bit quantized model into Metal/MPS memory
- Serves a `/synthesize` HTTP endpoint
- Inference latency: 200-500ms per call on Apple Silicon
- Model location: `~/.voicelayer/models/qwen3-tts-4bit/`

### Testing

```bash
# Health check
curl http://127.0.0.1:8880/health

# Synthesize
curl -X POST http://127.0.0.1:8880/synthesize \
  -H "Content-Type: application/json" \
  -d '{"text": "Hello world", "voice": "speaker-name"}'
```

## Using Cloned Voices

Once the daemon is running and a profile exists, VoiceLayer automatically routes through Qwen3-TTS:

```
voice_speak("Your cloned voice speaks this text")
```

If the daemon is unavailable, VoiceLayer falls back to edge-tts using the `fallback` voice from the profile.

## File Locations

| Path | Purpose |
|------|---------|
| `~/.voicelayer/voices/{name}/samples/` | Extracted voice clips |
| `~/.voicelayer/voices/{name}/profile.yaml` | Voice profile |
| `~/.voicelayer/models/qwen3-tts-4bit/` | Quantized model weights |
