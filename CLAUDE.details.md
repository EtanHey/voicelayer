# VoiceLayer Details

## Architecture
- MCP server exposes `voice_speak` (non-blocking TTS) and `voice_ask` (blocking record + transcribe).
- TTS routing: Qwen3-TTS daemon (cloned voices) -> edge-tts (preset) -> text-only fallback.
- Voice Bar is a persistent server on `/tmp/voicelayer.sock` (POSIX sockets + GCD). MCP servers connect as clients.
- Socket protocol uses NDJSON events: state, speech, transcription, error; commands: stop, replay, toggle.
- No discovery file — fixed socket path. Voice Bar survives MCP reconnects.

## MCP Daemon Ownership
- Daily-driver supervision is `launchd -> VoiceBar.app -> child MCP daemon`.
- `com.voicelayer.mcp-daemon` is retired. `bash launchd/install.sh` now removes that old daemon LaunchAgent instead of installing it.
- VoiceBar is the sole daemon owner. It launches `src/mcp-server-daemon.ts` as a child process so macOS microphone TCC is inherited from the app.
- The app restarts the child on crashes, clean exits, and broken-mic silence signals unless `/tmp/.voicelayer-daemon-disabled` is present.
- `bash flow-bar/build-app.sh` may run the retirement script after rebuilding `/Applications/VoiceBar.app`; it must not install a second daemon owner.

## TTS Backends
- Qwen3-TTS daemon runs on port 8880 and reads `~/.voicelayer/voices/{name}/profile.yaml`.
- Profile fields: `engine`, `reference_clip(s)`, `fallback`.
- `voice_speak` supports `replay_index` and `enabled` toggle.
- Ring buffer size is 20 outputs.

## STT Backends
- Backend selection: `QA_VOICE_STT_BACKEND=whisper|wispr|auto` (default auto).
- whisper.cpp binary detection checks `whisper-cli` then `whisper-cpp`.
- Model search order: `QA_VOICE_WHISPER_MODEL` -> `~/.cache/whisper/ggml-large-v3-turbo.bin` -> any `ggml-*.bin` in `~/.cache/whisper/`.
- Performance effort tiers (Settings -> Audio -> Performance, code in `src/whisper-performance.ts`): `fast` (`-bo 1 -bs 1`), `balanced` (`-bo 3 -bs 3`), `accurate` (`-bo 5 -bs 5`, default). Same `large-v3-turbo` model for all three — only whisper.cpp beam-search/best-of changes. Persisted to `~/.local/state/voicelayer/whisper-performance.json`; override per-process with `QA_VOICE_WHISPER_PERFORMANCE_EFFORT`.

## VoiceBar Settings (SwiftUI, `flow-bar/Sources/VoiceBarUI/SettingsView.swift`)
- General tab: hotkey shortcut/status; permissions panel (Microphone + Accessibility + Input Monitoring) with "Open" links to the matching System Settings pane; Karabiner "Set up" helper (F5 relay install); gestures + pill position/anchor.
- Audio tab: microphone input-device picker + Performance effort tier picker (Fast/Balanced/Accurate).
- Dictionary tab: STT corrections + prompt terms (same store as `voicelayer vocab`).

## Voice Modes
- `announce`, `brief`, `consult`: non-blocking TTS only.
- `converse`: blocking TTS + record + transcribe.
- `think`: no audio, writes to markdown log.
- `replay`: plays ring buffer audio.
- `toggle`: enable/disable TTS and/or mic.

## VAD and Recording
- Uses Silero VAD (ONNX) with silence modes: quick (0.5s), standard (1.5s), thoughtful (2.5s).
- Model location: `models/silero_vad.onnx`.
- MCP recording modes: VAD (default) or gated `push_to_end=true` for manual stop.
- VoiceBar's trusted F5/tap socket field remains `press_to_talk=true`; do not rename or MCP-gate it.
- Stop signals: touch `/tmp/voicelayer-stop-{TOKEN}`, VAD silence (VAD mode), timeout (default 30s).
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
- `voicelayer build-app` builds VoiceBar from source and installs `/Applications/VoiceBar.app` (override `--install-path`; refuses to overwrite a running VoiceBar; runs `launchd/install.sh` after). Routes to `flow-bar/build-app.sh`.
- `voicelayer bar` launches the installed `/Applications/VoiceBar.app` via `open` (no longer builds a dev binary); errors out telling you to run `build-app` if the bundle is missing. `voicelayer bar-stop` stops it.
- `voicelayer update` is a cross-machine updater (auto-detects git-checkout vs global-package install): updates the package, rebuilds the app, runs `launchd/install.sh`, pulls the Qwen3 model into `~/.voicelayer` if missing, and restarts the VoiceBar stack. Flags: `--dry-run`, `--data-mode skip|direct|brain-drive`, `--data-source SOURCE_HOME` (personal-data rsync is opt-in; default `skip`). Routes to `scripts/voicelayer-update.sh`.
- `voicelayer hotkey install|status` installs/inspects the F5/Dictation -> F18 `hidutil` relay LaunchAgent.
- `voicelayer daemon --port 8880` to run Qwen3-TTS.
- `voicelayer extract ...` to collect voice samples.
- `voicelayer clone ...` to build a voice profile.
- `voicelayer vocab ...` to add/list/remove STT vocabulary aliases.

## Key Paths
- Socket: `/tmp/voicelayer.sock` (fixed path — Voice Bar listens, MCP connects)
- Thinking log: `/tmp/voicelayer-thinking.md`
- TTS/mic disable flags: `/tmp/.claude_tts_disabled`, `/tmp/.claude_mic_disabled`
- Recording temp files: `/tmp/voicelayer-recording-{pid}-{ts}.wav`
- Qwen3 model: `~/.voicelayer/models/qwen3-tts-4bit/`
- Voice samples: `~/.voicelayer/voices/{name}/samples/*.wav`

## Environment Variables
- `QA_VOICE_STT_BACKEND`, `QA_VOICE_WHISPER_MODEL`, `QA_VOICE_WISPR_KEY`
- `VOICELAYER_STT_AGGRESSIVE_FILLERS=1` opts into legacy removal of meaning-bearing English hedges/intensifiers; `QA_VOICE_STT_AGGRESSIVE_FILLERS` remains a legacy alias. Default cleanup preserves those words.
- `QA_VOICE_TTS_VOICE`, `QA_VOICE_TTS_RATE`, `QA_VOICE_THINK_FILE`
- `VOICELAYER_ALLOW_PUSH_TO_END=1` enables the MCP manual-stop mode; unset/other values keep it disabled.
- `VOICELAYER_SOCKET_PATH` and `VOICELAYER_MCP_SOCKET_PATH` isolate dev VoiceBar/MCP sockets; legacy `QA_VOICE_SOCKET_PATH` and `QA_VOICE_MCP_SOCKET_PATH` remain supported.

## Dependencies (setup)
- sox (`rec`), edge-tts, whisper-cpp (optional), yt-dlp, ffmpeg
- Python: mlx-audio, fastapi, uvicorn, numpy, pydantic, silero-vad, torch, soundfile
- Optional: demucs, pyannote.audio

## Naming
- Primary tools: `voice_speak`, `voice_ask`
- Env vars use a mixed contract: `VOICELAYER_*` is canonical where implemented (currently aggressive-filler control and socket overrides), with legacy `QA_VOICE_*` aliases retained; settings not yet migrated still use `QA_VOICE_*`.
