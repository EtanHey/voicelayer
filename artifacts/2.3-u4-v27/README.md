# V27: last row of a day no longer covered by the next day's header

Settings › History › Dictations, synthetic three-row archive (one dictation on Nov 4, two on Nov 3); the
Nov 4 row is selected, so its tint shows its full frame. Rendered by `HistoryDayBoundaryClipTests` with
`VOICEBAR_U4_SHOTS_DIR`, 900 × 700 pt window at 2×, list region cropped 1:1 (460 × 440 px, never scaled).
Host: Etan's M4, macOS 27.0, arm64, 2026-11-05.

| # | Before (2.2.61, b53ba2f2) | After |
|---|---|---|
| 1 light | `1-before-light.png`: the Nov 4 row's time line is cut by the "Nov 3, 2026" header (34 pt of a ~50 pt row visible) | `1-after-light.png`: whole row |
| 1 dark | `1-before-dark.png` | `1-after-dark.png` |

Guard: `HistoryDayBoundaryClipTests` measures the selected row's tint height in pixels; it FAILS on b53ba2f2
(34.0 pt, light and dark) and passes on this branch.
