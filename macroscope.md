# Macroscope — VoiceLayer Code Review Rules

> Categorized best practices for automated code review of the VoiceLayer codebase.
> VoiceLayer is a bi-directional TTS/STT system: TypeScript MCP server + VoiceBar Swift macOS daemon.

---

## Security

- Never log or store audio recordings beyond the current session. Temp files in `/tmp/voicelayer-*` must be cleaned up on session end.
- API keys for TTS/STT services (e.g. `QA_VOICE_WISPR_KEY`) must come from environment variables — never hardcode credentials.
- The Unix socket at `/tmp/voicelayer.sock` has no authentication. Do not expose it beyond localhost.
- Voice samples and cloned voice profiles (`~/.voicelayer/`) may contain biometric data — treat as sensitive.

## Architecture

- **VoiceBar is the persistent server** on `/tmp/voicelayer.sock` — MCP server instances connect as clients, not the other way around. Reversing this relationship breaks the singleton model.
- **edge-tts is the primary TTS backend.** Long messages must be chunked before sending — edge-tts silently fails or truncates on long text. Callers must handle this.
- **`voice_ask` is BLOCKING** (waits for mic input + transcription). **`voice_speak` is non-blocking** (fires and returns). Never confuse them — calling `voice_ask` where `voice_speak` was intended will hang the agent.
- **Multiple MCP server instances can cause orphan sockets.** Each Claude Code session spawns its own MCP server process. Stale sockets and lock files (`/tmp/voicelayer-session.lock`) must be cleaned up. Session booking uses PID-based stale lock detection.
- **Three-tier TTS routing:** Qwen3-TTS (cloned voices) → edge-tts (neural) → text-only fallback. Do not bypass this chain.
- **Dual protocol support:** NDJSON streaming + MCP Content-Length framing. Changes to the transport layer must preserve both.
- **Session booking is lockfile-based** (`/tmp/voicelayer-session.lock`). It prevents mic conflicts between concurrent sessions. Do not remove or weaken this mutex.
- **Audio pipeline order matters:** native sample rate recording → 16kHz resampling → Silero VAD → whisper.cpp. Changing the order or skipping resampling will break STT accuracy.

## Dictation cleanup (`src/rules-engine.ts`)

- **The governing law is AGENTS.md: "a fix that loses my words is worse than the bug."** Rank a
  finding that drops a spoken word above any finding about punctuation tidiness. Where the two
  conflict, verbatim wins.
- **Etan talks ABOUT dictation commands.** "The words colon, comma, and period are punctuation" and
  "there's still sometimes a new line on codex agents" are prose, not commands. Whisper punctuates a
  meta-mention exactly like a dictated one, so surrounding commas are not evidence either way.
- **Whisper isolates each spoken command in its own commas** — "update, colon, Q3" is one dictated
  "colon", not a list. Adjacent commands SHARE a delimiter, so anything matching them one at a time
  leaves the second one wrapped.
- **`applyRules` stage order is load-bearing** and changing it silently breaks things: the
  comma-unwrap must run before every other substitution (`preserveCodeTokens` rewrites "open paren"
  early), and any stage that does `split(/\s+/).join(" ")` will flatten a newline a command
  produced. Check both before proposing a reorder.
- **Before claiming a cleanup bug is a regression, diff against `main`.** Several long-standing
  defects in this file predate any given PR; the useful report says which.

## Testing

- Test both TTS and STT paths independently — they have different backends and failure modes.
- **edge-tts availability** should be checked at startup (`pip3 install edge-tts`). Missing edge-tts must produce a clear error, not a silent failure.
- Voice profiles are stored in `~/.voicelayer/voices.json`. Tests that modify profiles must use fixtures, not the real file.
- Pronunciation overrides go in `~/.voicelayer/pronunciation.yaml` — test that overrides are applied before TTS synthesis.
- Run the full suite with `bun test` (308 tests). PRs must not reduce test count without justification.
- Mock audio I/O (sox, afplay, whisper-cpp) in unit tests — never depend on real hardware in CI.

## Style

- TypeScript strict mode is mandatory — no `any` types without an explicit comment explaining why.
- MCP tool descriptions must clearly state **blocking vs non-blocking** behavior. This is a safety-critical distinction for callers.
- Keep `/tmp/voicelayer-*` path constants centralized in `src/paths.ts`. Do not scatter hardcoded `/tmp` paths.
- SwiftUI code in `flow-bar/` follows standard Apple conventions. Keep Swift and TypeScript concerns separated — IPC via the socket protocol only (`src/socket-protocol.ts`).
- Environment variable names use the `QA_VOICE_` prefix for backward compatibility. New variables should follow the same convention.
- The served MCP surface is exactly `voice_speak` and `voice_ask`; do not add compatibility aliases.
