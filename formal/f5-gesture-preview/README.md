# F5 gesture preview timing

The logical gesture still publishes pressing on key-down, awaiting-second-tap on
short release, holding at 160 ms, and lock on a second press within 400 ms.
VoiceState uses that immediate phase for selection admission/cancellation and
quit safety. Only the phase consumed by the status label and notch layout is delayed.

Named presentation policy: pressing grace 120 ms, awaiting grace 350 ms, minimum
meaningful visibility 150 ms. Preview begins strictly after the grace and only
when at least 150 ms remains before the phase's normal resolution. The timer
rechecks remaining time at dispatch, so a late callback cannot introduce a short
flash. Current 160/400 ms windows suppress both hints; this is a policy check,
not a deletion of the hints. The future-window config uses 800 ms and witnesses
an awaiting hint after the grace. Early second presses can still resolve a
future hint early; minimum visibility is the time available before timer expiry,
not a reason to delay input or keep stale UI visible.

Calibration: one recorded double-tap, approximately 250 ms ± 50 ms at 20 fps
(n = 1). The 350 ms awaiting grace covers the 300 ms upper observation bound
plus 50 ms. This is not a population p95 estimate. Private frames and timestamps
remain outside tracked files.

Run from the repo root (Java must be on PATH):

```sh
bash formal/f5-gesture-preview/check.sh
# Refresh normalized evidence explicitly:
bash formal/f5-gesture-preview/check.sh --record
```

This uses the existing pinned TLC runner, one worker and nice 19. checks.json
registers every config and exact expected counterexample. The model uses 1 ms
ticks, four representative first-release times, all second-press ticks, hold
and expiry timers, and cancellation. It explores input/preview order at equal
timestamps. It is bounded to one episode (no A-B-A re-press). Current constants and a future 800 ms window pass; the old immediate
awaiting preview and pressing preview violate their exact invariants. Removing
the minimum-visible rule reproduces the late hint flash. FutureHintWitness is
a deliberately false assertion whose counterexample proves that the longer
window actually permits a hint. PreviewMatchesPhase ties every displayed hint
to the current logical phase. StaleShowMutant drops the phase guard and violates
that invariant when a queued awaiting hint arrives after cancellation.

The model abstracts cancelled jobs as inert and does not prove Swift source
refinement or macOS rendering. Swift's injected clock/scheduler tests exercise
the real gesture machine and presentation mapping, including stale scheduled
hold/window jobs and selection cancellation. Installed by-eye QA remains:
**hint never flashes on quick double/single taps**. NOT_RUN in this lane;
live VoiceBar and system inputs are out of scope.
