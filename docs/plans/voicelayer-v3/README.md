# VoiceLayer v3 — MCP Polish + Standalone Dictation

> Perfect the MCP experience first, then build standalone dictation to replace Wispr Flow entirely.

## Baseline

- **Tests**: 236 pass, 468 expect() calls
- **PRs merged**: #43 (word timestamps), #44 (paste fix), #45 (cleanup)
- **Voice Bar**: Dynamic sizing, karaoke sync, socket discovery, paste-on-record
- **v2 phases done**: 1-3 (teleprompter, recording, visual polish)
- **v2 phases pending**: 4 (live dictation), 5 (production readiness)

---

## Progress

| # | Phase | Folder | Status | PR | Checkpoint |
|---|-------|--------|--------|----|------------|
| 1 | MCP Sweep | [phase-1](phase-1/) | **DONE** | [#47](https://github.com/EtanHey/voicelayer/pull/47) | MCP tools work flawlessly end-to-end |
| 2 | Voice Bar Hardening | [phase-2](phase-2/) | **in progress** | — | Zero bugs in daily use for 1 week |
| 3 | Standalone Daemon | [phase-3](phase-3/) | pending | — | `voicelayer serve` runs without Claude Code |
| 4 | Global Hotkeys | [phase-4](phase-4/) | pending | — | Option+Space hold/double-tap, configurable |
| 5 | Batch STT Engine | [phase-5](phase-5/) | pending | — | whisper small.en default, large-v3-turbo upgrade |
| 6 | Dev-Aware Post-Processing | [phase-6](phase-6/) | pending | — | camelCase/snake_case commands, punctuation aliases |
| 7 | Integration + Production | [phase-7](phase-7/) | pending | — | SMAppService, first-run setup, metrics, production build |
| 8 | LLM Correction (v2) | [phase-8](phase-8/) | pending | — | Optional Llama 3.2 1B pass for ambiguity |
| 9 | Context-Aware Prompts (v2) | [phase-9](phase-9/) | pending | — | Active app detection, IDE vs chat modes |

---

## Phase Details

### Phase 1: MCP Sweep
**Goal**: Every MCP tool (`voice_speak`, `voice_ask`) works perfectly. Fix edge cases, stale state, error recovery.

- [ ] Audit all MCP tool handlers — test each mode (announce, brief, consult, converse, think, replay, toggle)
- [ ] Fix any stale state bugs (e.g., stuck in "recording" after error)
- [ ] Verify `voice_ask` auto-waits for playback to finish
- [ ] Test TTS three-tier routing: Qwen3 -> edge-tts -> text-only
- [ ] Session booking: verify lock/unlock, stale lock cleanup
- [ ] Update MCP tool descriptions and parameter docs
- [ ] Test count target: maintain or increase from 236

**Depends on**: nothing
**Audit**: Run full test suite + manual MCP tool exercise

### Phase 2: Voice Bar Hardening
**Goal**: Voice Bar is rock-solid for daily MCP use — no crashes, no disconnects, no visual glitches.

- [ ] Fix any remaining paste issues (test across iTerm2, VS Code, Chrome, Slack)
- [ ] Handle MCP server restart gracefully (discovery watcher + auto-reconnect verified)
- [ ] Voice Bar auto-launch: verify PR #42 works after fresh `npm install`
- [ ] Error states: show meaningful messages, auto-recover to idle
- [ ] Memory/CPU profile: Voice Bar should idle at <30MB, <1% CPU
- [ ] Test collapsed pill: 5s idle -> collapse -> expand on any state change
- [ ] Verify dynamic panel sizing doesn't jitter on rapid state changes

**Depends on**: Phase 1
**Audit**: 1 week of daily use, log errors, fix any issues found

### Phase 3: Standalone Daemon
**Goal**: `voicelayer serve` starts the socket server + recording pipeline without MCP/Claude Code.

- [ ] New entry point: `src/daemon.ts` — starts socket server, handles commands, writes discovery file
- [ ] Reuse: `socket-server.ts`, `input.ts`, `stt.ts`, `vad.ts`, `session-booking.ts`, `paths.ts`
- [ ] No MCP dependencies — no `@modelcontextprotocol/sdk` imports
- [ ] CLI command: `voicelayer serve [--port N]` (default: socket only, optional HTTP for health check)
- [ ] Graceful shutdown: SIGINT/SIGTERM -> cleanup sockets, discovery file, stop recordings
- [ ] Coexistence: daemon detects if MCP server is already running (check discovery file PID)
- [ ] Voice Bar connects to daemon OR MCP server transparently (same socket protocol)

**Depends on**: Phase 2
**Research needed**: None — architecture already proven standalone-capable
**Test**: `voicelayer serve &` -> click Voice Bar -> record -> paste

### Phase 4: Global Hotkeys (CGEventTap)
**Goal**: Configurable hotkeys work system-wide, including fullscreen apps.

- [ ] CGEventTap in Voice Bar process (AppDelegate) — `.defaultTap` to consume hotkey
- [ ] Default: Globe (Fn) hold = push-to-talk, double-tap Globe = toggle, Ctrl+Shift+V = re-paste
- [ ] User-configurable hotkeys in `~/.voicelayer/config.yaml` (F5, Option+Space as alternatives)
- [ ] Double-tap detection (~300ms window)
- [ ] Input Monitoring permission check on startup (alongside Accessibility)
- [ ] Visual feedback: pill animates immediately on keypress (optimistic UI)
- [ ] Coexistence: when Claude MCP is active, hotkeys still work (daemon handles both)

**Depends on**: Phase 3
**Can parallelize with**: Phase 5, Phase 6 (independent codebases)
**Research**: Gemini research #1 covers CGEventTap patterns, key hold detection, double-tap timing
**Audit**: Test in fullscreen apps, Electron apps, Terminal, web browsers

### Phase 5: Batch STT Engine
**Goal**: Fast, accurate local transcription using whisper large-v3-turbo.

- [ ] whisper.cpp with CoreML acceleration (ANE on Apple Silicon)
- [ ] Model management: auto-download large-v3-turbo on first use, progress UI
- [ ] First-run CoreML compilation (~15 min) with progress notification
- [ ] Batch transcription: record -> stop -> transcribe -> paste. Target: <1.5s for 10s clip
- [ ] Configurable model selection (small.en for speed, large-v3-turbo for accuracy)
- [ ] `--initial-prompt` with dev vocabulary (~224 tokens) for better code term recognition
- [ ] Benchmark: compare WER and latency vs current whisper-cli setup

**Depends on**: Phase 3
**Can parallelize with**: Phase 4, Phase 6 (independent codebases)
**Research**: Gemini research #1 (STT model comparison), Claude research (CoreML latency benchmarks)

### Phase 6: Dev-Aware Post-Processing
**Goal**: Transcribed text is developer-ready — proper casing, punctuation, code terms.

- [ ] Stage 1 — Rule-based pipeline (<5ms):
  - Spoken punctuation: ~50 mappings ("open paren" -> `(`, "semicolon" -> `;`, "arrow" -> `=>`)
  - Case formatting commands: "camel case foo bar" -> `fooBar`, "snake case" -> `foo_bar`
  - Filler removal: "um", "uh", "like", "you know"
  - Auto-capitalization after sentence boundaries
  - Number formatting: "forty two" -> `42`
- [ ] Config file: `~/.voicelayer/aliases.yaml` for custom user aliases
- [ ] Tech vocabulary: ~500 common dev terms ("use effect" -> `useEffect`, "type script" -> `TypeScript`)
- [ ] Reference: Talon Voice + Serenade voice coding vocabularies

**Depends on**: Phase 3
**Can parallelize with**: Phase 4, Phase 5 (pure text transforms, no Swift/STT deps)
**Research**: Gemini research #2 (voice coding vocabularies, text expansion patterns)

### Phase 7: Launch at Login + Production Build
**Goal**: VoiceLayer starts automatically, runs as a proper macOS citizen.

- [ ] `SMAppService.mainApp.register()` for launch at login (macOS 13+)
- [ ] Proper code signing (Developer ID) so Accessibility/Input Monitoring permissions persist
- [ ] `LSUIElement = YES` in Info.plist (no Dock icon)
- [ ] First-run setup flow: permission prompts, model download, alias config
- [ ] Menu bar: status, preferences, quit
- [ ] Homebrew formula or npm global install: `npm i -g voicelayer`
- [ ] Uninstall: `voicelayer uninstall` removes login item, caches, config

**Depends on**: Phase 6
**Research**: Gemini research #1 (SMAppService vs LaunchAgent comparison)

### Phase 8: LLM Correction (v2)
**Goal**: Optional local LLM pass for ambiguous transcriptions.

- [ ] Llama 3.2 1B via MLX (Q4_K_M), ~400ms on M1 Pro
- [ ] User toggle: "fast mode" (rules only) vs "smart mode" (rules + LLM)
- [ ] LLM handles: context correction, "no wait" edits, ambiguous homophones
- [ ] Falls back to rules-only if LLM unavailable or slow

**Depends on**: Phase 7
**Defer until**: v1 is shipping and daily-driven

### Phase 9: Context-Aware Prompts (v2)
**Goal**: Adjust transcription based on active app.

- [ ] `NSWorkspace.frontmostApplication` -> bundle ID detection
- [ ] IDE mode (VS Code, Xcode, Cursor): code-heavy initial prompt
- [ ] Chat mode (Slack, Telegram, iMessage): natural language prompt
- [ ] Terminal mode: command-heavy prompt
- [ ] Custom per-app profiles in `~/.voicelayer/contexts/`

**Depends on**: Phase 8
**Defer until**: v2

---

## Execution Rules

Same as v2:
1. Each phase = one branch = one PR
2. Branch naming: `feat/v3-phase-N-<name>`
3. Full PR loop: push -> CI -> review -> triage -> fix -> merge
4. Tests must pass + Swift build clean before push
5. Update this table after each phase completes
6. Telegram notification at each checkpoint

## Quality Gates

| Gate | When | What |
|------|------|------|
| **MCP Perfect** | After Phase 2 | All MCP tools work flawlessly, Voice Bar stable for 1 week |
| **Standalone MVP** | After Phase 5 | Dictation works without Claude Code, F5 hotkeys, batch STT |
| **Wispr Replacement** | After Phase 7 | Can quit Wispr Flow permanently, launch at login, dev formatting |
| **Full v2** | After Phase 9 | LLM correction, context-aware, production-grade |

## Cross-Phase Knowledge

- Socket protocol: `src/socket-protocol.ts`
- Theme tokens: `flow-bar/Sources/FlowBar/Theme.swift`
- MCP instructions: `src/mcp-tools.ts`
- Voice Bar state: `flow-bar/Sources/FlowBar/VoiceState.swift`
- Research: digested into BrainLayer (tag: `voicelayer standalone-dictation`)
- Gemini research #1: macOS APIs, global hotkeys, STT models, launch-at-login
- Gemini research #2: dev-aware transcription, voice coding, text expansion
- Claude research: architecture decisions, daemon design, v1 feature set
