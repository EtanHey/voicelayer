# Phase 1 Findings

## Decisions

- [13:50] Scroll anchor `.center` instead of `.leading` — keeps current word visible
- [13:50] Replay fix goes in `mcp-server.ts` not Swift — broadcast speaking state before playing audio
- [13:50] Word timing: punctuation adds pauses (. ! ? = +150ms, , ; : = +80ms)
- [13:55] Expanding teleprompter: wider view (220pt) + smaller font (11pt) for Phase 1. Full vertical expansion deferred to Phase 3.

## Research

- [13:45] Replay flow: `case "replay"` → `getHistoryEntry(0)` → `playAudioNonBlocking()`. Missing: no speaking broadcast before play. History entry has `.text` with original message.
- [13:45] Speaking broadcast truncates text to 200 chars (line 319 of tts.ts). Fine for teleprompter.

## Task Board

| Task | Owner | Status |
|------|-------|--------|
| Fix scroll anchor to center | claude | done |
| Replay broadcasts speaking state | claude | done |
| Punctuation-aware word timing | claude | done |
| Wider teleprompter (220pt, 11pt font) | claude | done |
| Full vertical expansion | — | deferred to Phase 3 |

## Notes

- `playAudioNonBlocking()` already broadcasts idle when playback finishes (via `.exited` callback). So replay flow is: broadcast speaking → play audio → (auto) broadcast idle.
