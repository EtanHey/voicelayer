# Lane I FIXED-2 — final-round implementation receipt

Status: FIXED; verified source merge `52539fe5da8ba4992a7b3ba95badf2df239f8270`.
Parents are Lane I ba86d623 and the exact
Lane G FIXED-2 0fb80413, not G's later integration merge. No push/PR, installed
bundle change, mic, audio emission or OS input synthesis is authorized/performed.

## P1-A: unreadable identity fallback

An optional captured AX identity now has distinct meanings: nil means unreadable
at capture, a readable closure returning false means changed. Both paths require
the original app PID and bundle to be frontmost. A readable identity must still
match its exact window/element. With an unreadable identity, guarded typing is
allowed only when no mic owner, pending bar take or remote recording exists.
The same predicate is rechecked by the production typing boundary; owned delivery
never activates an app. The existing captured native-cursor decline guard remains
for readable identities; an unreadable identity can use the prior editable-target
fallback. Transcript text is unchanged.

The test helper accepts an unreadable identity provider. New direct tests:

- testUnreadableIdentitySingleElectronTakeTypesExactlyOnce
- testUnreadableIdentitySingleTerminalTakeTypesExactlyOnce
- testUnreadableIdentitySingleGhosttyTakeTypesExactlyOnce
- testUnreadableIdentityWhileBRecordsIsNotInserted
- testReadableDifferentIdentityIsNotInserted
- testUnreadableIdentityCannotFollowSameBundleIntoDifferentProcess
- testUnreadableIdentityFallbackRechecksPendingBAtTypingBoundary
- testXUsesNewestTakeGuardAndCannotBorrowAnotherTakeGuard

The red archive is ba86d623 plus only this test-file patch, with no code fix.
The lead can apply docs.local/lane-i/fixed2-tests.patch to ba86d623 and run the
same focused filter. Green runs the merged implementation. No real typing occurs.

RuntimeOwnership now varies AX readability at Record. The changed
NoDeliveryOutsideCapturedTarget requires readable identities to match, and permits
unreadable fallback only with no mic owner. Existing RetargetMutant still rejects
a known mismatch. UnreadableOverlapMutant rejects unsafe overlap fallback;
UnreadableIdentitySingleTakeDelivers plus UnreadableRefusalMutant prevents the
original over-refusal. No invariant or temporal property was removed.

## P3 dispositions

| Finding | Disposition and reason |
| --- | --- |
| P3-1 X target/guard | FIXED: X chooses the newest processing take and arms/commits that exact take's guard; it cannot borrow A's ready guard to cancel B or B's guard to cancel A. Escape retains its displayed-take bypass. |
| P3-2 shared-helper / split-coverage probes | ⏭ per lead: the independent shared-Newest helper mutant remains a known limitation of the main oracle; native newest-take tests are an independent anchor. EscapeGuarded removal is killed by the ownership model's GuardedEscape check, rather than the main model. The 63/63 gate describes registered exact-property mutants, not the reviewer's independent 13-probe set. |
| P3-3 stale timeout docs | FIXED: removed the default-30s sentence; CLAUDE.details.md now states 60s continuous silence plus 20min hard cap, keeping/transcribing both stops. |
| P3-4 dedicated admission / threshold tests | ⏭ per lead: generic pre-handoff failure and the existing simulated-clock speech/silence fixtures cover the implemented boundaries. No dedicated admission-refusal or p=0.49/0.50 fixture is added; the review's scratch threshold results remain review evidence only. |
| P3-5 unproven recorder exit | ⏭ per lead: a never-proven exit remains visibly blocked until daemon restart; unsafe automatic admission could create two recorders. Documented under Recorder exit remains unconfirmed in docs/voicebar-release-runbook.md. No restart was performed. |
| P3-6 silence vs cap abstraction | Resolved by pinned G FIXED-2 merge: main model has separate timeout/cap reasons, exact ProductClock 60s/20min, renewal/cap bounds and all associated mutants. Ownership and PTT supplements remain. |

## Formal merge custody

G's state/action structure, ProductClock, MutHeldDecode* family, silence/cap
mutants, decode-fairness mutant and pinned Fixed-family divergence assertions are
retained. A manifest comparison against both parents retains all 25 G FIXED-2
and all 21 prior-I main properties, and every configuration with the same
role/target/kind. Fixed runtime policy remains mandatory zero divergence. Unknown
stale take IDs refine the production noop reply, preserving identity fencing.
All original Old* historical FAIL receipts remain. The full post-run union table
is UNION-MUTANTS.md; no property or mutant was dropped.

## Surface sweep

- Entry points: checked owned final delivery, X and Escape through VoiceState/router.
- Clients: Electron/T3, Terminal, Ghostty fixtures and existing native AX ownership tests.
- Providers: readable/unreadable AX paths checked; STT/recorders unchanged in this fix.
- Contracts: captured PID/bundle, optional identity and take-scoped guard; default socket/native corpus replay.
- Reverse states: single take, recording/pending B, readable mismatch, same bundle/new PID, duplicate final.
- Connections: existing reconnect/missing-target and legacy-Ask ownership tests retained.
- Docs: silence/cap text, recorder recovery limit, model readability/custody map updated.

## Commands

```sh
bash formal/record-while-processing/check.sh --record
bash formal/record-while-processing/conformance.sh
~/.local/state/captain-2.2.61/heavy.sh I swift test --package-path .build.noindex/lane-i-fixed2-red/flow-bar --scratch-path .build.noindex/lane-i-fixed2-red/swift --filter 'RecordingJobOwnershipTests/(testUnreadableIdentity|testReadableDifferentIdentity|testXUsesNewest)'
~/.local/state/captain-2.2.61/heavy.sh I swift test --package-path flow-bar --scratch-path flow-bar/.build.noindex/swift --filter 'RecordingJobOwnershipTests|SynthesizedKeyEventsTests|CommandModeAXHelperTests|VoiceBarCommandRouterTests'
nice -n 19 bun run typecheck
```

Execution output is kept in docs.local/lane-i/fixed2-*.log. Installed/live
acceptance is captain-owned and remains NOT_RUN under the lane's hard rules.

## Final results and changed lines

| Check | Result |
| --- | --- |
| Red: ba86d623 + new tests only | 8 executed; 3 passed, 5 expected failing cases, 14 assertion failures, rc 1. The three single-host cases, pending-B boundary and X guard case fail for the intended behavior. No compile failure. |
| Green focused Swift | 98 executed, 0 failures, 0 skips; includes all 17 RecordingJobOwnershipTests and all 8 new cases. |
| Default conformance | Bun 5 pass / 0 fail; Swift 9 executed / 0 failures / 0 skips. Fixed socket: 13 record + 107 cancel contexts, zero divergences. Native: both policy corpora, 8 paths plus 73 ownership cancellation classes. G's visual baseline divergence pins remain strict and unchanged; this is not a claim that Lane A visuals conform to Fixed. |
| Formal union | Fixed main 35,514 states; ProductClock 683; N8Fixed 5,555; ownership Fixed 101,390; PTT Fixed 8,318. All positives PASS. All 63/63 registered mutants fail their exact property. Four witness queries and all historical regressions fail as required. |
| Typecheck | bun run typecheck / tsc --noEmit: rc 0. |
| Diff / local receipt hygiene | git diff --check and check-docslocal-hygiene.py docs.local/lane-i: rc 0. |

| Model | Exact-property mutants killed |
| --- | ---: |
| Main pipeline (full G/I union) | 44/44 |
| Ownership/readability | 13/13 |
| PTT sequence/silence/cap | 6/6 |
| Union | **63/63** |

See [the full property → mutant → result table](UNION-MUTANTS.md). No property or
mutant was dropped. A direct comparison preserves the full 25-property/52-config
G FIXED-2 manifest and 21-property/43-config prior I manifest, including unchanged
role/target/kind for every original check. All recorded source/config/tool hashes
match this verified merged source. Final proof-only changes do not change runtime.

- P1-A: VoiceState.swift:4589 (readability-aware PID/bundle and ownership predicate),
  :4545 (posting-boundary recheck), :4443 (readable native-cursor decline guard).
  RecordingJobOwnershipTests.swift:14 exposes identity injection; :271–316 adds
  the unreadable, changed-identity, duplicate, process-change and pending-B checks.
- P3-1: VoiceState.swift:2009 selects newest X target; the guard/cooldown transaction
  still commits only its exact take. RecordingJobOwnershipTests.swift:319 verifies
  A's ready guard cannot cancel B and B's guard cannot cancel A.
- P3-3: CLAUDE.details.md:64 replaces the stale default-30s line.
- F6 model refinement: RuntimeOwnership.tla:20 samples readable identity at Record;
  :31 chooses delivery/fallback; :72–77 checks target safety and fallback availability.
- P3-5 documentation: docs/voicebar-release-runbook.md:151 records honest blocked
  recovery and the need for an idle-safe daemon restart if exit never proves.
- P3-6/G: RecordWhileProcessing.tla retains ProductClock and all exact silence/cap,
  renewed-speech, held-decode and decode-fairness contracts from 0fb80413.

The isolated red VoiceState Git blob equals ba86d623's
`82c89f7c4c40a4274737d6cbda72fb1d5a48b6fe`; the identical red/green test file
SHA256 is `3b41c3389561514695d682dc6de73279d640021a1db3088524717353773b420f`.
The archive and build caches are removed after verification; the small red/green
logs and test-only patch remain under docs.local/lane-i for the lead's direct replay.
