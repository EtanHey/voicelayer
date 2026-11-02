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

The implementation realises "an entrance starts after `Delay`" with `TeleprompterPreparingHandoffGate`: the
arriving side is not mounted until the leaving side's exit plus one frame has passed. SwiftUI's delayed
insertion transitions alone did not do it (review round 2: 30 ms into preparing -> text the status was at
0.65 and the text already at 1.00; a returning status was drawn at full opacity over the fading text).

Swift guards: `TeleprompterPreparingHandoffRenderTests` mounts the real `BarView`, drives the daemon's speaking
events (both directions and a reversal before `Delay`) and samples the committed layer tree's presentation
opacity every ~4 ms: no sample shows both, the end state has no stale text, and in-flight samples prove the
sampler sees the fades. `TeleprompterPreparingHandoffTests` (timing contract, structure) is supplemental.
