# Phase 3: Visual Polish & UX

> [Back to main plan](../README.md)

## Goal

Polish the pill UX with audio-responsive waveform, idle collapse, draggable positioning, and smooth animations.

## Tools

- **Research:** Wispr Flow UX patterns, macOS drag APIs
- **Code:** Claude (Swift)

## Steps

1. Expanding teleprompter — pill grows vertically during agent speech
   - Pill height animates from 44pt → ~80pt when speaking with text
   - Show 2-3 lines of text, current word highlighted, past lines fade
   - Panel height must accommodate expansion
   - Collapse back to 44pt when speaking ends
   - Different from user dictation (Phase 4) — agent speech shows full readable text
2. Audio-level driven waveform — replace shimmer with real RMS levels
   - New socket event: `{"type": "audio_level", "rms": 0.42}`
   - Emit from `src/input.ts` during recording (already have RMS from VAD)
   - Emit from `src/tts.ts` during speaking (estimate from audio analysis)
   - WaveformView reads RMS to drive bar heights
3. Idle collapse — pill shrinks after inactivity
   - After 5s idle: collapse to small dot + green indicator only (~40pt wide)
   - On hover: expand back to full pill smoothly
   - On any state change: expand immediately
   - Wispr Flow reference: collapses to ~30pt circle after inactivity
4. Draggable pill position + persistence
   - `.gesture(DragGesture())` on the pill
   - Save position to `UserDefaults` (x offset as percentage)
   - Load on launch, fall back to `Theme.horizontalOffset`
   - Constraint: keep within screen bounds
5. Smooth width transitions between states
   - Currently `.fixedSize()` causes instant width changes
   - Add `.animation(.smooth(duration: 0.3))` on the frame
   - Test all state transitions for jank
6. Haptic/sound feedback on button press
   - `NSHapticFeedbackManager` on stop/cancel/replay clicks
   - Subtle, not annoying

## Depends On

- None

## Status

- [x] Expanding teleprompter (vertical, 2-3 lines for agent speech)
- [x] Audio-level waveform (protocol + Swift + TS emission during recording)
- [x] Idle collapse with hover expand
- [x] Draggable positioning + UserDefaults persistence (via isMovableByWindowBackground + didMove observer)
- [x] Smooth width animation
- [x] Haptic feedback on buttons
