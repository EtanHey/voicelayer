# X4 M1 layout candidates (not catalog goldens)

Written by `WingLayoutX4Tests` with `VOICEBAR_X4_CANDIDATES=<dir>` on the M1 (macOS 26.5.1, 25F80), 2x.

Each PNG is one right wing laid out by the production slot (`VoiceBarNotchWingSlot`) on black, without the
notch glass, at the flat-display width (`-0.0`) and the M4's 8.5 pt hardware-notch occlusion (`-8.5`; the first
8.5 pt are behind the camera housing). They show the recording row, the reading row with the teleprompter open,
and the paused reading row.

The catalog goldens (`../recording-*`, `../speaking-*`, `../paused-*`, `../teleprompter-*`, `../queue-*`,
`../busy-note-*`) could not be rendered here: this macOS paints native glass content dim in `cacheDisplay`
(`GlassTextCapability` contrast 0), and the catalog skips on a renderer mismatch anyway. The M4 re-records them
with `scripts/voicebar-snapshots.sh --record` and reviews the gallery.
