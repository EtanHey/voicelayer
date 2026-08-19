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
| `QA_VOICE_TTS_RATE` | `+0%` | Base speech rate |
| `VOICELAYER_TTS_DAEMON_SECRET_FILE` | `~/.voicelayer/daemon.secret` | Preferred override for the shared Qwen3 daemon bearer secret file |
| `VOICELAYER_TTS_AUTH_TOKEN_FILE` | `~/.voicelayer/daemon.secret` | Backward-compatible override for the shared Qwen3 daemon bearer secret file |


## STT performance tiers

VoiceBar's Audio tab exposes three decoding-effort tiers. They trade latency for accuracy on the
*same* `large-v3-turbo` model — only whisper.cpp's beam search / best-of changes, not the model.

| Tier | whisper.cpp args | Notes |
|------|------------------|-------|
| **Fast** | `-bo 1 -bs 1` | Lowest decode cost |
| **Balanced** | `-bo 3 -bs 3` | Middle ground |
| **Accurate** | `-bo 5 -bs 5` | Default; widest beam |

The selection persists to `~/.local/state/voicelayer/whisper-performance.json`. Override
per-process with `QA_VOICE_WHISPER_PERFORMANCE_EFFORT=fast|balanced|accurate`.

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
   `dist/voicebar-release/**/Resources/src/__tests__` build copy gets picked up and
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

