# Phase 2: State Emission

> [Back to main plan](../README.md)

## Goal

Wire state events into all VoiceLayer integration points so every voice action broadcasts its state to connected Flow Bar clients.

## Key Technical Decisions

- **Emit points:** Each state change calls `broadcast()` from `socket-server.ts`
- **State machine:** `idle → speaking → idle` (voice_speak), `idle → speaking → recording → transcribing → idle` (voice_ask)
- **Speech events:** Fire during `recording` state only, `true`/`false` as VAD processes chunks
- **Speaking end:** Detected when afplay process exits (non-blocking TTS) or speak() returns (blocking)
- **Lightweight:** Just import `broadcast` and call it at the right points. No refactoring of existing code.

## Emission Points

| File | Location | Event |
|------|----------|-------|
| `src/tts.ts` | `speak()` start | `{"type": "state", "state": "speaking", "text": "...", "voice": "..."}` |
| `src/tts.ts` | `playAudioNonBlocking()` process exit | `{"type": "state", "state": "idle"}` |
| `src/input.ts` | `recordToBuffer()` start | `{"type": "state", "state": "recording", "mode": "vad"|"ptt"}` |
| `src/input.ts` | VAD chunk loop — speech detected | `{"type": "speech", "detected": true}` |
| `src/input.ts` | VAD chunk loop — silence after speech | `{"type": "speech", "detected": false}` |
| `src/input.ts` | `recordToBuffer()` finish | `{"type": "state", "state": "transcribing"}` |
| `src/stt.ts` or `src/input.ts` | After transcription complete | `{"type": "state", "state": "idle"}` + `{"type": "transcription", "text": "..."}` |
| `src/mcp-server.ts` | Error catches | `{"type": "error", "message": "...", "recoverable": bool}` |

## Command Handlers

| Command | Action |
|---------|--------|
| `stop` | Write `/tmp/voicelayer-stop` (reuses existing stop mechanism) + `pkill afplay` |
| `replay` | Call `playAudioNonBlocking(getHistoryEntry(0))` from tts.ts |
| `toggle` | Write/delete flag files (`/tmp/.claude_tts_disabled`, `/tmp/.claude_mic_disabled`) |

## Tools

- **Code:** Claude Code (Bun/TypeScript)
- **Tests:** `bun test`

## Steps

1. Read `src/tts.ts`, `src/input.ts`, `src/stt.ts`, `src/mcp-server.ts` to identify exact insertion points
2. Write tests: mock broadcast, trigger voice_speak → assert speaking/idle events emitted
3. Write tests: mock broadcast, trigger voice_ask → assert speaking/recording/speech/transcribing/idle events
4. Add `broadcast()` calls to `src/tts.ts` — speaking start + idle on playback end
5. Add `broadcast()` calls to `src/input.ts` — recording start + speech detected + transcribing + idle
6. Add error event broadcasts to `src/mcp-server.ts` error handlers
7. Implement command handlers in `socket-server.ts` → `handleCommand()`: stop, replay, toggle
8. Write tests for command handlers (stop creates file, replay plays audio, toggle writes flags)
9. Verify existing 116 tests still pass (no regressions from broadcast calls)

## Depends On

- Phase 1 (socket server must exist for `broadcast()` import)

## Status

- [ ] Read and map all emission points in existing code
- [ ] Tests for speak event emission
- [ ] Tests for voice_ask event sequence
- [ ] Broadcast calls in `tts.ts`
- [ ] Broadcast calls in `input.ts`
- [ ] Error broadcasts in `mcp-server.ts`
- [ ] Command handlers (stop, replay, toggle)
- [ ] Command handler tests
- [ ] Regression check (all existing tests pass)
