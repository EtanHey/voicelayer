# Native automatic paste

One already-selected native target, one transcript already retained in History,
one AX attempt, then at most one keyboard fallback. Focus can change app/PID,
disappear, or change elements in the same app before either decision. `recording`
means the original PID; a replacement process with the same bundle is `other`.

D1 / P-01: TextEdit's AXTextArea omits both AXEnabled and AXEditable while
AXValue, AXSelectedText and AXSelectedTextRange are settable. Requiring an
explicit AXEnabled=true rejects this writable editor in both native AX and
keyboard fallback. Both paste-path checks now reject only explicit false;
all other focus, role, security and setter guards remain unchanged.

`editable` represents the independent writable-text evidence, including the
existing text-role and security requirements. `enabled` separately ranges over
`"true"`, `"false"`, and `"absent"`. `NativeEditable` recognizes writable text
with absent AXEnabled; `PolicyEnabled` applies the implementation's enabled
policy. Separating those predicates prevents a refusal from making the delivery
property vacuously pass.

`NoWrongApp`, `NoDoubleDelivery`, `Retention`, and `NoDisabledDelivery` are safety
invariants. `EligibleDelivery` additionally requires a dispatch after an editable,
unchanged-focus pre-write AX decline. Current.cfg models the pre-D1 policy:
normal native fallback is enabled, but absent AXEnabled refuses both routes.
Fixed.cfg changes only `AllowAbsentEnabled` to TRUE. Explicit false still refuses
both routes, as checked by `NoDisabledDelivery`.

`AXConsumes` includes possible/unverified writes: it terminates the operation so
fallback cannot duplicate them. Counts represent dispatch attempts, not proof
that a host inserted the text. Retention is structural in this small model:
the already-saved transcript is never removed. App selection/retargeting before
the paste pipeline, rich-host bypasses, event-batch internals and the detailed
macOS AX protocol are outside this model. This is a bounded abstraction, not
source refinement or installed macOS acceptance. `CommandModeAXHelperTests`
uses the observed TextEdit metadata for the eligibility fixture and exercises
the automatic fallback through VoiceState. `VoiceStatePasteTests` covers the
other existing delivery paths and refusal cases.

Run from this directory (TLC 2.19 accepts these options):

```sh
nice -n 19 java -XX:+UseParallelGC -cp ~/.cache/tla/tla2tools.jar tlc2.TLC \
  -workers 1 -seed 1 -fp 0 \
  -metadir ../../.build.noindex/tlc-native-autopaste/current -config Current.cfg NativeAutoPaste.tla
nice -n 19 java -XX:+UseParallelGC -cp ~/.cache/tla/tla2tools.jar tlc2.TLC \
  -workers 1 -seed 1 -fp 0 \
  -metadir ../../.build.noindex/tlc-native-autopaste/fixed -config Fixed.cfg NativeAutoPaste.tla
```

TLC2 Version 2.19 (rev: 5a47802), one worker, seed 1, fp 0, 2026-11-02:

```text
Current.cfg: exit 12 (expected counterexample)
Error: Invariant EligibleDelivery is violated.
133 states generated, 79 distinct states found, 35 states left on queue.
The depth of the complete state graph search is 3.

Fixed.cfg: exit 0
Model checking completed. No error has been found.
200 states generated, 110 distinct states found, 0 states left on queue.
The depth of the complete state graph search is 4.
```

The old-policy counterexample keeps `front = "recording"`, `editable = TRUE`,
`enabled = "absent"`, `sameElement = TRUE`, and `retained = TRUE` throughout
`ax -> fallback -> done`, but ends with `eligibleDecline = TRUE` and `attempts = 0`.
Both configs keep `AllowNativeFallback = TRUE`; only `AllowAbsentEnabled` differs.

Installed acceptance remains separate: normal F5 into a focused TextEdit document
must insert the completed transcript exactly once at the caret, leaving the
clipboard unchanged. An AX success should log `paste_path path=ax source=fresh`
and `paste_ax_insert_complete result=verified`; a safe fallback should log
`paste_typing_eligibility reason=eligible` and `paste_typing_result typed=true`.
These dispatch/readback logs accompany, and cannot replace, the actual document
check. The implementation lane does not launch apps or synthesize input.
