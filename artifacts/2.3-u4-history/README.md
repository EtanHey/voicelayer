# U4: History morph B, 2-line × 7 rows, extend handle to 12, row click, clipped-row tooltip

Synthetic dictations only. Rendered offscreen from the real `BarView` (`NotchHistoryMorphShotsTests`, and the
same cases on 2.2.61 b53ba2f2 for "before") with `VOICEBAR_U4_SHOTS_DIR`, at 2×, never scaled.
Host: Etan's M4, macOS 27.0, arm64, 2026-11-05.

## Numbered before/after pairs (fixed capture: 954 × 800 px, top-aligned crop)

| # | State | Before (2.2.61) | After |
|---|---|---|---|
| 1 | Closed launcher (hovered notch) | `1-before-closed-launcher-{light,dark}.png` | `1-after-…` |
| 2 | History open | `2-before-open-…`: 320 pt panel, wrapped rows, the last visible row cut mid-line, footer prose | `2-after-open-…`: 420 pt, seven 46 pt two-line rows, grip under the last row, no footer |
| 3 | Hovered row | `3-before-row-hover-actions-…` | `3-after-row-hover-actions-…`: Copy / Paste / Transcribe again at the right, same frame as the pointer |

## After-only states (full canvas)

`after-2-opening-p015` · `after-3-midway-p050` · `after-4-rows-arriving-p080` (morph B frozen at progress 0.15 / 0.5 / 0.8:
rows scale from 0.8 at the top edge, blur 20 → 0, fade in after 30 %) · `after-5-overshoot-p104` (the open spring's
overshoot) · `after-8-scroll-indicator` (4 pt thumb, only while scrolling) · `after-9-extended-10-rows` ·
`after-10-extended-12-rows` (V6: the handle settled at 10 and 12 rows). Light and dark each.

## Contrast (`contrast-notch.json`)

Palette text colour alpha-composited over the rendered panel background pixel; threshold 4.5:1.

| Appearance | Text | On row | On hovered row |
|---|---|---|---|
| light | primary (dictation) | 16.60 | 14.01 |
| light | tertiary (when · length) | 7.43 | 6.74 |
| dark | primary | 15.77 | 12.32 |
| dark | tertiary | 9.27 | 7.65 |

## Motion and interaction proof

Static frames cannot show motion. The morph is proven by `formal/history-pull` (TLC: Fixed PASS 1236 states;
six mutants fail on their invariants) and `NotchHistoryMorphTests` (springs, retargeting, rubber band, snap).
The live drag, snap, click-is-not-a-drag, Esc and reopen-at-height path is `U4NotchHistoryNativeTests`
(UIE2E): native run pending on the M1 test rig (pointer events are not allowed on the M4).
