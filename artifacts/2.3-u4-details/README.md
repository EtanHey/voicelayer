# Recording details: visible close, folded re-transcribes, "No change: same text"

Synthetic take, 20 identical Re-transcribe requests (each returned the same words). Rendered by
`SettingsHistoryDetailsShotsTests` with `VOICEBAR_U4_SHOTS_DIR`, 552 pt wide at 2×, 1:1 (never scaled).
Host: Etan's M4, macOS 27.0, arm64, 2026-11-05.

| # | State | Files |
|---|---|---|
| 1 | Open details: × at the header's trailing edge (Esc closes); one "Re-transcribed ×20 · 09:34–09:37 · No change: same text" row | `1-folded-light.png`, `1-folded-dark.png` |
| 2 | The folded row opened: every request, indented, oldest first | `2-folded-open-light.png`, `2-folded-open-dark.png` |

Before (2.2.61): the same take listed 20 separate "Retry · New text received" rows and no close control
other than the chevron (Etan's 01:44Z recording; not re-rendered here).

Contrast (darkest glyph pixel vs card): dark 5.65:1. Light 3.90:1 for the system `.secondary` text
(log times, outcomes, fact labels). That colour is unchanged from 2.2.61 and used across the whole panel;
reported to the captain as a History-window finding, not changed here.
