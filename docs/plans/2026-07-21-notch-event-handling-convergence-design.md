# VoiceBar Notch Event-Handling Convergence Design

**Status:** Approved by the autonomous `notch-363c-eventhandling` boot brief.

## Problem and root cause

The product window currently uses `VoiceBarNotchHitRegion`, the full rendered glass path, as the predicate for SwiftUI hosting hits, hover expansion, panel drags/context menus, and `NSPanel.ignoresMouseEvents`. This solved transparent window-corner interception, but it still classifies every visible wing pixel and the whole teleprompter body as interactive. The result is a large invisible input surface around the glyphs and above the terminal.

The recording actions also occupy the same right-side menu-bar band as macOS screen-recording and microphone indicators. The refined click-visible QA frames confirm repeated clicks clustered on the macOS screen-recording STOP around x2140. In the affected recording presentation, VoiceBar's own stop was not prominent enough to read as the intended target beside the red waveform and cancel glyph. Because both applications draw black chrome in the same band, intent cannot be recovered after the controls overlap; VoiceBar needs its own prominent stop affordance away from the OS band.

Waveforms already share the same renderer, but not the same placement contract. Recording adds internal padding, transcribing reserves a leading invisible control, and speaking uses the teleprompter fade inset. Those independent spacers produce different core-to-waveform gaps.

## Considered approaches

1. **Exact interaction geometry plus control relocation — selected.** Keep the visible continuous-glass architecture, add a separate state-driven interaction-region model containing only mounted 20-point controls, retain a distinct hover/core region for launcher discovery, and move recording actions to the leading wing while leaving the waveform first in the trailing wing. This makes pass-through deterministic and removes the right-side OS overlap.
2. **Only reduce the existing glass path.** Insets or clips would reduce accidental capture, but any shape-based region would still treat visual-only glass and the teleprompter body as interactive. It also cannot resolve two controls occupying the same screen coordinates.
3. **Report live SwiftUI button frames back to AppKit.** Anchor preferences could provide exact runtime frames, but they arrive asynchronously during morphs and would create a second mutable geometry channel at the event boundary. The controls use fixed contract sizes and spacing, so a pure layout model is safer and directly testable.

## Selected architecture

`VoiceBarNotchHitRegion` becomes an interaction contract instead of a rendered-surface contract. It receives the immutable notch presentation plus a small `VoiceBarNotchInteractionConfiguration` derived from `VoiceState`. Its rectangles are the exact mounted control frames: launcher mic/history/dictionary, recording hold/cancel/stop, compact-state actions, and the centered teleprompter control row. Waveforms, status glyphs, text, glass, shadows, and empty padding never enter the click region.

`VoiceBarPanelLayout` exposes three independent questions:

- `containsInteractiveContent`: may this click/right-click reach VoiceBar?
- `containsHoverExpansion`: is the pointer on the hardware core or a real launcher/control glyph?
- `containsHoverRetention`: may an already-open launcher remain open briefly while crossing the small inter-control gaps?

The hosting view, panel context menu/drag gate, and `NSPanel.ignoresMouseEvents` use only `containsInteractiveContent`. Global pointer observation continues to drive hover without requiring the panel to capture the pointer. Retained-readback dismissal uses visible-surface/retention geometry, not the click predicate. The `.nonactivatingPanel` style and no-`makeKey` behavior remain unchanged.

Recording keeps its red waveform immediately to the right of the fixed hardware core. A prominent red VoiceBar stop, cancel, and optional hold move into a leading-wing action group, away from macOS screen recording, the Control Center microphone indicator, and neighboring menu extras. The stop remains the existing destructive red-circle/white-square treatment but is now spatially unmistakable as part of VoiceBar's screen-left action group. PTT omits hold without leaving a hittable placeholder. The existing continuous material, fixed black core, and morph sequencing remain intact.

The rendered layout and hit rectangles use the same formulas (`controlSize = 20`, compact control spacing `= 6`, leading core inset `= 13.5`, leading outer inset `= 14`, shared waveform core gap `= 24`, waveform viewport `= 46`, waveform outer inset `= 8`):

| State | Screen-left → screen-right content | Geometry and control centers relative to the hardware core | Right-side OS clearance |
|---|---|---|---|
| VAD recording | stop, cancel, hold · core · waveform | leading wing `14 + 3×20 + 2×6 + 13.5 = 99.5pt`; hold/cancel/stop centers are `23.5/49.5/75.5pt` left of `core.minX`; trailing wing `24 + 46 + 8 = 78pt`; waveform begins `24pt` right of `core.maxX` | no interactive rectangle exists right of the core; the visual-only wing ends about 27 capture pixels before the observed mic-indicator center and about 59 pixels before the screen-recording stop band on the accepted 2× fixture |
| PTT recording | stop, cancel · core · waveform | leading wing `14 + 2×20 + 6 + 13.5 = 73.5pt`; cancel/stop centers are `23.5/49.5pt` left of `core.minX`; the 78pt waveform wing is unchanged | same; no stale/invisible hold rectangle is permitted |
| Transcribing | spinner · core · waveform, cancel | waveform begins `24pt` right of `core.maxX`; cancel center is `24 + 46 + 6 + 10 = 86pt` right of `core.maxX`; trailing wing is `24 + 46 + 6 + 20 + 8 = 104pt` | only the visible cancel glyph is interactive; waveform and surrounding glass pass through |
| Teleprompter | no leading dictionary · core · waveform; centered lower controls | top waveform begins `24pt` right of `core.maxX`; for `N` lower controls, row width is `N×20 + (N−1)×10`, first center is `body.midX − rowWidth/2 + 10`, and AppKit-local center Y is `14 + 10 = 24pt` | top wings and body are noninteractive; only the mounted replay/eye/stop/dismiss rectangles capture |

The table is the source for both SwiftUI ordering/wing widths and `VoiceBarNotchHitRegion`; tests fail if those two representations drift.

The teleprompter dictionary button is removed from the leading wing and from the teleprompter content-role contract. The idle-hover dictionary and its popover remain unchanged. The visual continuous-glass body remains; its text and empty surface are click-through, while the real bottom controls remain interactive.

## Shared waveform contract

Add one state-driven notch waveform component for recording, transcribing, and speaking. It owns the renderer mode/color/truth source and a single `coreGap`/viewport contract. Every waveform is the first trailing-wing element. Remove recording-only padding and the transcribing invisible leading control. Geometry reserves the same core-to-waveform gap in all three states; state changes affect signal/color only.

## Verification design

- Pure interaction-region tests prove every mounted glyph center hits, points immediately below/beside each glyph pass through, the old glass-only wing/body points pass through, and teleprompter controls remain clickable.
- Negative state tests prove PTT has no hold target, teleprompter has no dictionary target, and controls omitted by state/configuration leave no placeholder rectangle.
- Transition tests switch recording → transcribing → teleprompter → idle and prove the prior state's rectangles disappear before the destination accepts clicks, including a stationary-pointer case at the old recording stop coordinate.
- App lifecycle tests prove the panel toggles `ignoresMouseEvents` from exact interaction geometry and remains nonactivating.
- Offscreen `NSHostingView` click tests exercise hold/cancel/stop, compact controls, and teleprompter actions with real AppKit mouse events.
- Render tests compare core-relative waveform bounds across recording, transcribing, and speaking and verify the teleprompter no longer mounts a dictionary control while idle-hover still does.
- Full Swift and Bun suites, the corpus/runtime verifier, existing material/morph/readability gates, an exact-head isolated Developer-ID/notarized app, and offscreen pixel inspection guard the sacred merged behavior.

The resident `/Applications/VoiceBar.app` is never stopped, replaced, or relaunched by this branch. All app artifacts use unique sockets/defaults and an explicit offscreen location; teardown targets only the captured QA PID and deregisters the isolated instance.
