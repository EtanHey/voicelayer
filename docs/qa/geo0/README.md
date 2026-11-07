# GEO0: stable Replay and Hide targets

Status: offscreen source proof; installed/native acceptance is not claimed.

The speaking row reserves the exact terminal X control, with `.hidden()`,
no hit testing, no keyboard focus, no accessibility element and no tooltip registration. Stop
remains in the speaking wing. No recording, F5, playback or speech logic changes.

## Regression proof

`TeleprompterControlGeometryTests` hosts the real `BarView` in an isolated
nonactivating offscreen panel. It measures AX frames in host coordinates across
speaking → readback → replaying, with the production presentation model's reduced
motion setting off/on. No system accessibility preference is changed.

| Frame minX (points) | Base 317245d8 | Fixed |
| --- | --- | --- |
| Replay, speaking → readback | 219.5 → 204.5 | 204.5 → 204.5 |
| Hide, speaking → readback | 249.5 → 234.5 | 234.5 → 234.5 |

Tolerance: 0.5 pt. Terminal size: 20 × 20 pt. The test rejects any AX leaf in
that slot. Local mouse events test the slot and neighbouring Eye; a process-local
haptic recorder detects button action entry even if its command would no-op.
No global event is posted, no pointer is moved, no physical feedback is emitted.

## Images

| State | Before | After |
| --- | --- | --- |
| Speaking | [before](before-speaking.png) | [after](after-speaking.png) |
| Readback | [before](before-readback.png) | [after](after-readback.png) |

These are synthetic native fixed-canvas captures, not browser breakpoints.

Only `teleprompter-expanded-dark.png` and `teleprompter-expanded-light.png`
required new catalog references: Replay/Eye shift left 15 pt into their readback
positions. Dark: 333 changed pixels; light: 244 (channel threshold >16).
[Dark diff](catalog-dark-diff.png) · [Light diff](catalog-light-diff.png).
All other catalog references remain unchanged.

The existing `NotchIconButtonTooltipTests.testSpeakingButtons` also guards the
focus loop: the initial opacity-only candidate failed with an extra bare
`KeyViewProxy`. Using `.hidden()` removes that focus target while keeping its size.
