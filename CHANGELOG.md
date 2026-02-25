# Changelog

All notable changes to VoiceLayer will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.3] - 2026-02-25

### Fixed
- **Audio overlap between voice_speak and voice_ask** — `voice_ask` now auto-waits for any playing `voice_speak` audio to finish before speaking its question. Previously, non-blocking `voice_speak` (brief/announce/consult) could overlap with the next `voice_ask` TTS, creating unnatural double-audio.
- **Recording fails with AirPods and other non-16kHz devices** — Recording now detects the device's native sample rate and records at that rate, then resamples to 16kHz in code. Previously, sox tried to force 16kHz on devices that only support other rates (e.g., AirPods at 24kHz), causing buffer overruns and silent audio data loss when piping to stdout. Silero VAD never detected speech because the audio chunks were mostly empty.

### Added
- `awaitCurrentPlayback()` in `tts.ts` — awaits completion of any currently playing audio
- `detectNativeSampleRate()` in `audio-utils.ts` — probes default audio device via `rec -n stat`
- `resamplePCM16()` in `audio-utils.ts` — linear interpolation resampler for 16-bit PCM between arbitrary sample rates

## [1.0.2] - 2026-02-22

### Fixed
- **whisper.cpp not detected on macOS** — Homebrew v1.8.3+ renamed binary from `whisper-cpp` to `whisper-cli`. Now checks both names, preferring `whisper-cli`. This was the root cause of STT failures — local backend was never activating, forcing fallback to Wispr cloud.
- **Wispr Flow cloud fallback** — Fixed `audio_encoding` from deprecated `"pcm"` to `"wav"`. Restored 1-second PCM chunking (prevents timeout on long recordings). Wispr is now a reliable cloud fallback when whisper.cpp is unavailable.

## [1.0.1] - 2026-02-22

### Fixed
- **Wispr STT broken** — Wispr API dropped raw PCM support. Switched to `audio_encoding: "wav"` ([#9](https://github.com/EtanHey/voicelayer/pull/9))

## [1.0.0] - 2026-02-21

### Added
- Initial release — extracted from `golems/packages/qa-voice`
- 5 voice modes: announce, brief, consult, converse, think
- Local TTS via edge-tts (neural quality, free)
- Local STT via whisper.cpp (~300ms latency) or Wispr Flow (cloud)
- Session booking with lockfile mutex ("line busy" for concurrent sessions)
- User-controlled stop (touch `/tmp/voicelayer-stop`)
- MCP server with 7 tools (`qa_voice_announce`, `qa_voice_brief`, `qa_voice_consult`, `qa_voice_converse`, `qa_voice_think`, `qa_voice_say`, `qa_voice_ask`)
- Note: These tools were later consolidated into `voice_speak` and `voice_ask` (aliases still supported).
- Published to npm as `voicelayer-mcp`
- MkDocs Material documentation site (16 pages)
- GitHub Actions CI (lint, typecheck, test)
- JSON.parse validators for STT responses
- MCP Registry `server.json`

### Infrastructure
- Dark navy docs theme matching etanheyman.com
- GitHub Pages deployment workflow
- 75 unit tests across 9 test files
