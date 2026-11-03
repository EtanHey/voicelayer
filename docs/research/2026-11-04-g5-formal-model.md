# G5 formal-model gap: leased update must release the gate

Task marker: `cloud-credit-20261104-g5-formal-model`. This is a formal-model
and report change only. It adds no runtime change and makes no
native/installed claim.

| Ref | SHA |
| --- | --- |
| Start (`origin/main`) | `1cb914a23411de94007aeba463cdab1f3b6725c6` |
| Reference `origin/integration/2.2.61` | `f401ae7b2ba24313f9c0bc1ed113c5081da345fd` |
| Reference `origin/lane/g5-leased-update-completes` | `1479ea77255ffaf80d4f131526040d7c7ed1d624` |

Both reference branches were only read. Neither was modified or pushed.

## 1. What failed, and why the old model allowed it

**Integration `update-gate-installer.ts:240-243`:**

```ts
const result = await child.exited;
if (result !== 0) recoveryReceipt(...);
return result;
```

When the child exits 0, the controller returns 0 with `update-gate.json` still
`COMMITTED`. `finally` skips CANCEL because `pastCommit()`, and CANCEL would be
refused on `COMMITTED` anyway. No COMPLETE command exists. Every later admission
reads a gate that is not OPEN and returns `UpdateBusyError`
(`update-gate-admission.ts:161`), so dictation stays blocked.

**The integration model (`formal/update-gate/FirstInstall.tla` @ `f401ae7`)**
contains no completion spec. Its `UpgradeSpec` `leaseOwner` scenario ends at
`phase = "done"` with `gate = "COMMITTED"`, and no property objects.

Reproduction: a scratch wrapper declares
`LeaseOwnerEventuallyReopens == (scenario = "leaseOwner") ~> (gate # "COMMITTED")`
and runs `UpgradeFixed`'s constants against it:

```
ProbeUpgrade rc=13 | Temporal property LeaseOwnerEventuallyReopens was violated | 13 generated, 12 distinct
```

The same probe fails identically on G5 `1479ea7`, where `UpgradeSpec` is
unchanged by design.

## 2. Audit of the actual G5 model (`1479ea7`)

All 20 G5 configs were rerun with raw TLC
(`-workers 1 -seed 1 -fp 0 -config X.cfg FirstInstall.tla`). Every verdict and
state count matches the committed `results/*.log`. For example: CompleteOld 15,
CompleteFixed 17, CompleteSlowFixed 29, CompleteSlowOneShot 12, Fixed 39,
QuitFixed 41.

Coverage of the requested properties in G5's `CompletionSpec` and
`SlowCompletionSpec`:

| Requested | G5 model | Gap |
| --- | --- | --- |
| Verified complete releases the gate (liveness) | `LeasedUpdateReopensAdmission`, failed by `CompleteOld`/`CompleteSlowOneShot` | Single controller, starting at COMMITTED. Not composed with REQUEST/PREPARE/COMMIT or with UpgradeSpec. |
| Aborted update releases the gate | **none** | Precommit CANCEL is not modeled at all. |
| Owner/lease exclusivity vs nonowners | `IgnoreCompleteOwner` flips an `owner` evidence boolean | No concurrent second updater and no stale/foreign COMPLETE interleaving. |
| Failure/rollback ordering | Failing scenarios just stop | Rollback after COMMIT is not modeled; there is no mutant for it. |
| Process exit / crash | **none** | No crash, no detached child that outlives the controller, no orphaned G1. |
| G1 lock release | `mutex` | **Model infidelity, see the probe below.** |

**G1 probe.** `G1EventuallyFree == <>[](mutex = FALSE)` was checked against
`CompleteFixed`'s constants:

```
ProbeG1 rc=13 | Temporal property G1EventuallyFree was violated | 17 generated, 17 distinct
trace: scenario="exitFailure": install -> verified -> locked (mutex = TRUE), then stutters
```

In `CompletionSpec`, every refusal scenario acquires G1 and never releases it.
The source does not behave this way:

- Exit-code, SHA and successor failures throw before G1 (`:148/:155/:158-175`).
- A REFUSED in-lock recheck returns through `withUpdateGateLock`'s `rmdirSync`.

G5's `CompleteOld` counterexample also ends with `mutex = TRUE`. That
misdescribes the real trigger, in which G1 was free and the **durable lease**
was what stayed held. This does not invalidate G5's safety results, but it means
that model cannot tell "lease held" apart from "G1 orphaned".

**Verdict:** G5 covers the COMPLETE guard and successor-readiness retry well. It
does **not** cover the remaining requested properties: abort liveness,
concurrent-owner exclusivity, rollback/crash orderings, and correct G1 release.
The G5 configs are left unchanged. Their retry/readiness coverage is not
duplicated here.

## 3. The extension: `formal/update-gate-lease/LeasedUpdate.tla`

The model covers:

- 2 controllers and one voice admitter
- atomic G1 sections, plus crash inside G1 (orphaned lock)
- crash anywhere
- a detached installer child
- successor pair states `none/starting/ready/never/lost`
- the installed SHA relative to the owner's target

Safety properties, liveness properties, fairness, source mapping and
abstractions are in `formal/update-gate-lease/README.md`. Liveness premises are
**environment facts**, not controller program counters, so the old code (which
never reaches a "verified" state) cannot satisfy them vacuously. Each property
has a mutant config that fails exactly that property.

### Receipts

TLC `Version 2026.11.03.180953` (git `309e489`): the jar served at the `v1.8.0` release URL on
2026-11-03, sha256 `e20447644bfabd29d6bd0fc2c0eb1473fb301c1a0e4dfe1961938ce5a191edbf`.
Run with `-workers 1 -seed 1 -fp 0`, through the repo's `formal/check-model.py
--record`, in a scratch tree made of G5 head plus this directory.

Cross-checked with the immutable TLC 2.19 release `v1.7.4`, sha256
`936a262061c914694dfd669a543be24573c45d5aa0ff20a8b96b23d01e050e88`. The verdicts
and the generated/distinct counts were identical.

| Config | Result | Property | Generated / distinct | Depth |
| --- | --- | --- | --- | --- |
| LeaseFixed | PASS | all 5 invariants + 2 liveness | 16,125 / 4,992 | 23 |
| LeaseOld | EXPECTED_FAIL (rc 13) | VerifiedUpdateReleases | 4,867 / 1,700 | — |
| LeaseOldExit | EXPECTED_FAIL (rc 12) | NoHealthyExitHoldingLease | 675 / 356 | 7 |
| LeaseMutantNoCancel | EXPECTED_FAIL (rc 13) | AbortedUpdateReleases | 12,199 / 3,662 | — |
| LeaseMutantSteal | EXPECTED_FAIL (rc 12) | LeaseExclusive | 12 / 10 | 3 |
| LeaseMutantForeignComplete | EXPECTED_FAIL (rc 12) | ReleaseByOwnerOnly | 332 / 196 | 6 |
| LeaseMutantRollback | EXPECTED_FAIL (rc 12) | MutationExclusive | 689 / 361 | 7 |
| LeaseMutantCrashReopens | EXPECTED_FAIL (rc 12) | MutationExclusive | 323 / 183 | 6 |
| LeaseMutantNoRecheck | EXPECTED_FAIL (rc 12) | ReopenOnlyVerified | 2,901 / 1,147 | 10 |
| boundary/BoundaryCrash | EXPECTED_FAIL (rc 13) | ReleasesEvenIfCrashed | 16,125 / 4,992 | — |
| boundary/BoundaryOrphan | EXPECTED_FAIL (rc 13) | ReleasesEvenIfOrphaned | 16,125 / 4,992 | — |
| boundary/BoundaryEvidence | EXPECTED_FAIL (rc 13) | ReleasesEvenIfEvidenceGone | 16,125 / 4,992 | — |
| boundary/BoundaryAbortCrash | EXPECTED_FAIL (rc 13) | AbortReleasesEvenIfCrashed | 16,125 / 4,992 | — |

### Shortest counterexample: the 2.2.61 trigger (`LeaseOldExit`)

TLC's breadth-first search gives the minimal 6-step trace:

| # | Action | gate | pc[c1] | child[c1] | installed | pair | g1 | receipt |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | Init | OPEN gen 0 | idle | none | old | old | none | none |
| 2 | Request(c1) | DRAINING c1 gen 1 | drain | none | old | old | none | none |
| 3 | Prepare(c1) | PREPARED c1 | prepared | none | old | old | none | none |
| 4 | Commit(c1) | COMMITTED c1 | committed | none | old | old | none | c1 |
| 5 | Spawn(c1) | COMMITTED c1 | installing | running | old | none | none | c1 |
| 6 | ChildExit(c1) | COMMITTED c1 | installing | exit0 | target | starting | none | c1 |
| 7 | OldReturn(c1) | **COMMITTED c1** | **exited** | exit0 | target | starting | **none** | c1 |

Unlike G5's `CompleteOld`, G1 is free at the end. The durable lease is what
stays held, which matches the observed failure. `LeaseOld` reaches the same
terminal state as a liveness lasso (12 states, then stuttering at state 13, after an
unrelated c2 cancel prelude), so `VerifiedUpdateReleases` is violated by the old
code itself. The model does not have to exclude that transition. With G5
semantics (`Verify` → in-G1 `Complete`), `LeaseFixed` passes both liveness
properties and every safety invariant.

### Safety teeth: nonowner and failure orderings (all shortest traces)

- **Steal** (3 steps): Request(c1); Request(c2) on a DRAINING gate. Both
  controllers think they hold the lease. The source fence is
  `update-gate.ts:82-90`.
- **ForeignComplete** (6 steps): c1 commits; c2 is refused at start, then
  submits COMPLETE. The gate reopens while c1 is `committed`. The source fence
  is `sameLease`.
- **Rollback** (7 steps): c1 spawns the installer, then aborts. CANCEL on
  COMMITTED reopens while the child is still running. The source fence is
  CANCEL→PHASE refusal (`update-gate.ts:109-110`).
- **CrashReopens** (6 steps): c1 spawns, then crashes. A "dead owner reopens"
  policy opens the gate while the detached child is still mutating. This is why
  the contract forbids PID/heartbeat reaping.
- **NoRecheck** (10 steps): Verify, then the pair is lost, then COMPLETE
  succeeds on stale evidence. Source fence: the in-G1 `installed.unchanged() &&
  successor.verify(state)` check (`update-gate-installer.ts:176-183`).

### Boundary probes: what the design does *not* promise

Each probe drops one liveness excuse, and each one fails. That shows the
condition is necessary and was not added to make the proof pass:

- **Crash:** the owner is killed during install and its detached child exits 0.
  Successor ready, `COMMITTED` forever.
- **Orphan:** a voice process dies inside G1. The owner's COMPLETE gives up and
  `COMMITTED` stays forever. (In source, admission then diagnoses the fault and
  runs unregistered; this is fail-open, not modeled.)
- **Evidence:** the plist changes after exit 0, then `VerifyFail`. `COMMITTED`
  stays forever.
- **AbortCrash:** the controller is SIGKILLed while draining, so `DRAINING`
  stays forever. **This has the same user-visible symptom as G5 (dictation
  blocked after an update) from a different cause, and G5 does not change it.**
  It follows the contract ("an absent owner ... never opens the gate"); recovery
  is manual.

## 4. No race test added

The model's new coverage concerns compositions and orderings: a second
controller, crashes, aborts. G5 already tests the source guards it maps to: the
`sameLease` OWNERSHIP refusal, CANCEL-on-COMMITTED PHASE refusal, and the
COMPLETE in-lock recheck (`src/__tests__/update-gate-complete.test.ts`, 214
lines on G5). The audit's G1 finding is a model infidelity, not a source bug.
This topic branch starts from `main`, where `completeGatedInstall` does not
exist, so a test here would target code that is not present. No deterministic
race test closed a source/model gap, so none was written.

## 5. Infrastructure finding: the TLC checksum pin has drifted

`formal/tlc.lock.json` (integration/G5) pins `v1.8.0` with sha256 `011267fc…`.
The `v1.8.0` release URL is now a rolling build: the manifest is stamped
2026-11-03T18:09:53Z, git `309e489`, sha256 `e2044764…`. On a cold cache,
`formal/setup-tlc.py` will raise `Downloaded TLC checksum mismatch`. CI survives
only while `actions/cache` keeps the old jar. Two possible fixes, neither made
here because this lane does not own that file:

- pin an immutable asset such as `v1.7.4`, sha256 `936a2620…`; the runner's
  `-noGenerateSpecTE` flag would then need a 1.7.4 fallback
- vendor the hash of a specific nightly

## 6. Native-proof boundary and limitations

- What is verified: model checking of an abstraction, with TLC state counts as
  listed above.
- What is not verified: the installed VoiceBar, real Homebrew, macOS
  LaunchServices/TCC, IPC timing, or the Swift `NativeUpdateGate`. No build,
  sign, install, tag, release, simulator or Mac access took place.
- Abstractions are listed in the README: G1 sections are atomic, voice
  fail-open is not modeled, uncertain writes are over-approximated, retry timing
  is delegated to G5's `SlowCompletionSpec`, and a bounded model uses
  2 controllers with one attempt each.
- `formal/check-model.py` is not on `main`. `check.sh` runs on
  integration/G5-based trees. On `main`, use the raw TLC commands below.

## 7. Exact commands

```bash
# Raw TLC (any tree), from formal/update-gate-lease/
for c in *.cfg boundary/*.cfg; do
  java -cp tla2tools.jar tlc2.TLC -workers 1 -seed 1 -fp 0 -config "$c" LeasedUpdate.tla
done
# Shared exact-property runner (integration/G5 tree with this dir added)
bash formal/update-gate-lease/check.sh
TLA2TOOLS=$HOME/.cache/tla/v1.7.4/tla2tools.jar bash formal/update-gate-lease/boundary/check.sh
```

Exit codes: 0 means PASS, 12 an invariant violation, 13 a temporal violation.
