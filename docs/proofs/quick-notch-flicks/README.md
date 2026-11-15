# Short notch flick proof

A seeded handoff absorbed the first six points of pointer displacement and also lost its velocity. The fix preserves the release velocity while keeping the handoff's zero displacement.

Baseline: f5994253af357bcd8be5c5bfd8f58db923699102, five tests, fourteen assertion failures. Four assertions reproduce lost six-point flick velocity in both directions; two reproduce the hosted centre pull. Eight other assertions came from a new fixture nominally at y=33. A subsequent candidate run executed 92 tests with eight assertion failures, all in the same new edge test (two per 6/8/10/220-point pull); the other 91 methods passed. The legacy helper wrongly subtracts the 17-point bottom shadow from the window top: nominal y=31 actually starts at y=48, beyond pullBandHeight34. The earlier y=33 fixture actually started at y=50. The new test alone now derives the point from visibleContentRect.maxY and asserts its exact canvas Y and pull-band admission. Every result assertion and the legacy helper's other callers are unchanged. No evidence from that run requires a further production velocity change. The 40 ms click, slow/cancel control and immediate-hover click already passed on the baseline.

Focused candidate test summary:

- Executed 15 tests, with 0 failures (0 unexpected) in 23.551 (23.593) seconds
- Executed 39 tests, with 0 failures (0 unexpected) in 0.009 (0.015) seconds
- Executed 7 tests, with 0 failures (0 unexpected) in 14.892 (14.894) seconds
- Executed 31 tests, with 0 failures (0 unexpected) in 168.088 (168.106) seconds
- Executed 92 tests, with 0 failures (0 unexpected) in 206.541 (206.608) seconds
- Executed 92 tests, with 0 failures (0 unexpected) in 206.541 (206.608) seconds

HistoryPull's guarded model run completed and its source hashes were checked before commit. The model receipt binds source integrity; it does not add native click or audio acceptance.

green-measurements.txt contains real model release values and 60 Hz spring-model frames; these are synthetic measurements, not screen measurements. Offscreen candidate PNGs are retained for lead inspection in the local receipt folder; glass is unavailable through that renderer. Before renders were not run. No native app, live recording, corpus or installed proof is claimed.

Push custody: lead on M4. Planned PR base: integration/2.4.3. Other-vendor review is pending; no reviewer was started by this worker.
