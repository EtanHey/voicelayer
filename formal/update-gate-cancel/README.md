# Precommit Cancel acquisition/release refinement

Run `bash formal/update-gate-cancel/check.sh`. The shared runner requires the
fixed model to pass and the old guard to fail `RecoverableCancelReopens`.

`formal/update-gate/FirstInstall.tla` covers bootstrap, quit and completion,
not precommit Cancel. PR #676's `LeasedUpdate.tla` adds Cancel but abstracts G1
sections atomically; that unmerged model is absent from this integration pin.
This independent refinement exposes the attempt/release/decision interleaving
without changing R6/R7's recovery or leased-completion models.

Mapping:

- `Attempt`: `updateVoiceGate(CANCEL)` attempts real G1 mkdir; held means a
  contention result. A successful attempt changes DRAINING to OPEN.
- `Release`: the fixture holder drops G1 before the attempt, between attempt
  and decision, or after the first decision. Never-release is a fourth case.
- `Decide`: `cancelLease` passes the result to `retryInstallerContention`.
  The old guard consults current lock presence; the fixed path throws the
  original acquisition error and retries even after G1 becomes free.
- Eight attempts preserve the source helper's budget. Backoff durations are
  abstracted; weak fairness assumes each enabled controller/holder step runs.

`OldSplitProbe` fails on acquire-locked -> release -> stale-refusal/recovery,
leaving DRAINING. `Fixed` reattempts and reopens for all three release schedules.
Never-release exhausts the budget and retains DRAINING; it is outside the
conditional recovery promise. No COMMIT or installer action exists on this
precommit-refusal path; the real-code regression asserts both remain absent,
that the original admission ledger survives Cancel, and that later retry works.

This is ordering proof, not installed VoiceBar or macOS availability proof.

## 2.3 precommit voice availability

`UserBlockFixed` models registered admission in OPEN/DRAINING, atomic locked
PREPARE/COMMIT ledger checks, and cancellation at a three-tick logical deadline
(implementation: 120 seconds). With weak fairness for clock, commit and cancel,
every requested precommit drain commits or cancels within that logical bound,
even when the participants never ACK or voice continues arriving. This assumes
healthy storage and lock acquisition; `Fixed` separately models recoverable
CANCEL contention. Permanent lock/storage faults still require recovery.

`OldAdmission` fails NoEarlyVoiceRefusal; `NoLedger` fails NoSwapWithLedger;
`UnboundedDrain` fails BoundedDrainResolves. NoEarlyVoiceRefusal observes actual
admission attempts in OPEN/DRAINING; PREPARED/COMMITTED may refuse.
Run `bash formal/update-gate-cancel/check.sh --record` to refresh receipts.
