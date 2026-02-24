# Phase 1: Teleprompter Polish

> [Back to main plan](../README.md)

## Goal

Fix teleprompter word tracking, replay integration, and add expanding view for full text display.

## Tools

- **Code:** Claude (Swift + TypeScript)

## Steps

1. Fix scroll anchor — current word should stay centered in view, not overflow left
   - Change `ScrollViewReader` anchor from `.leading` to `.center`
   - Test with long sentences (10+ words)
2. Replay re-triggers teleprompter — reset TeleprompterView when replay event fires
   - VoiceState needs to re-emit speaking state on replay
   - Or TeleprompterView resets when text changes to same value
3. Expanding teleprompter view — pill expands vertically to show full text
   - Smaller font (10pt instead of 12pt) for full text mode
   - Current word highlighted bold white, upcoming dimmed, past words medium opacity
   - Pill height animates from 44pt → ~70pt during speaking
   - Panel height needs to accommodate expansion
4. True word-timing estimation — improve timing model
   - Account for punctuation pauses (commas, periods add delay)
   - Adjust base rate to match edge-tts actual speech rate
5. Tests — verify teleprompter word splitting, timing estimates

## Depends On

- None

## Status

- [x] Fix scroll anchor to center (PR #28)
- [x] Replay re-triggers teleprompter (PR #28 — idle→speaking broadcast)
- [ ] Expanding teleprompter view (deferred to Phase 3)
- [x] Improved word timing — punctuation pauses (PR #28)
- [ ] Tests (deferred — timing estimation is heuristic)
