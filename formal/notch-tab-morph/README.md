# Notch tab morph (N1)

How `VoiceBarNotchView` turns presented geometry changes into shell springs, so the
note tab drops straight down from under the notch instead of sweeping a wing-wide
slab inward. Run from the repository root: `bash formal/notch-tab-morph/check.sh`
(shared fail-closed runner `formal/check-model.py`, TLC 2.19, one worker, seed 1).

Updates are batches: between updates the presentation may change any number of times;
an update runs each changed value's `onChange` with that update's value, in either
order. A bodiless body is invisible, so `Rest` and `RestTab` draw the same shell.

| Config | Expected | Result |
| --- | --- | --- |
| Old (spring straight to the presented geometry) | `NoSlabSweep` fails | 15 states, violated |
| Async (snap, then a `DispatchQueue.main.async` spring whose write is dropped) | `SettlesOnPresented` fails | 15 states, violated |
| Unguarded (chained `onChange`, no stale-target guard) | `NoSlabSweep` fails | 101 states, violated |
| Fixed (chained `onChange`, guarded by presented geometry and snapped start) | PASS | 492 states, 297 distinct |

The Async mode is the first implementation tried in this lane: a render test showed
the tab never grew (writes from the escaping closure were dropped). A probe with only
the presented-geometry guard also passes (492 states); the code carries both guards.
This is a bounded abstraction of event order, not of spring physics or rendering.
