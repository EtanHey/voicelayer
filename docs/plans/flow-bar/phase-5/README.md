# Phase 5: Waveform + Visual Polish

> [Back to main plan](../README.md)

## Goal

Integrate the hero waveform animation into the pill UI and polish all visual states to look incredible.

## Research Source

`docs.local/logs/research-5-waveform.swift` — Complete WaveformView implementation with 3 modes, golden-ratio phase offsets, center-weighted bars, glow effects.

## Key Technical Decisions

- **Animation:** `TimelineView(.animation(minimumInterval: 1/60))` for 60fps
- **Bar count:** 7 bars, 6pt wide, 4pt spacing, max 28pt height, min 4pt
- **Phase offsets:** Golden ratio (`phi = 1.618...`) so bars never sync up
- **Center weighting:** Center bars taller (weight 1.0) vs edges (0.65) — natural arc
- **Idle:** Gentle breathing sine wave, barely visible (0.05 + 0.1 * breath)
- **Listening/recording:** Medium sway, waiting for speech
- **Speech detected:** Multi-frequency layers (fast 8.5Hz + medium 4.2Hz + slow 1.8Hz + pulse + jitter) — feels alive
- **Colors:** Red (#E54D4D) during recording, blue (#4A90D9) during speaking, gray (#8E8E93) idle
- **Glow:** Subtle shadow with mode-appropriate color and radius
- **Transitions:** `spring(duration: 0.3, bounce: 0.15)` between modes

## Visual Polish Targets

| State | Left | Center | Right | Background |
|-------|------|--------|-------|------------|
| idle | mic icon (gray) | "VoiceLayer" text | — | Dim vibrancy |
| speaking | play icon (blue) | waveform (shimmer) | stop button | Full vibrancy, blue tint |
| recording | red dot (pulsing) | waveform (active) | finish button | Full vibrancy, red border glow |
| transcribing | spinner | "Processing..." | — | Full vibrancy |
| error | warning (yellow) | error message | dismiss | Yellow border, auto-dismiss 3s |
| disconnected | empty circle | "Disconnected" | — | Very dim |

## Tools

- **Code:** Claude Code (Swift)
- **Preview:** Xcode SwiftUI previews

## Steps

1. Integrate `WaveformView.swift` into the project (adapt from research-5 code)
2. Connect WaveformView to VoiceState — map speaking/recording/speechDetected to WaveformMode
3. Update `BarView.swift` — replace placeholder center content with WaveformView during speaking/recording states
4. Add recording pulse animation — red dot with scale pulse (1.0 → 1.2 → 1.0, 1.5s cycle)
5. Add error auto-dismiss — 3s timer, slide-in from bottom, fade out
6. Add state transition animations — 200ms crossfade between all states
7. Polish idle state — subtle presence, "VoiceLayer" label, semi-transparent
8. Polish speaking state — blue accent, animated waveform, prominent stop button
9. Polish recording state — red accent, pulsing dot, active waveform, finish button
10. Polish transcribing state — spinner animation, brief transitional state
11. Add right-click context menu — replay last message
12. Test all visual states with mock_server.py cycling through modes
13. Screenshot/record each state for README documentation

## Depends On

- Phase 3 (SwiftUI app must exist)
- Phase 4 (socket client for state-driven animations)

## Status

- [ ] WaveformView integration
- [ ] VoiceState → WaveformMode mapping
- [ ] BarView center content update
- [ ] Recording pulse animation
- [ ] Error auto-dismiss
- [ ] State transition animations
- [ ] Idle state polish
- [ ] Speaking state polish
- [ ] Recording state polish
- [ ] Transcribing state polish
- [ ] Right-click context menu
- [ ] Visual testing with mock server
- [ ] State screenshots
