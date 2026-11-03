# Leased update lifecycle (G5 formal-model gap)

`LeasedUpdate.tla` is a TLA+ model of the whole update lease lifecycle, from
start to finish. It sits next to lane G5's `formal/update-gate/FirstInstall.tla`
and replaces nothing in it. This directory adds no runtime code and makes no
installed-app claim.

**Why it exists.** A successful update from 2.2.61 returned 0 but left
`update-gate.json` at `COMMITTED`. Admission therefore answered
`UpdateBusyError` from then on, and dictation stayed blocked after the update.
The integration model let this happen:

- `UpgradeSpec` ends its `leaseOwner` scenario at `phase = "done"` with
  `gate = "COMMITTED"`.
- No property asked for the gate to reopen.

G5 adds `CompletionSpec`, but it checks COMPLETE on its own: one controller,
starting at `COMMITTED`. This model puts REQUEST → PREPARE → COMMIT → install →
COMPLETE/CANCEL into one spec. The spec also includes:

- a second updater
- a voice admitter
- process crash and death inside the G1 lock
- the detached installer child
- evidence lost after verification

The audit, receipts and counterexamples are in
`docs/research/2026-11-04-g5-formal-model.md`.

## Properties

| Property | Kind | Meaning | Exact failing config |
| --- | --- | --- | --- |
| `LeaseExclusive` | safety | A closed gate names exactly one owner, and every live controller in a lease phase is that owner | `LeaseMutantSteal` (REQUEST accepted from a closed gate) |
| `ReleaseByOwnerOnly` | safety | Only the lease's own controller ever publishes its release | `LeaseMutantForeignComplete` (COMPLETE skips `sameLease`) |
| `MutationExclusive` | safety | The installer runs only under its owner's `COMMITTED` lease plus custody receipt, with no voice admission registered | `LeaseMutantRollback` (CANCEL after COMMIT), `LeaseMutantCrashReopens` (a dead owner reopens) |
| `ReopenOnlyVerified` | safety | A committed lease reopens only on proof present at the reopening step | `LeaseMutantNoRecheck` (COMPLETE trusts evidence gathered before G1) |
| `NoHealthyExitHoldingLease` | safety | The 2.2.61 terminal state is unreachable: a normal return after a healthy install while the lease is still held | `LeaseOldExit` (2.2.61 semantics; the shortest trace, found by breadth-first search) |
| `VerifiedUpdateReleases` | liveness | A healthy installed update eventually releases the gate | `LeaseOld` (2.2.61 semantics) |
| `AbortedUpdateReleases` | liveness | An aborted precommit update eventually releases the gate | `LeaseMutantNoCancel` |

Each liveness property has a **condition**. Its premise uses environment facts
(owner holds `COMMITTED`, child exited 0, installed SHA equals the target,
successor pair starting or ready), not controller program counters. Code that
never verifies therefore cannot satisfy the premise vacuously. Only three
excuses are allowed:

- the owner crashed
- some process died inside G1, so `<gate>.lock` is orphaned
- the verified evidence vanished before the recheck inside G1

A normal return is never excused, and that is exactly the 2.2.61 transition.
Each excuse is shown necessary by a probe in `boundary/` that must fail:

| Probe | Drops the excuse | Counterexample |
| --- | --- | --- |
| `BoundaryCrash` | owner crashed | Owner killed during install; its detached child exits 0; `COMMITTED` is retained |
| `BoundaryOrphan` | G1 orphaned | Voice dies inside G1; `CompleteGiveUp`; `COMMITTED` is retained |
| `BoundaryEvidence` | evidence gone | Plist changes after exit 0; `VerifyFail`; `COMMITTED` is retained |
| `BoundaryAbortCrash` | owner crashed (abort) | Controller is killed while draining; `DRAINING` is retained forever |

These match the documented fail-closed contract: an absent owner, an expired
heartbeat, or an orphaned lock never opens the gate. They are not promises the
code breaks. They are availability limits that this model makes explicit.

**Fairness.** A live controller keeps executing its own code. A detached child
terminates. A starting successor becomes ready within the 15 s retry budget;
this is G5's bounded-readiness assumption, and `"never"` models the successor
that does not. A voice turn finishes. Nothing forces a REQUEST, an abort, a
crash, an admission or evidence loss.

## Source mapping (lane G5 head `1479ea77`, unless noted)

| Model | Source |
| --- | --- |
| `g1`, atomic G1 steps | `update-gate-storage.ts:75-91` `withUpdateGateLock`: `mkdir <gate>.lock`, synchronous body, `rmdirSync` on success. `update-gate-admission.ts:74-98` `safeGateLock` catches body faults so a REFUSED transition still unlocks. A process dying between mkdir and rmdir is the only way to orphan the lock (`Crash` with `orphan`, `VoiceCrashInG1`). |
| `Request` / `RefuseStart` | `update-gate-installer.ts:228-235`: a gate that is not OPEN, or an existing `.controller` receipt, refuses. `update-gate.ts:82-88`: REQUEST only from OPEN, generation +1. `update-gate.ts:90`: any other command on a closed gate needs `sameLease` (OWNERSHIP). |
| `Prepare` / `Commit` (`~voice`) | `update-gate.ts:94-103`. `update-gate-admission.ts:305-307`: PREPARE, COMMIT and COMMITTED→OPEN refuse while `active.length !== 0` or the in-lock proof is not exactly true. `update-gate-installer.ts:258`: COMMIT persists the controller receipt inside the same G1 callback. |
| `Abort` / `CancelLease` | Signal handlers at `update-gate-installer.ts:242-249` set `cancelled` before commit. The loop breaks at 299/307/310, or a refusal throws. `finally` at 348 runs `cancelLease` (195-204) only when `requested && !pastCommit()`. `update-gate.ts:109-112`: CANCEL refuses `COMMITTED` (PHASE). |
| `Spawn` | `update-gate-installer.ts:322` (controlled quit of the old pair) and `:326` (`Bun.spawn(..., detached: true)`: the child survives controller death, hence `ChildExit` runs after `Crash`). |
| `OldReturn` (2.2.61 / `OmitComplete`) | integration `f401ae7` `update-gate-installer.ts:240-243`: `const result = await child.exited; ...; return result;`. Exit 0 returns 0 and `finally` skips CANCEL because `pastCommit()`. Nothing reopens the gate. |
| `Verify` / `VerifyFail` | `update-gate-installer.ts:148` (exit code), `:155` (plist GitCommit equals `lease.targetSha`), `:158-175` (fresh successor round trips within 15 s; `UnsafeSuccessorError` refuses at once, `:169`). The new-pair fences are in `update-gate-installer-participant.ts:200-205` and `:257`. The retry schedule itself is G5's `SlowCompletionSpec`; this model does not duplicate it. |
| `Complete` / `CompleteRefused` / `CompleteGiveUp` | `update-gate-installer.ts:176-186`: inside G1 it rechecks `COMMITTED` plus `sameLease`, the controller receipt pid/identity, `installed.unchanged()` and `successor.verify`. `update-gate.ts:104-108` is the COMPLETE transition. `withCompletionProof` (participant `:251`) bounds lock contention, then it throws into `recoveryReceipt` (`:189`). |
| `Reopen` receipt removal | `update-gate-storage.ts:141-151`: the state is persisted first, then the matching controller receipt is removed (G5 reordered these). |
| `ForeignComplete` | Any caller of `updateVoiceGate` supplies its own proof callback. `transitionUpdateGate`'s `sameLease` check (`update-gate.ts:90`) is the fence against a nonowner. |
| `Crash` (`CrashReopens` mutant) | `docs/update-gate-contract.md`: "An absent owner or expired heartbeat never opens the gate" and "Never unlink/reap/replace a lock on age, heartbeat, PID death". |
| `Admit` / `VoiceDone` | `update-gate-admission.ts:149-185`: registration under G1 only when OPEN (`:161`; a closed gate gives `UpdateBusyError`). Release removes the ledger entry under G1. |

**Known abstractions (not modeled):**

- Voice fail-open behavior when G1 is contended or orphaned. Admission
  diagnoses the fault and runs unregistered; the model's `Admit` waits instead.
- Durable writes whose outcome is uncertain. A crash after rename but before
  rmdir is over-approximated as a completed step plus a crash that orphans the
  lock.
- The retry timing, which is G5's `SlowCompletionSpec`.
- Homebrew and LaunchServices behavior.
- Real IPC, TCC and macOS scheduling.

## Run

```bash
bash formal/update-gate-lease/check.sh   # needs formal/check-model.py (integration/G5 trees)
TLA2TOOLS=/path/to/tla2tools.jar bash formal/update-gate-lease/boundary/check.sh
```

`results/` was recorded by `check-model.py --record`. That run used a scratch
tree built from G5 head `1479ea77` plus this directory, so the source hashes in
`results/run.json` are G5's. The TLC used was the jar currently served at the
`v1.8.0` release URL (sha256 `e2044764…`, git rev `309e489`). See the report for
why the repo's checksum pin no longer matches that URL.
