# Native automatic paste

One already-selected native target, one transcript already retained in History,
one AX attempt, then at most one keyboard fallback. Focus can change app/PID,
disappear, or change elements in the same app before either decision. `recording`
means the original PID; a replacement process with the same bundle is `other`.

`NoWrongApp`, `NoDoubleDelivery`, and `Retention` are safety invariants.
`EligibleDelivery` additionally requires a delivery attempt after an editable,
unchanged-focus pre-write AX decline. The old policy fails this delivery goal;
it is not claimed to violate the three safety properties.

`AXConsumes` includes possible/unverified writes: it terminates the operation so
fallback cannot duplicate them. Counts represent dispatch attempts, not proof
that a host inserted the text. Retention is structural in this small model:
the already-saved transcript is never removed. App selection/retargeting before
the paste pipeline, rich-host bypasses, event-batch internals and native AX
capabilities are outside this model. This is a bounded abstraction, not source
refinement or real macOS acceptance. `VoiceStatePasteTests` exercises the real
delivery code using its existing fakes.

Run from this directory (use the installed Java executable on the host):

```sh
java -XX:+UseParallelGC -cp ~/.cache/tla/tla2tools.jar tlc2.TLC \
  -noGenerateSpecTE -workers 1 -seed 1 -fp 0 \
  -metadir /tmp/native-autopaste-current -config Current.cfg NativeAutoPaste.tla
java -XX:+UseParallelGC -cp ~/.cache/tla/tla2tools.jar tlc2.TLC \
  -noGenerateSpecTE -workers 1 -seed 1 -fp 0 \
  -metadir /tmp/native-autopaste-fixed -config Fixed.cfg NativeAutoPaste.tla
```

TLC2 Version 2026.10.28.014557 (rev: 56d37a9), one worker, seed 1, fp 0:

```text
Current.cfg: exit 12 (expected counterexample)
Error: Invariant EligibleDelivery is violated.
45 states generated, 27 distinct states found, 11 states left on queue.
The depth of the complete state graph search is 3.

Fixed.cfg: exit 0
Model checking completed. No error has been found.
67 states generated, 37 distinct states found, 0 states left on queue.
The depth of the complete state graph search is 4.
```

The current-policy counterexample keeps `front = "recording"`, `editable = TRUE`,
`sameElement = TRUE`, and `retained = TRUE` throughout `ax -> fallback -> done`,
but ends with `eligibleDecline = TRUE` and `attempts = 0`. Only
`AllowNativeFallback` changes between the two configs.
