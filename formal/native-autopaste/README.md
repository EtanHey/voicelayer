# Native automatic paste

One already-selected native target, one transcript already retained in History,
one AX attempt, then at most one keyboard fallback. Focus can change app/PID,
disappear, or change elements in the same app before either decision. `recording`
means the original PID; a replacement process with the same bundle is `other`.

D1 / P-01: TextEdit's AXTextArea omits both AXEnabled and AXEditable while
AXValue, AXSelectedText and AXSelectedTextRange are settable. Requiring an
explicit AXEnabled=true rejects this writable editor in both native AX and
keyboard fallback. Both paste-path checks accept an omitted enabled attribute
but reject explicit false and AXEnabled read failures. Only AttributeUnsupported
and NoValue responses count as absent; other errors (including CannotComplete)
refuse delivery and log enabledAttribute=error plus the AX error code. Other
focus, role, security and setter guards remain unchanged.

`editable` represents the independent writable-text evidence, including the
existing text-role and security requirements. `enabled` separately ranges over
`"true"`, `"false"`, and `"absent"`. `NativeEditable` recognizes writable text
with absent AXEnabled; `ImplEnabled` applies the implementation's enabled
policy, including an explicit-false mutant knob. Separating those predicates
prevents a refusal from making the delivery property vacuously pass.

`NoWrongApp`, `NoDoubleDelivery`, `Retention`, and `NoDisabledDelivery` are safety
invariants. `NoChangedElementDelivery` and `NoUnwritableDelivery` additionally
require dispatch-time evidence that the target is the captured element/window
and a writable text target. The ghost values `dispatchedSameElement` and
`dispatchedEditable` record the raw evidence when AX or typing dispatches, not
whether an implementation policy knob approved it. `sameElement` abstracts both
element and window identity; `editable` includes the existing text-role,
secure-subrole and protected-content requirements. `EligibleDelivery` additionally
requires a dispatch after an editable,
unchanged-focus pre-write AX decline. Current.cfg models the pre-D1 policy:
normal native fallback is enabled, but absent AXEnabled refuses both routes.
Fixed.cfg changes only `AllowAbsentEnabled` to TRUE. The implementation actions
use independent implementation guards rather than the specification's
`NativeEditable`. With mutation knobs off they require writable text, matching
element/window identity and `ImplEnabled`. Four targeted configs remove the
identity or writable-text guard independently from AX and fallback delivery.
Consequently, flipping `AllowExplicitFalse` can actually dispatch into a disabled
target, and `NoDisabledDelivery` must detect that defect.

`AXConsumes` includes possible/unverified writes: it terminates the operation so
fallback cannot duplicate them. Counts represent dispatch attempts, not proof
that a host inserted the text. With mutation knobs off, the already-saved
transcript is never removed; the retention mutant deliberately breaks that rule. App selection/retargeting before
the paste pipeline, rich-host bypasses, event-batch internals and the detailed
macOS AX protocol are outside this model. This is a bounded abstraction, not
source refinement or installed macOS acceptance. `CommandModeAXHelperTests`
uses the observed TextEdit metadata for the eligibility fixture and exercises
the automatic fallback through VoiceState. `VoiceStatePasteTests` covers the
other existing delivery paths and refusal cases.

From the repository root, run all checks, including one mutant per invariant:

```sh
bash formal/native-autopaste/check.sh
```

The script runs Java under nice with the options below, keeps separate logs and
metadata under this worktree's `.build.noindex`, and requires exit 12 plus the
exact invariant name for each failing case. A mutant that passes, a parser error,
or a different failed invariant makes the runner fail. In an isolated negative
check, changing Mutant.cfg to reject explicit false made TLC pass and the runner
correctly exit 1 (`expected exit 12, got 0`).

Mutation results on TLC 2.19 (2026-11-02):

| Config | Mutation | Required property | TLC exit |
|---|---|---|---|
| Fixed.cfg | Production policy | All eight invariants | 0 |
| Current.cfg | Reject absent enabled | EligibleDelivery | 12 |
| Mutant.cfg | Accept explicit false | NoDisabledDelivery | 12 |
| MutantType.cfg | Invalid completion phase | TypeOK | 12 |
| MutantWrongApp.cfg | Dispatch to foreign PID | NoWrongApp | 12 |
| MutantDouble.cfg | Dispatch twice | NoDoubleDelivery | 12 |
| MutantRetention.cfg | Drop retained transcript | Retention | 12 |
| MutantEligible.cfg | Reject absent enabled | EligibleDelivery | 12 |
| MutantAXElement.cfg | AX ignores element/window change | NoChangedElementDelivery | 12 |
| MutantFallbackElement.cfg | Typing ignores element/window change | NoChangedElementDelivery | 12 |
| MutantAXWritable.cfg | AX ignores writable-text evidence | NoUnwritableDelivery | 12 |
| MutantFallbackWritable.cfg | Typing ignores writable-text evidence | NoUnwritableDelivery | 12 |

Mutation knobs are test-only faults in the model. Every fixed/old/mutant config
sets them explicitly. There are no temporal properties in this bounded model;
all eight declared invariants have a mutant that fails that exact invariant.

Run individual cases from this directory (TLC 2.19 accepts these options):

```sh
../tlc.sh \
  -workers 1 -seed 1 -fp 0 \
  -metadir ../../.build.noindex/tlc-native-autopaste/current -config Current.cfg NativeAutoPaste.tla
../tlc.sh \
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
