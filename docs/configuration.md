# Configuration

Environment variables and test commands.

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `QA_VOICE_STT_BACKEND` | `auto` | STT backend: `whisper`, `wispr`, or `auto` |
| `QA_VOICE_WHISPER_MODEL` | auto-detected | Path to whisper.cpp GGML model |
| `QA_VOICE_WHISPER_PERFORMANCE_EFFORT` | `accurate` | STT decode effort: `fast`, `balanced`, or `accurate` |
| `VOICELAYER_STT_AGGRESSIVE_FILLERS` | unset | Opt into legacy removal of meaning-bearing hedges/intensifiers; `QA_VOICE_STT_AGGRESSIVE_FILLERS` is supported as a legacy alias |
| `QA_VOICE_WISPR_KEY` | -- | Wispr Flow API key (cloud fallback) |
| `QA_VOICE_TTS_VOICE` | `en-US-JennyNeural` | edge-tts voice ID |
| `VOICELAYER_ASK_NO_ANSWER_SECONDS` | `120` | Ask no-answer deadline after the question finishes; finite seconds from 5–3600, invalid values use 120. Explicit `timeout_seconds` overrides it. First detected speech cancels it permanently; normal silence/Stop rules then apply. Silent takes are archived, HOLD pauses this budget; locked Ask ends on 10 minutes of continuous silence, renewed by speech, with no cap. |
| `QA_VOICE_TTS_RATE` | `+0%` | Base speech rate |
| `VOICELAYER_TTS_DAEMON_SECRET_FILE` | `~/.voicelayer/daemon.secret` | Preferred override for the shared Qwen3 daemon bearer secret file |
| `VOICELAYER_TTS_AUTH_TOKEN_FILE` | `~/.voicelayer/daemon.secret` | Backward-compatible override for the shared Qwen3 daemon bearer secret file |


## STT performance tiers

The backend supports three decoding-effort values for the *same* `large-v3-turbo` model.
Only whisper.cpp's beam search / best-of changes. Settings has no effort picker; removing it
does not change existing saved values, environment overrides, or the Accurate default.

| Tier | whisper.cpp args | Notes |
|------|------------------|-------|
| **Fast** | `-bo 1 -bs 1` | Lowest decode cost |
| **Balanced** | `-bo 3 -bs 3` | Middle ground |
| **Accurate** | `-bo 5 -bs 5` | Default; widest beam |

Saved preferences remain in `~/.local/state/voicelayer/whisper-performance.json`. Override
per-process with `QA_VOICE_WHISPER_PERFORMANCE_EFFORT=fast|balanced|accurate`.

## Transcription API (opt-in)

Set `"transcriptions_enabled": true` in `~/.local/state/voicelayer/processing-settings.json`
(or `$VOICELAYER_STATE_DIR/processing-settings.json`), preserving its other fields, then restart VoiceBar.
This persists across login, reboot and update relaunch. Default is OFF; a defined
`VOICELAYER_TRANSCRIPTIONS_ENABLED=1` or `0` overrides the saved setting. The daemon serves
`http://127.0.0.1:8179/v1/audio/transcriptions` (override the port with
`VOICELAYER_TRANSCRIPTIONS_PORT`). Only `127.0.0.1` binds are accepted.
Configure T3's exact base string as `http://127.0.0.1:8179/v1`. Changing the port
or any URL bytes requires granting client consent again.
Use the dedicated token from `~/.voicelayer/transcriptions.secret`, or
`$VOICELAYER_STATE_DIR/transcriptions.secret` when set, as the Bearer API key.
It is generated on first enabled start with mode 0600; it does not unlock speech control.
The same token is reused across restarts; restarting does not rotate it.
POST multipart `file` (complete mono 16kHz PCM16 WAV, at most 25 MiB), optional
`language` and `prompt`, and `response_format=json` (default) or `text`. The client
language hint is ignored; VoiceLayer's own language settings remain authoritative.
Any `model` is accepted and ignored, as are `languages[]` and `keywords[]`.
JSON returns `{ "text": "..." }`.
Busy voice work returns 409; retry once idle. Uploads use the current recognizer,
dictionary, punctuation, polish and paragraphs without capture, paste or playback.
Disable duplicate cleanup in the client. Accepted WAVs are saved before inference
in the existing History archive, including failures, with `upload_source: "t3"`
metadata; the existing VoiceBar source discriminator/UI is unchanged. Temporary
multipart data stays in memory; upload text is excluded from polish logs.
An unloaded model loads through the same single owner used by live dictation.
Missing/downloading assets or unconfirmed cleanup return 503 with retained audio.
A 100-second request budget leaves cleanup time before T3's two-minute timeout.
Disconnects/timeouts retain a failure receipt; an ongoing load continues for retry.
Set the saved setting to false (and remove any enable override), then restart to close the endpoint.

## Testing

```bash
bun test                              # Bun/TypeScript suite
swift test --package-path flow-bar    # Swift tests for VoiceBar
git config core.hooksPath .githooks   # install repo pre-push hook once per clone (#181, #182)
```

Test counts are deliberately not written down here — they rot within a week, and three
different numbers were in circulation before this was cleaned up. The CI run on `main` is
the number.

**What CI runs.** The GitHub Actions `CI` workflow runs the platform-independent slice. The
remaining local tests are macOS- and hardware-bound (real whisper decodes, live daemon/socket
round-trips, microphone capture, corpus replay) and are skipped off-macOS.

**Running the full suite locally**, note two things:
1. `bun test` treats its arguments as path *substrings*, so a previous
   `.build.noindex/voicebar-release/**/Resources/src/__tests__` build copy gets picked up and
   double-counted (even via `bun test src/`). Scope with an explicit file list:
   `bun test $(git ls-files 'src/__tests__/*.test.ts')`.
2. Many local-only tests assert against **real machine and repo state**, so they
   fail for environmental reasons rather than code ones:
   - the shell-contract suites (`voicelayer-version-check.sh`,
     `voicelayer-verify.sh`, `voicelayer-update.sh`, `verify-notch-*.sh`) require a
     **clean worktree on a tagged release commit**, with the git tag, `package.json`,
     the checked-in `Info.plist`, the Homebrew cask, and the stapled resident
     `/Applications/VoiceBar.app` all in agreement — by design, since that is exactly
     what they exist to police. On a feature branch they will fail.
   - the live-integration and TTS tests claim the **real microphone** and voice-session
     lock, so running them while VoiceBar is recording (or alongside another agent
     driving the daemon) yields failures like
     `user is recording — speaker output refused`.

   Treat CI, or a clean checkout at a release tag on an idle machine, as the source of
   truth for "green".

Test coverage includes: MCP protocol framing, tool handlers, TTS synthesis + retry, VAD speech detection, session booking, process lock lifecycle, socket client reconnection, edge-tts health checks, schema validation, Hebrew STT eval baselines, daemon resilience, ToolAnnotations, SSML sanitization, and secure path hardening.

