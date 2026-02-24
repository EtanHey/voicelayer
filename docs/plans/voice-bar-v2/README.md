# Voice Bar v2 — Full Wispr Flow Replacement

> Replace Wispr Flow entirely: click-to-record, live dictation, expanding teleprompter, and native macOS polish.

## Context

Voice Bar v1 (PRs #20–#27) delivered:
- Floating dark pill with state indicators
- Teleprompter word-by-word highlighting during TTS
- Cancel/stop buttons, replay, waveform animations
- Mouse tracking across screens, SwiftFormat CI

v2 makes it a full Wispr Flow replacement — the user can unsubscribe from Wispr Flow after this.

---

## Progress

| # | Phase | Folder | Status | PR | Notes |
|---|-------|--------|--------|----|-------|
| 1 | Teleprompter Polish | [phase-1](phase-1/) | done | #28 | Scroll anchor, replay, punctuation timing, wider view |
| 2 | Interactive Recording | [phase-2](phase-2/) | done | #29 | Click-to-record, paste via CGEvent Cmd+V |
| 3 | Visual Polish & UX | [phase-3](phase-3/) | in-progress | — | Audio waveform, drag, idle collapse, expanding teleprompter |
| 4 | Live Dictation | [phase-4](phase-4/) | pending | — | Streaming STT — needs Etan present |
| 5 | Production Readiness | [phase-5](phase-5/) | pending | — | Launch at login, center position, cleanup |

---

## Execution Rules

Each phase = one branch = one PR. See `/large-plan` skill for the full protocol.

1. Branch: `feat/voice-bar-v2-phase-N`
2. PR loop: push → wait for Bugbot → fix comments → merge
3. **Never merge without checking review comments**
4. Tests must pass (`bun test`) + Swift build clean before push
5. Update this table after each phase completes

## Dependencies

- Phase 4 requires Etan present (whisper-server compile + mic testing)
- Phase 4 booked: Wed Feb 25, 09:00–11:00
- All other phases can run autonomously

## Cross-Phase Knowledge

Update this section as phases complete:
- Design system: `memory/voice-bar-design-system.md`
- Socket protocol: `src/socket-protocol.ts` (commands + events)
- Theme tokens: `flow-bar/Sources/FlowBar/Theme.swift`
- NSPanel quirks: FB16484811 (nonactivatingPanel must be in init styleMask)
