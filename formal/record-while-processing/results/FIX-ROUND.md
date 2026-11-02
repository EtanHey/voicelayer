# Lane I last fix round — merged verification receipt

Status: FIXED in lane/i-record-while-processing. Integration parent:
`4f932a96081c95236c3c8e3a2e16e304a95282df`; merged source commit:
`ccc2ec713ee968299296da4861ccb9fadd0283b8`. The final receipt commit only
refreshes proof artifacts. No push, PR, installed-app replacement, microphone,
audio emission or input synthesis was performed.

## Findings and changed production lines

| Finding | Fix and production lines | Behavioral proof |
| --- | --- | --- |
| F1 | `src/socket-handlers.ts:516` gates ACK expectation on supplied take_id; `src/recording-jobs.ts:143` broadcasts/settles legacy clients | recording-review-regressions F1: two legacy takes both decode without ACK |
| F2 | `VoiceState.swift:2009` selects newest processing take, guard if not displayed; main model `RecordWhileProcessing.tla:151` | Swift ownership + complete cancellation corpus; EscapeMic/EscapeOlder mutants |
| F3 | `src/recording-jobs.ts:63` try/finally; `recording-take-queue.ts:84` terminal failure, bounded exit proof, visible recovery error | throw-before-handoff + unconfirmed exit/late proof + real capture archive-failure fixture; FailedMicMutant |
| F4 | `VoiceState.swift:2004` falls through legacy body without a managed owner | legacy voice_ask cancel after capable snapshot |
| F5 | `VoiceState.swift:3399`, `:3412`; `SocketServer.swift:497` clear job state on disconnect/new command owner before snapshot | reconnect/older daemon ownership test |
| F6 | `VoiceState.swift:2643`, `:4267`, `:4588` retain/revalidate captured target, no owned activation; `CommandModeAXHelper.swift:97` captures exact app/window/element; `SynthesizedKeyEvents.swift:9` checks before posting; `VoiceBarApp.swift:1318` wires guarded typing | native, terminal and Electron changed-target fixtures; zero wrong-target posts/activations; exact History note; Retarget/FocusSteal mutants |
| F7 | `src/recording-jobs.ts:143` 30s ACK bound and metadata callback; `VoiceState.swift:4631`, `:4769` watchdog records unverified while keeping actual writer mutex | bounded missing ACK keeps full archive/transcript, releases FIFO; late completion ACK once; NoAckBoundMutant |
| F8 | `src/input.ts:2571`, `:2595`, `:2680`, `:2809`: 60s continuous silence renewed by speech, 20min hard cap, both retain/transcribe; `CLAUDE.details.md:63` changeable D3 decision | simulated-clock continuous speech, 60s silence, full 20min cap fixtures; NoRenewal/NoCap/WallClock mutants |
| F9 | `VoiceBarCommandRouter.swift:136`, `:165`; `VoiceState.swift:3395`; `src/socket-handlers.ts:463` visible drain rejection | native drain notice fixture and socket admission; SilentDrainMutant |
| F10 | `VoiceState.swift:4399` restores single terminal trailing-newline strip, keeps all other raw text | terminal/Electron newline fixture |
| F11 | default `conformance.sh`, package test includes formal, checksum-bound checked-in corpora; `LaneGFormalConformanceTests.swift:9`, `LaneIFormalConformanceTests.swift:51` | 391 wire contexts across Current+Fixed; Fixed 120/120 zero divergence; 61 native cancellation classes; no replay skips |
| F12 | main `RecordWhileProcessing.tla:151`, `:153`; runtime `RuntimeOwnership.tla:68`, `:70`, `:75` adds newest/stale guard and ACK-bound settlement without ACK fairness | all three surviving guard probes killed; ProcessingSettles and DeliveryAckBound exact-property mutants |
| F13 | `VoiceState.swift:4063` immediate final path; removed pendingRecordingIdleAfterFinal and unused minimumTranscribingDisplayDuration API/callers | default immediate-final/deferred-drop replay; complete Swift compile |
| F14 | `src/input.ts:3035` empty failure archive uses recording-failed reason/status; archive types/scanner label match | focused zero-byte recording failure archive fixture |

Paths without directory prefixes above are under flow-bar/Sources/VoiceBarUI,
except VoiceBarCommandRouter/CommandModeAXHelper/SynthesizedKeyEvents/SocketServer/
VoiceBarApp under flow-bar/Sources/VoiceBar. Main and runtime TLA paths are under
their corresponding formal directories. Native tests use injected delivery edges;
they do not post OS input or prove installed/live behavior.

## Merge custody and full property union

Lane G's structure remains the main model: ENABLED/action contracts, durable
cancelRequested, speech variable, conditional drain liveness, pinned TLC runner,
Current+Fixed default replay. A direct manifest comparison against 4f932a96
preserves all **19 original properties and all 37 original configurations** with
identical role/target/kind, including all 27 original G mutants. Lane I adds the
newest/stale contracts, ownership refinement and exact PTT budget/cap module.
**No property dropped.** All legacy Old* historical FAIL receipts remain.
The complete per-mutant table is [UNION-MUTANTS.md](UNION-MUTANTS.md).

| Model | Fixed states | Mutants killed |
| --- | ---: | ---: |
| record-while-processing | 7,613 | 32/32 |
| record-while-processing-runtime | 35,914 | 11/11 |
| ptt-silence-timeout | 8,318 | 6/6 |
| Union | | **49/49** |

The main model's result event is paste dispatch, not proof of inserted characters.
The ownership supplement models notInserted on target change/focus theft and
bounded unverified settlement. The PTT supplement models both silence and hard-cap
stops. TLC uses no depth/state truncation. Every mutant fails its exact property;
an unexpected mutant pass, wrong property, missing config or changed source fails
check.sh. Witness queries prove overlap paste and scoped cancellation reachable.

Lane D merge: last_stt_gate_removal is written after each successful live/archive/
retained/Ask transcript commit (`src/input.ts:3581`, `:4538`, `:4661`, `:4365`).
Gate-removal facts never populate not_transcribed_*; all 195 durability tests pass.

## Exact focused commands and results

Run from repository root unless a cd is shown. Bun uses normal bunfig preload,
isolated paths and the silent recorder fixture. All heavy commands use Lane I's
machine-wide serialization wrapper.

```sh
bash formal/record-while-processing/check.sh --record
# Fixed/N8Fixed/Current positive configurations PASS; 49/49 exact-property mutants
# killed; six historical regressions and two event witnesses fail as required.
bash formal/record-while-processing/conformance.sh
# Bun: 5 pass, 0 fail (Current strict historical mismatch; Fixed zero divergence).
# Swift via heavy.sh: 9 tests, 0 failures, 0 skips; both native corpora run.
~/.local/state/captain-2.2.61/heavy.sh I bun test src/__tests__/input-durability.test.ts
# 195 pass, 0 fail.
~/.local/state/captain-2.2.61/heavy.sh I bun test src/__tests__/recording-review-regressions.test.ts src/__tests__/recording-jobs.test.ts src/__tests__/recording-take-queue.test.ts src/__tests__/socket-protocol.test.ts src/__tests__/socket-handlers-idempotency.test.ts src/__tests__/socket-stop-queue.test.ts
# 100 pass, 0 fail.
cd flow-bar
~/.local/state/captain-2.2.61/heavy.sh I swift test --scratch-path .build.noindex/swift --filter 'RecordingJobOwnershipTests|SynthesizedKeyEventsTests|CommandModeAXHelperTests|SettingsHistoryArchiveTests|SettingsArchiveScannerTests|VoiceBarCommandRouterTests'
# 98 tests: 8 SettingsHistoryArchive + 90 ownership/router/AX/typing; 0 failures.
cd ..
nice -n 19 bun run typecheck
# tsc --noEmit, exit 0.
git diff --check
# exit 0.
```

Small text execution logs are local in docs.local/lane-i/merged-*.log. The full
suite was not run, per captain's focused-only rule. No installed/live acceptance
claim. Captain owns integration, cross-vendor final disposition and release.
