# Precommit voice availability: implementation evidence

Status: source/isolated/formal proof only. No installed app, live permissions,
microphone, live sockets, user preferences or recording archive exercised.
Independent cross-vendor review belongs to the lead. No merge authorization.

## Regression contract

- OPEN/DRAINING admit registered voice, using the open/lease generation.
- PREPARE and COMMIT retain their in-lock empty-ledger checks. A registration
  between ACK and PREPARE forces a new proof round.
- The default 120-second precommit deadline cancels even an unsettled refresh.
  UNKNOWN and lost replies retry without proving readiness. SIGINT/SIGTERM
  also cancel before COMMIT. An uncertain/durable COMMIT retains recovery custody.
- stderr and the private timeout receipt name pending participants, observed
  identities/version/reply, and ledger token/kind/PID. Old records use kind=voice.
  Installed-bundle version is labeled as such; it is not a resident-version proof.
- UPDATE_BUSY ACKs use the existing notice band: “Updating VoiceBar…”.

## Formal proof

The committed `formal/update-gate-cancel/results/run.json` records exact source
hashes, per-config states and expected property violations. `UserBlockFixed`
checks NoEarlyVoiceRefusal, NoSwapWithLedger and BoundedDrainResolves under weak
fairness. OldAdmission, NoLedger and UnboundedDrain each falsify one exact
property. Fixed/OldSplitProbe retain the separate recoverable CANCEL lock model.
`formal/update-gate/results/run.json` also refreshes all 24 existing bootstrap,
quit, completion and recovery configurations.

The deadline model uses three logical ticks. Storage/lock faults still require
explicit recovery; TLC does not prove wall-clock scheduling or installed behavior.
An already-installed old resident retains its own admission implementation until
updated; legacy-peer evidence here proves bounded cancel, not new resident code.

## Verification commands

- `bun test ./src ./tests ./site ./formal` (normal preload; real archive/mic off).
- `bun run typecheck`.
- `PATH=/opt/homebrew/opt/openjdk/bin:$PATH bash formal/update-gate-cancel/check.sh --record`.
- `PATH=/opt/homebrew/opt/openjdk/bin:$PATH python3 -B formal/check-model.py formal/update-gate --record`.
- Swift fail-first: unchanged baseline NativeUpdateGate in a minimal isolated Swift
  package, then current touched suites via the host's heavy.sh wrapper.

Current receipts: focused final adapters/typed Ask/refusal suites **180 pass, 0 fail**
across 7 files; separate installer/lifecycle run **86 pass, 0 fail** across 4 files;
typecheck passes. The first full Bun run was **7365 pass, 60 skip, 2 todo, 5 fail**
(7432 tests/365 files); its stale DRAINING-refusal fixtures were corrected and the
final focused run includes those cases. A fresh full run remains required.
Swift RED executed 1 baseline test and failed with the old gate's `busy` error
(XCTest counted 1 unexpected failure); the corrected current-source run passed
all **20 selected native tests, 0 failures**. The first current-source harness
used an isolated native socket override, which changed singleton quit policy and
caused 19 assertions in 3 quit tests; that adverse run is retained. Correcting
only the harness environment produced the 20-test pass. Both runs used private
preferences/state and fixture-only media paths. The lead authorized direct,
serial `nice -n 10` Swift runs after the host load guard could not admit them.
The first pre-push run passed the full Swift suite (2837 tests, 83 skipped,
0 failures). Its Bun run found a replay-fixture failure: the out-of-range index
999999 defaults to 0, so a full-suite history buffer could start retained audio
and correctly keep PREPARE blocked. That fixture now uses valid index 0 with an
explicit empty history backend, asserts an empty ledger before PREPARE, and
verifies PREPARED never reaches history. The post-fix focused run remains
180 pass / 0 fail. Fresh full pre-push results are recorded in the PR/handoff receipt. Native visual
and installed qualification remain NOT_RUN. This is an implementation handoff,
not a green release verdict.
Native visual and installed acceptance are NOT_RUN by task boundary.

## Entry points
Checked: shared TS admission behind raw socket, MCP handlers, CLI fallback, capture,
replay/retranscription and selection queue; native gate and UPDATE_BUSY ACK handling
— isolated ingress/refusal and queue fixtures cover the changed gate semantics.

## Clients
Checked: Bun controller/daemon/standalone consumers and Swift gate/History/pill
— shared state schema preserved; native fixture execution is separately reported.

## Providers
Checked: authenticated G3 participant receipts, qualified installer harness, legacy
UNKNOWN/version and lost/no-reply cases — diagnostics never authorize readiness.
STT/TTS provider selection happens after shared admission and is unchanged.

## Contracts
Checked: version-1 state/lease and zero-work ACK schemas, TS/Swift registration
generation, optional informational pending metadata and private drain receipt
— the locked empty-ledger condition and exact lease checks remain mandatory.

## Reverse states
Checked: DRAINING arrival/release, PREPARE race, timeout CANCEL, SIGINT/SIGTERM,
missing/malformed diagnostics, precommit faults and postcommit uncertainty
— tests preserve refusal/recovery instead of treating UNKNOWN as idle.

## Connection modes
Checked: local isolated same-user IPC, standalone CLI, existing controller custody,
legacy/non-ACKing peer, unsettled/disconnected refresh and restarted successor
fixtures — no live connection or installation performed in this lane.

## Docs
Checked: update-gate contract, admission, installers and both formal READMEs
— OPEN/DRAINING availability, bounded cancel and proof limits documented.

## TLC per-configuration receipts

Distinct reachable states and the designated violation (mutants fail as intended).

| Configuration | States | Violation | Result |
| --- | ---: | --- | --- |
| update-gate/Fixed | 39 | none | PASS |
| update-gate/MutantLive | 19 | BootstrapOnlyQuiescent | EXPECTED_FAIL |
| update-gate/MutantEvidence | 25 | BootstrapPreservesEvidence | EXPECTED_FAIL |
| update-gate/MutantReplace | 24 | BootstrapExclusiveCreate | EXPECTED_FAIL |
| update-gate/MutantGeneration | 20 | BootstrapOpenGenerationZero | EXPECTED_FAIL |
| update-gate/OldNoBootstrap | 39 | FreshInstallCompletes | EXPECTED_FAIL |
| update-gate/UpgradeFixed | 12 | none | PASS |
| update-gate/UpgradeOld | 13 | VoiceBarRunningAfterUpgrade | EXPECTED_FAIL |
| update-gate/MutantMissingTarget | 11 | VoiceBarRunningAfterUpgrade | EXPECTED_FAIL |
| update-gate/MutantUpgradeController | 11 | UpgradeControllerOwnsStartup | EXPECTED_FAIL |
| update-gate/QuitFixed | 41 | none | PASS |
| update-gate/QuitOld | 31 | HealthyQuitCompletes | EXPECTED_FAIL |
| update-gate/QuitMutantReuse | 11 | NeverProceedOnReusedOrCompetitor | EXPECTED_FAIL |
| update-gate/QuitMutantHeld | 15 | NeverProceedWithoutHeldLease | EXPECTED_FAIL |
| update-gate/CompleteFixed | 17 | none | PASS |
| update-gate/CompleteOld | 15 | LeasedUpdateReopensAdmission | EXPECTED_FAIL |
| update-gate/CompleteMutantSha | 17 | NeverReopenUnverified | EXPECTED_FAIL |
| update-gate/CompleteMutantOwner | 17 | NeverReopenUnverified | EXPECTED_FAIL |
| update-gate/CompleteSlowFixed | 29 | none | PASS |
| update-gate/CompleteSlowOneShot | 12 | LeasedUpdateReopensAdmission | EXPECTED_FAIL |
| update-gate/RecoveryFixed | 44 | none | PASS |
| update-gate/RecoveryOld | 42 | EventuallyOpenAfterAbandonedLease | EXPECTED_FAIL |
| update-gate/RecoveryMutantLive | 60 | NeverRecoverLiveController | EXPECTED_FAIL |
| update-gate/RecoveryMutantTarget | 44 | RecoveryOnlyVerified | EXPECTED_FAIL |
| update-gate-cancel/Fixed | 33 | none | PASS |
| update-gate-cancel/OldSplitProbe | 31 | RecoverableCancelReopens | EXPECTED_FAIL |
| update-gate-cancel/UserBlockFixed | 43 | none | PASS |
| update-gate-cancel/OldAdmission | 7 | NoEarlyVoiceRefusal | EXPECTED_FAIL |
| update-gate-cancel/UnboundedDrain | 37 | BoundedDrainResolves | EXPECTED_FAIL |
| update-gate-cancel/NoLedger | 19 | NoSwapWithLedger | EXPECTED_FAIL |
