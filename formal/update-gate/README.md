# First-install update gate (G0)

Base 776982d0 has no update-gate TLA+ model. This adds a focused model; every
existing formal model and mutant is retained unchanged. It models absent-file
availability bootstrap, including a legacy 2.2.58 bundle with no gate. It does
not qualify the entire update controller or a real Homebrew install.

Setup samples stopped owners before and after acquiring its bootstrap mutex,
then calls the same G2/G1 exclusive initializer used by voice startup. Existing
records and sidecars stay authoritative. Faults refuse initialization while G4d
may restore availability without granting update authorization. An observed
OPEN generation 0 is never a verified target SHA or a COMMIT lease.

`Create` abstracts the stopped-owner recheck and G1 publication; `Arrive` tests
an owner appearing between the initial sample and that recheck. Legacy apps do
not honor the mutex, so this is not proof that an arbitrary OS launch cannot
race the final process sample. Post-publication process resampling detects that
case and reports recovery, preserving the gate rather than deleting evidence.

Run on the M1 under the captain lock: `bash formal/update-gate/check.sh`.
The shared runner rejects any mutant which passes or fails the wrong property.

| Property | Exact failing config |
| --- | --- |
| BootstrapOnlyQuiescent | MutantLive |
| BootstrapPreservesEvidence | MutantEvidence |
| BootstrapExclusiveCreate | MutantReplace |
| BootstrapOpenGenerationZero | MutantGeneration |
| FreshInstallCompletes | OldNoBootstrap |

## Old updater / new script upgrade (G1)

`UpgradeSpec` models 2.2.58's still-running updater installing new formula bytes,
then cask replacement/postflight, then the NEW dedupe and autostart scripts.
The old updater starts with either an absent gate or the already OPEN gate
observed in the captain's restored 2.2.58 upgrade path.
Homebrew's stop/delete/move is abstracted by `UpgradeCask`. Cask setup and the
compatibility helpers restore only availability. A lease-holding controller
gets plists only until `UpgradeOwnerRestore`; its COMMITTED gate is retained.
`created` records successful completion of the old updater's whole repair
sequence, so merely starting the app in postflight cannot hide a later missing
SHA refusal. `mutex` represents the live controller for this specification.

| Config | Expected result | Exact property |
| --- | --- | --- |
| UpgradeOld | FAIL: sandbox plus missing target | VoiceBarRunningAfterUpgrade |
| UpgradeFixed | PASS | Both upgrade properties |
| MutantMissingTarget | FAIL: fix sandbox only, remove compatibility | VoiceBarRunningAfterUpgrade |
| MutantUpgradeController | FAIL: remove setup's live-controller startup fence | UpgradeControllerOwnsStartup |

`VoiceBarRunningAfterUpgrade` requires successful old-updater completion,
VoiceBar running, and an OPEN gate. Fairness assumes each installer step runs;
startup actions assume functioning host launchd/LaunchServices outside the
observed sandbox denial. This is an ordering proof, not an installed acceptance
claim or protection for the legacy updater's ungated brew mutation. Every new
property has an exact failing mutant, enforced by the shared check runner.

## Controlled quit (G3)

`QuitSpec` models alive, exiting, unreaped, teardown, empty-ps, defunct, gone,
reused and competitor observations. Each poll records process evidence and the
locked COMMITTED-lease check before deciding. Healthy schedules traverse the
transitional classes and finish within the budget; persistent uncertainty expires.
This is an observation/order model, not a macOS scheduler or installed-app proof.

| Config | Expected | Exact property |
| --- | --- | --- |
| QuitOld | FAIL on the first transitional observation | HealthyQuitCompletes |
| QuitFixed | PASS | All three quit properties |
| QuitMutantReuse | FAIL when reuse is treated as gone | NeverProceedOnReusedOrCompetitor |
| QuitMutantHeld | FAIL without locked lease verification | NeverProceedWithoutHeldLease |

## Verified leased completion (G5)

`CompletionSpec` starts at COMMITTED after the old participants have exited.
The controller waits for child exit, reads the installed GitCommit, and obtains
fresh authenticated replacement native/daemon identities. Only its matching
lease/controller custody can publish OPEN with that generation and released
lease under G1; the matching controller receipt is removed after publication.
The existing startup-only upgrade model above intentionally retains COMMITTED:
starting the app alone is not completion. G5 supplies the separate final phase.

| Config | Expected | Exact property |
| --- | --- | --- |
| CompleteOld | FAIL: omit COMPLETE | LeasedUpdateReopensAdmission |
| CompleteFixed | PASS | LeasedUpdateReopensAdmission + NeverReopenUnverified |
| CompleteMutantSha | FAIL: omit installed target match | NeverReopenUnverified |
| CompleteMutantOwner | FAIL: allow a different controller owner | NeverReopenUnverified |

The liveness premise is verified successful installation by the owner. Weak
fairness assumes controller and next admission acquire execute. A nonzero child,
SHA mismatch, dead/old successor, or foreign owner retains COMMITTED; those are
not liveness promises. The model abstracts fresh round trips/unchanged bytes as
verified predicates, not proof of real macOS permissions or IPC availability.
The same native admission object rereads OPEN on its next acquire without a
restart (NativeUpdateGateTests.testCommittedSuccessorAdmitsAfterCompleteWithoutRestart).
R6 below adds the separate successor startup backstop.

## Slow successor readiness (G5 round 2)

`SlowCompletionSpec` models fresh successor samples, ready only at k=3, with a
five-sample abstract deadline. Never-ready and positively unsafe sample-two
scenarios retain COMMITTED. `OneShotCompletionSpec` uses the identical schedule
and checks, but refuses after one failed sample. Both check
`NeverReopenUnverified`; only the retrying caller satisfies
`LeasedUpdateReopensAdmission` for the slow healthy scenario. The liveness
premise includes that scenario before readiness, so one-shot refusal cannot
make the property vacuous. The existing completion scenarios retain their
original premises and expected outcomes.

| Config | Expected | Exact property |
| --- | --- | --- |
| CompleteSlowOneShot | FAIL: successor not ready on the first sample | LeasedUpdateReopensAdmission |
| CompleteSlowFixed | PASS | LeasedUpdateReopensAdmission + NeverReopenUnverified |

The bounded schedule assumes readiness within the retry budget. The model does
not predict startup time or prove real IPC; source guards separately use a
virtual 60-second clock, 100 ms exponential backoff capped at one second, and
the production participant verifier with synthetic authenticated-RPC responses.

## Abandoned COMMITTED recovery (R6)

`RecoverySpec` adds a successor observing controller death after launch. The crash
scenario starts with a live controller; its exit is weakly fair. Five bounded
observations represent the five-second grace. A transient G1 holder eventually
releases independently; no orphaned lock is reaped. Publication requires the
matching running/installed target and fresh, idle participant evidence, then the
G1 custody recheck. OPEN restores admission; it grants no installer authorization.

| Config | Expected | Exact property |
| --- | --- | --- |
| RecoveryOld | FAIL: no startup completion | EventuallyOpenAfterAbandonedLease |
| RecoveryFixed | PASS | Liveness and both safety properties |
| RecoveryMutantLive | FAIL: recover with live controller | NeverRecoverLiveController |
| RecoveryMutantTarget | FAIL: recover wrong target | RecoveryOnlyVerified |

Death is irreversible for the recorded process incarnation. Unknown identity,
reused PID, missing custody, persistent G1, and mismatched/busy successors are not
liveness promises. The source watches a live controller for up to 60 seconds;
readiness has its own 60-second deadline, renewing one-second receipts as needed.
Liveness assumes controller absence, G1 release and readiness within the source
budgets; weak fairness orders the abstract actions and does not prove a real-time
deadline. The model abstracts fresh round trips and the empty ledger as predicates,
and G1 publication as atomic. It does not prove partial-write recovery, detached
installer quiescence, actual launch latency, IPC availability or installed macOS
behavior. R5 half-state repair and rollback to a different build remain deferred.

## Precommit user-block correction

The admission/deadline extension is checked alongside CANCEL retry in
[`../update-gate-cancel/`](../update-gate-cancel/README.md): `UserBlockFixed`,
`OldAdmission`, `UnboundedDrain`, and `NoLedger`. These prove separate availability,
locked-ledger and bounded-resolution properties; installed acceptance remains a
separate gate. The bootstrap/completion models here keep their existing scope.
