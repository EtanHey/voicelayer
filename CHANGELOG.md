# Changelog

All notable changes to VoiceLayer will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

_Nothing yet._

## [2.2.0] - 2026-07-22

### Removed — BREAKING

- **The nine `qa_voice_*` MCP aliases are gone.** The server now advertises exactly
  two tools: `voice_speak` and `voice_ask`. Removed: `qa_voice_announce`,
  `qa_voice_brief`, `qa_voice_consult`, `qa_voice_converse`, `qa_voice_think`,
  `qa_voice_say`, `qa_voice_ask`, `qa_voice_replay`, `qa_voice_toggle`.

  **No capability is lost** — every alias was surface over the two canonical tools:

  | Removed alias | Call instead |
  |---|---|
  | `qa_voice_announce` / `qa_voice_say` | `voice_speak({ mode: 'announce' })` |
  | `qa_voice_brief` | `voice_speak({ mode: 'brief' })` |
  | `qa_voice_consult` | `voice_speak({ mode: 'consult' })` |
  | `qa_voice_think` | `voice_speak({ mode: 'think' })` |
  | `qa_voice_replay` | `voice_speak({ replay_index: N })` |
  | `qa_voice_toggle` | `voice_speak({ enabled: bool })` |
  | `qa_voice_converse` / `qa_voice_ask` | `voice_ask({ ... })` |

  `voice_speak` still auto-detects the mode from message content, so most callers
  need only the tool name change. A regression test now pins the served tool list
  to exactly `["voice_speak", "voice_ask"]` so an alias cannot silently return.

## [2.1.17] - 2026-07-22 — notch convergence

The VoiceBar **notch** becomes the finished canonical surface: readable glass,
centered morphs, a truthful waveform, working system-control pass-through, and a
restored right-click menu.

### Added
- **Readable Liquid Glass + notch morph prototypes** — glass material with a legible
  content layer over the wings, and three morph prototypes evaluated against the
  camera-housing core (#362).
- **Recording hold control** contained inside the morph canvas, so VAD controls no
  longer escape the notch shape (#366).

### Changed
- **Morph originates from the notch center** and the hit area tracks the animating
  surface; wings size responsively to their content instead of being forced equal
  widths (#365).
- **Window height tracks state** rather than being pinned to the tallest state (#365).

### Fixed
- **Notch pointer coordinates vertically aligned** — `NSEvent.locationInWindow` is
  already an unflipped panel-window coordinate, but the pill hosting view converted
  it a second time through its flipped `NSHostingView`, pushing the whole hit region
  ~15–18pt DOWN (the top ~75% of every control glyph was dead). Forwarded unchanged
  (#373).
- **Right-click context menu restored** — hit-testing now claims the full *rendered*
  notch shape (`containsVisibleSurface`) for window admission and right-click, while
  the mounted control glyphs (`containsInteractiveContent`) own active controls and
  drag. Transparent margins still return `nil` (#372).
- **Notch event handling hardened** — the notch no longer intercepts clicks meant for
  adjacent macOS menu-bar controls (screen-recording stop, mic indicator, third-party
  icons), and never steals focus from the frontmost app (`.nonactivatingPanel`,
  no-key/no-main) (#370).
- **Hover stabilized** — hover authority is the global mouse monitor →
  `handlePointerMovement` → hysteresis; native glass hosts no longer own their own
  tracking areas, removing the first-hover color flicker. Empty teleprompter wing
  fixed (#371).
- **Waveform** centered and smoothed with a 200ms decay (#364), padding made
  consistent across recording/processing/speaking states (#367).
- **F5 "pill dance" fixed**, hit-region width corrected, caption ellipsis restored
  (#369).
- **Replay made atomic** — replay restarts the existing audio instead of stacking a
  second playback; the mic is released on `SIGTERM` so terminated QA instances stop
  leaving ghost menu entries (#368).
- **Teleprompter replay controls serialized**; dictionary access relocated (#363).
- Notch live-truth polish gaps closed (#359).

## [2.1.16] - 2026-07-19

### Changed
- **The notch surface is now canonical** — VoiceBar renders as a menu-bar notch
  surface around the camera housing instead of a floating draggable pill (#357, #358).

### Fixed
- Suppress stale ask prompts after a `voice_ask` timeout (#355).
- Close `voice_ask` / `voice_speak` runtime residuals (#354).

## [2.1.15] - 2026-07-19

### Added
- **Truthful waveform** — VoiceBar renders real captured/played amplitude instead of
  a decorative animation, for both recording and playback; decoding is kept off the
  speak path and bounded (#348).
- **Teleprompter persistence + VAD recording hold** — readback content is retained and
  recording can be held open through silence (#347, #349).
- Corpus-replay verification harness (isolated runtime, deterministic verifier).
- Phase-0 mined STT aliases (#343); VoiceBar dev-expanded state (#346).

### Fixed
- **Paste transcript once, restore the clipboard atomically** — removes duplicate
  pastes and clipboard clobbering; repaste key-release ordering corrected (#344).
- Restore F5 finish-paste into cmux panes (#350).
- Harden `voice_ask` waveform, timeout, and capture archive (#351).
- Stream large terminal AX insertions off the main thread (#329).
- Self-contained app bundle — bundle and sign the daemon's dependencies (#328).
- Archive paired `voice_ask` artifacts and disclose the TTS receipt (#345).

## [2.1.14] - 2026-07-14

### Added
- Voice convergence batch — corpus-replay runtime verification, teleprompter
  transition receipts, and second-wave teleprompter UX specimens (#330, #338, #339).

### Fixed
- STT polish punctuation floor: question-boundary fallback hardened; declarative
  auxiliaries and embedded named clauses no longer misread as questions.
- Corpus verifier determinism, journal isolation, and process-group reaping.

## [2.1.13] - 2026-07-13

### Added
- **Socket isolation env aliases** — `VOICELAYER_SOCKET_PATH` /
  `VOICELAYER_MCP_SOCKET_PATH` (legacy `QA_VOICE_*` still honored), so a dev VoiceBar
  never collides with the resident one (#333).
- Voice UX specimens 3b + 5 — Esc stops audio; display text is decoupled from TTS
  text (#336).
- Surface STT polish degradation to the user instead of failing silently (#335).

### Fixed
- Persist the retranscription polish surface (#337).
- Route playback interrupts to the real owner (#336).

## [2.1.12] - 2026-07-12

### Fixed
- edge-tts argparse exit-2 crash and the misleading "not installed" diagnosis (#332).
- Retry truncated STT polish candidates (#331).

## [2.1.11] - 2026-07-02

### Added
- Warm the STT polish endpoint at recording start (#326).

### Fixed
- **Restore the F5 → F18 `hidutil` remap so VoiceBar dictation survives reboots**, and
  treat a missing remap as required rather than stale in relay status (#324, #325).
- Retry no-op STT polish run-ons once (#327).
- Protect VoiceBar version integrity (#323).

## [2.1.10] - 2026-06-27

### Fixed
- VoiceBar M1 waveform and timing readiness (#322).
- VoiceBar version lock and release guards; documented the M1 Homebrew transfer.

## [2.1.9] - 2026-06-26

### Fixed
- Guard VoiceBar signing against an Apple Development identity (Developer ID only, so
  TCC grants persist across upgrades) (#318).
- Fix the STT polish timeout split (#319).

## [2.1.8] - 2026-06-26

### Changed
- VoiceBar release bump only.

## [2.1.7] - 2026-06-26

### Added
- **Developer ID notarization for VoiceBar builds** — hardened runtime signed with the
  microphone entitlement, so the shipped app keeps its TCC grants (#313).
- **Voice profile SSOT** — cloned-voice profiles resolve through one authority with
  alias/identity caches invalidated on inventory changes (#314).
- **Dictation-finalizer STT polish layer** — self-correction collapse, spoken-list
  formatting, `.at`/quote fixes.
- **Settings history browser** with pagination and retranscribe feedback (#315).
- Post-merge deploy freshness checklist (`scripts/voicelayer-deploy-check.sh` + `src/deploy-check-cli.ts`, verdict logic in `src/deploy-check.ts`). Verifies that code merged to main has actually been DELIVERED to and is live on the machine: the installed `/Applications/VoiceBar.app` was rebuilt from the current `package.json` version (build provenance via the bundle's copied `Contents/Resources/package.json`), its `Info.plist` version matches, and both VoiceBar and its MCP daemon child are running from processes that are not older than the installed bundle. Fail-closed (exit 1 + per-check remedy) on any version drift / missing bundle / stale or dead process; inconclusive (exit 0) on CI / non-macOS / off-target boxes. Closes the "build-green ≠ deployed" gap (stale-app regression; "the stack didn't transfer to the M1"). CI-safe RED→GREEN gate in `src/__tests__/deploy-check.test.ts` proves the checklist catches every flavor of "not actually deployed". Docs: `docs/deploy-checklist.md`.
- Voice-profile fail-closed gate: when a cloned voice is MANDATED (`requireClonedVoice: true` option, or the `QA_VOICE_TTS_REQUIRE_CLONE=1` global switch for a render/narration wrapper), `speak()` now raises `VoiceProfileUnavailableError` instead of silently downgrading to a preset/system TTS voice — both when the requested profile is not registered and when every cloned synthesis tier fails. The short-announcement edge-tts shortcut is also skipped under a mandate. Default behavior (no mandate) keeps the resilient fallback unchanged. Exposes `assertRegisteredClone(name)` for callers. Covers the "cloned voice not used / silent system-TTS fallback" regression.
- Golden-WAV STT regression eval suite (`src/stt-golden-eval.ts` + `src/__tests__/stt-golden-eval*.test.ts`). Deterministic detectors (fabricated/non-overlapping append, dropped content, punctuation drop) with a CI-safe RED→GREEN unit gate, plus a live golden-WAV harness that builds known spoken scripts (`say` + `sox`) and runs them through the real whisper CLI backend + finalize pipeline across the single-shot and chunked paths, asserting punctuation present, no fabricated append, no large drop, and bounded decode time. Fixtures: sub-90s short-tail, >60s medium single-shot, 108s chunked (multi-chunk merge), and an opt-in 20-minute long recording (`QA_VOICE_GOLDEN_LONG=1`). Skips cleanly when whisper/`say`/`sox` are absent.

### Fixed
- VoiceBar STT: restore punctuation-rich default transcriptions. A deterministic sentence-terminal punctuation stage (`restoreSentencePunctuation`) now runs in the default finalize path, so transcripts always end with `.`/`?` even when the optional LLM polish server is unavailable (regression: "back to zero punctuation, no commas, no periods"). Conservative and protected-token-safe — never touches slash-commands, @mentions, paths, or code identifiers; yes/no aux-pronoun openers ("do you …", "should I …") are detected as questions while imperatives ("do not …") stay statements. Covered by a deterministic unit RED→GREEN plus a golden-WAV live-outcome gate (#308).
- UX convergence pass (#317): dictionary editor presented standalone without collapsing
  the pill, settings paste target preserved across self-focus, menu-bar show action
  added, pill layout reset after unhide, context-menu actions grouped, collapsed pill
  shrunk and lowered, fallback transcribing label shown.
- History retranscribe hardened (#315) — survives record races, debounced, late pastes
  suppressed, archived audio checksum and metadata kept current.
- Bound the STT polish fallback timeout; allow correction-cue rewrites.

## [2.1.6] - 2026-06-21

### Fixed
- `voicelayer update` installs the full TTS-daemon dependency set into the venv (#307).

## [2.1.5] - 2026-06-21

### Added
- **Self-completing `build-app` update** — stop, swap, relaunch with no manual hand-off
  (#304).
- **VoiceBar autostart LaunchAgent** installed by `voicelayer setup`, for reproducible
  reboot persistence (#301).

### Fixed
- The daemon refuses an orphan startup, so VoiceBar stays its sole owner (#303).
- `bar-record` claims the cross-process voice-session lock (single-recorder) (#300).
- Handle the Homebrew cask fresh-install path in `setup` (#302).

## [2.1.4] - 2026-06-20

### Added
- **Push-to-talk speech gate** — suppresses empty transcripts when no speech was
  captured (#296).
- Context-aware whisper vocabulary aliases with a capped prompt (#295).

### Fixed
- Pass the edge-tts rate as a single `--rate=` argv token (#294).

## [2.1.3] - 2026-06-19

### Fixed

- VoiceBar STT polish: allow punctuation repair for long timestamped transcripts when the polish model writes equivalent standalone number words such as `three` for `3`, while still rejecting real numeric changes.

## [2.1.2] - 2026-06-18

### Fixed

- VoiceBar STT: stop launching resident whisper-server in no-timestamps mode, which could hallucinate fluent trailing sentences on medium-length recordings; normalize timestamped segment output into a single transcript.

## [2.1.1] - 2026-06-18

### Fixed
- VoiceBar STT: reject prompt-driven hallucinations from very short final chunks while preserving real terminal speech when an unprompted decode confirms it.

## [2.1.0] - 2026-06-17

### Added
- CLI voice coaching loop (Phase 1) — 16-chunk transcription, structured coaching workflow via `voicelayer` CLI (#53)

### Changed
- **VoiceBar renamed from FlowBar** — app name, Swift source files, TypeScript references, build scripts, and docs all updated to VoiceBar (#52)
- **Architecture inversion** — VoiceBar is now the persistent server (Unix socket IPC). MCP server acts as a thin client. Removes the facade layer between Swift and TS. (#50, #51)

### Fixed
- VoiceBar: 6 Swift bug fixes + symlink safety for `/Applications/VoiceBar.app` install (#48)
- MCP server: error recovery, session booking hardening, handler tests added (#47)

## [2.0.0] - 2026-02-28

### Changed
- **Tool consolidation** — Replaced 7 individual `qa_voice_*` tools (`qa_voice_announce`, `qa_voice_brief`, `qa_voice_consult`, `qa_voice_converse`, `qa_voice_think`, `qa_voice_say`, `qa_voice_ask`) with 2 unified tools: `voice_speak` (non-blocking TTS) and `voice_ask` (blocking record + transcribe). Old `qa_voice_*` names remain as backward-compat aliases.
- **Auto-mode detection** — `voice_speak` selects announce/brief/consult/think automatically from message content (ends with `?` → consult, length > 280 → brief, starts with `"insight:"` → think, default → announce). Override with `mode` param.
- **voice_ask auto-waits** — `voice_ask` automatically awaits any in-progress `voice_speak` playback before speaking its question, eliminating audio overlap without manual coordination.
- **MCP server name** changed from `qa-voice` to `voicelayer`.
- **npm package** renamed to `voicelayer-mcp`.

### Added
- `replay_index` param on `voice_speak` — plays a cached audio entry from the ring buffer (20-entry history at `/tmp/voicelayer-history-{0-19}.mp3`).
- `enabled` toggle on `voice_speak` — enable/disable TTS and/or mic at runtime.
- Voice Bar (macOS): floating SwiftUI widget communicating via Unix socket IPC.
- Qwen3-TTS daemon for cloned voices (three-tier routing: Qwen3-TTS → edge-tts → text-only).
- CLI commands: `voicelayer extract`, `voicelayer clone`, `voicelayer daemon`, `voicelayer bar`.

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
