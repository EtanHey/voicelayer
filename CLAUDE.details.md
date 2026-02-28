# VoiceLayer Details

## Architecture
- MCP server exposes `voice_speak` (non-blocking TTS) and `voice_ask` (blocking record + transcribe).
- TTS routing: Qwen3-TTS daemon (cloned voices) -> edge-tts (preset) -> text-only fallback.
- Voice Bar connects to `/tmp/voicelayer-{TOKEN}.sock` and shows state (idle/speaking/recording/transcribing).
- Socket protocol uses NDJSON events: state, speech, transcription, error; commands: stop, replay, toggle.

## TTS Backends
- Qwen3-TTS daemon runs on port 8880 and reads `~/.voicelayer/voices/{name}/profile.yaml`.
- Profile fields: `engine`, `reference_clip(s)`, `fallback`.
- `voice_speak` supports `replay_index` and `enabled` toggle.
- Ring buffer size is 20 outputs.

## STT Backends
- Backend selection: `QA_VOICE_STT_BACKEND=whisper|wispr|auto` (default auto).
- whisper.cpp binary detection checks `whisper-cli` then `whisper-cpp`.
- Model search order: `QA_VOICE_WHISPER_MODEL` -> `~/.cache/whisper/ggml-large-v3-turbo.bin` -> any `ggml-*.bin` in `~/.cache/whisper/`.

## Voice Modes
- `announce`, `brief`, `consult`: non-blocking TTS only.
- `converse`: blocking TTS + record + transcribe.
- `think`: no audio, writes to markdown log.
- `replay`: plays ring buffer audio.
- `toggle`: enable/disable TTS and/or mic.

## VAD and Recording
- Uses Silero VAD (ONNX) with silence modes: quick (0.5s), standard (1.5s), thoughtful (2.5s).
- Model location: `models/silero_vad.onnx`.
- Recording modes: VAD (default) or `press_to_talk=true` for manual stop.
- Stop signals: touch `/tmp/voicelayer-stop-{TOKEN}`, VAD silence (VAD mode), timeout (default 300s).
- Session booking uses `/tmp/voicelayer-session-{TOKEN}.lock`; stale locks are cleaned.

## Ring Buffer and Playback
- Cached outputs: `/tmp/voicelayer-history-{0-19}.mp3`.
- Metadata: `/tmp/voicelayer-history.json`.
- Stop playback with `pkill afplay` (macOS) or configured hotkey.

## Use Modes
- QA mode: schema `src/schemas/checklist.ts`, categories `src/schemas/qa-categories.ts`, report `src/report.ts`.
- Discovery mode: schema `src/schemas/discovery.ts`, categories `src/schemas/discovery-categories.ts`, brief `src/brief.ts`.
- Outputs: `~/.voicelayer/reports/qa-{date}-{id}.md`, `~/.voicelayer/briefs/discovery-{date}-{id}.md`.

## CLI Commands
- `voicelayer bar` / `voicelayer bar-stop` for the Voice Bar app.
- `voicelayer daemon --port 8880` to run Qwen3-TTS.
- `voicelayer extract ...` to collect voice samples.
- `voicelayer clone ...` to build a voice profile.

## Key Paths
- Socket: `/tmp/voicelayer-{TOKEN}.sock` (TOKEN is a random hex string generated per session for security)
- Thinking log: `/tmp/voicelayer-thinking.md`
- TTS/mic disable flags: `/tmp/.claude_tts_disabled`, `/tmp/.claude_mic_disabled`
- Recording temp files: `/tmp/voicelayer-recording-{pid}-{ts}.wav`
- Qwen3 model: `~/.voicelayer/models/qwen3-tts-4bit/`
- Voice samples: `~/.voicelayer/voices/{name}/samples/*.wav`

## Environment Variables
- `QA_VOICE_STT_BACKEND`, `QA_VOICE_WHISPER_MODEL`, `QA_VOICE_WISPR_KEY`
- `QA_VOICE_TTS_VOICE`, `QA_VOICE_TTS_RATE`, `QA_VOICE_THINK_FILE`

## Dependencies (setup)
- sox (`rec`), edge-tts, whisper-cpp (optional), yt-dlp, ffmpeg
- Python: mlx-audio, fastapi, uvicorn, silero-vad, torch, soundfile
- Optional: demucs, pyannote.audio

## Naming
- Primary tools: `voice_speak`, `voice_ask`
- Back-compat: `qa_voice_*` aliases (announce, brief, consult, converse, think, say, ask, replay, toggle)
- Env vars use `QA_VOICE_*` (aliasing to `VOICELAYER_*` planned)
