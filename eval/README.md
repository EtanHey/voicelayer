# VoiceLayer STT Eval Notes

The eval harness exposes both `voicelayer-resident` and `voicelayer-cli` when
their selected STT backends are actually available.

Latency evidence should separate cold and warm resident cases:

- Cold resident measurements include capability probing, `whisper-server`
  startup, model load, and the first transcription.
- Warm resident measurements require a server that is already healthy and only
  measure request/inference latency.
- Legacy CLI measurements include subprocess startup for each transcription.

Do not compare a warm resident number against a cold CLI number without labeling
both timing boundaries. Use a warmup pass, or report the first sample separately
from subsequent samples.

## Resident Whisper Configuration

The resident `whisper-server` path reads these environment variables:

- `QA_VOICE_WHISPER_ACCELERATION`: acceleration request for the launched
  resident server. Valid values are `auto`, `metal`, `coreml`, and `cpu`.
  Default is `auto`, which keeps the whisper.cpp default GPU path and supplies
  Homebrew Metal shader resources when available. `coreml` probes the
  `whisper-server --help` output for a supported Core ML runtime flag and falls
  back to Metal if unsupported or if startup fails. `cpu` appends `--no-gpu`.
- `QA_VOICE_WHISPER_COREML_MODEL`: path to a `.mlpackage` used only when the
  installed `whisper-server` exposes a Core ML option that requires a model
  package path. Missing paths fall back to Metal.
- `QA_VOICE_WHISPER_COREML`: legacy boolean shortcut. `1`, `true`, or `yes`
  request Core ML when `QA_VOICE_WHISPER_ACCELERATION` is unset.
- `QA_VOICE_WHISPER_SERVER_PORT`: resident server port. Defaults to `8178`.
- `QA_VOICE_WHISPER_MODEL`: GGML model path override. When unset, VoiceLayer
  searches the standard `~/.cache/whisper` model paths.

Live resident evals require both Bun and an available whisper backend. Tests or
scripts that launch real `whisper-server` processes should be treated as live
integration coverage rather than hermetic unit tests.

## Decode Quality Benchmark

Use the local-only decode benchmark when resident `whisper-server` quality
diverges from `whisper-cli` or when tuning latency-vs-quality flags:

```bash
bun run scripts/benchmark-stt-decode.ts \
  --audio /path/to/audio.wav \
  --plans server-bo5-bs5,server-bo5-bs3,server-defaults,cli \
  --language auto
```

The script launches temporary `whisper-server` processes on non-8178 ports and
writes private reports under `docs.local/research/` by default. It does not
touch the running VoiceBar resident server and does not upload audio or
transcripts.
