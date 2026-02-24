# Phase 2: Interactive Recording

> [Back to main plan](../README.md)

## Goal

Make the Voice Bar a full input device — click to record, paste transcription on stop, like Wispr Flow.

## Tools

- **Research:** Wispr Flow behavior study (how it pastes, where it focuses)
- **Code:** Claude (Swift + TypeScript)

## Steps

1. Click-to-record — tap the pill to start recording via socket command
   - New socket command: `{"cmd": "record", "mode": "vad"}`
   - MCP server handles: start `voice_ask` flow programmatically
   - Pill transitions to recording state with cancel (X) + stop (square)
2. Paste transcription on stop — insert transcribed text at cursor position
   - Use macOS Accessibility API or CGEvent to paste at current cursor
   - Or use NSPasteboard + simulated Cmd+V
   - Research: how Wispr Flow handles this (likely CGEvent key simulation)
3. Handle recording lifecycle from bar
   - Cancel (X) discards recording, returns to idle
   - Stop (square) sends to STT, shows transcribing, then pastes result
   - Transcription result event triggers paste
4. Focus-aware recording — know which app was focused when recording started
   - Store `NSWorkspace.shared.frontmostApplication` on record start
   - Paste into that app (even if focus changed during recording)
5. Visual feedback during paste — brief "Pasted!" confirmation in pill

## Depends On

- None (but Phase 1 polish is nice-to-have first)

## Status

- [ ] Click-to-record command + handler
- [ ] Paste transcription via CGEvent/Accessibility
- [ ] Recording lifecycle (cancel/stop/transcribe/paste)
- [ ] Focus-aware paste target
- [ ] Visual paste confirmation
