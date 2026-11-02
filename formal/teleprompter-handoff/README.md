# Teleprompter preparing handoff (R2-04)

QA 2026-11-02 recording 2, frame 183 @ 18.2 s: a faded "Preparing speech..." was
drawn over the teleprompter text. The body shows either the status or the text;
every switch removes one and inserts the other, at any tick (1/120 s), including
mid-handoff switches back. Run: `bash formal/teleprompter-handoff/check.sh`.

A view is visible while its opacity is above 0. An entrance starts after `Delay`; a
removed view stays visible for `Exit` only if it had already appeared.

| Config | Expected | Result |
| --- | --- | --- |
| Old (symmetric 0.2 s crossfade, no delay) | `NoOverlap` fails | 6 states, violated |
| Fixed (`TeleprompterPreparingHandoff`: exit 0.1 s, entry after 0.1 s + one 60 Hz frame) | PASS | 677,039 states |
| MutantNoEntry (the entering view never shows) | `NewestShows` fails | 3,093 states, violated |

Swift guard: `TeleprompterPreparingHandoffTests` (timing contract sampled per ms, and
both body branches use the handoff transition).
