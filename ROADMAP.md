# VoiceLayer Roadmap

Current version: **2.0.0**

## Recently Completed

- **Voice Bar v2** — Floating macOS widget with teleprompter, waveform visualization, click-to-record, draggable positioning, idle collapse
- **Silero VAD** — ONNX-based voice activity detection with configurable silence modes (quick, standard, thoughtful)
- **Voice Cloning** — Zero-shot cloning pipeline: YouTube extraction → sample selection → Qwen3-TTS daemon
- **F5-TTS** — MLX-based cloned voice engine (Tier 1a alternative to Qwen3-TTS)
- **Native Rate Recording** — Auto-detect device sample rate, record natively, resample to 16kHz in JS

## In Progress

### Live Dictation (Voice Bar Phase 4)

Stream audio to whisper-server for real-time transcription — words appear in the Voice Bar as you speak.

- Streaming STT via whisper.cpp server (chunked HTTP POST, ~1.5-2s latency)
- Partial transcription events over socket protocol
- Live text display in Voice Bar during recording
- **Blocker:** Requires whisper-server compiled from source (not in Homebrew)

## Planned

### Production Readiness (Voice Bar Phase 5)

- Launch at login (Login Items / launchd integration)
- Context-aware STT post-processing (developer vocabulary, project-specific terms)
- Configurable Voice Bar position
- npm publish with all v2 features

### Environment Variable Migration

- Migrate `QA_VOICE_*` env vars to `VOICELAYER_*` namespace
- Backward-compatible aliasing during transition

### Future Ideas

- **Multi-language STT** — Language detection + per-language whisper models
- **Streaming VAD improvements** — Lower latency silence detection for faster turn-taking
- **Linux Voice Bar** — GTK or Electron equivalent of the macOS SwiftUI widget
- **Voice profiles directory** — Community-contributed voice profiles
- **WebSocket transport** — Alternative to Unix socket for remote/containerized use

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for development setup. Issues and PRs welcome.
