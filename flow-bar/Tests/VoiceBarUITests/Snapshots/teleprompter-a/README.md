# U5 Teleprompter A frames

Opt-in receipt from `TeleprompterAShotsTests`, recorded 2026-11-05 on the M1 Pro (MacBookPro18,3, macOS 26.5.1 build 25F80).
Re-recorded 2026-11-08 on the same M1 for T2 (first-line, 3-line, 8-line, queued-2): only the footer label changed; paused is unchanged.
These are review frames, not a pixel-compared catalog: the catalog under `Snapshots/` stays M4-recorded.

Regenerate: `VOICEBAR_U5_SHOTS_DIR=<dir> swift test --package-path flow-bar --filter TeleprompterAShotsTests` (heavy.sh on the M1).

Offscreen `TeleprompterAView` with synthetic text, a 300 ms/word `speech_words` table and a fixed clock, at 2×. It never opens audio or the installed app.
The light frames use the contrast suite's light-glass backdrop; the dark frames sit on notch black.

| Frame | Shows |
| --- | --- |
| first-line | reading starts flush on line 1; no top fade |
| 3-line | focus held in the middle row after scrolling; top fade present |
| 8-line | handle-extended panel; the focus row is the middle (row 4); nothing scrolled yet |
| paused | footer "Paused"; tiers unchanged; words are inert |
| queued-2 | footer "1×" (T2: the redundant "Reading ·" is gone) plus the "+2 queued" chip |

Contrast (`contrast.md`, asserted by `testContrastTable`): spoken and read ink, and the footer, are ≥ 4.5:1 on every backdrop. **Unread 36 % ink is below 4.5:1** (2.16–2.96:1). That is the SPEC value as built, and it is raised as an open question for the lead.
