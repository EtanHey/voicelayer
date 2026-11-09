# Dead admission retirement: local evidence

Base: `849483ae6f04f0edc8310fcab1793c6e7614c0d0` (`origin/integration/2.3`).

- Fail-first: the new eight-case suite with the baseline admission implementation
  fails 8/8, including an actual exited Bun child whose registration blocks REQUEST.
- Fixed focused suites: 83 pass, 0 fail, 626 assertions across four files:
  `update-gate-reap`, `update-gate-admission`, `update-gate-storage`, and
  `update-gate-installer-participant` under `src/__tests__/`.
- Focused native: `swift test --package-path flow-bar --scratch-path
  .build.noindex/swift --filter NativeUpdateGateTests`: 9 tests, 0 failures.
  Existing Swift concurrency warnings remain in unrelated files.
- `bun run typecheck` and `git diff --check`: exit 0.
- `PATH="/opt/homebrew/opt/openjdk/bin:$PATH" python3 -B formal/check-model.py
  formal/update-gate --record`: 27 expected outcomes (7 positive passes,
  20 designated mutant violations). Normalized logs and source hashes are in
  `formal/update-gate/results/`. New checks: ReapFixed passes 304 states;
  ReapMutantAge violates NeverReapLiveOwner; ReapOld violates
  DeadRegistrationsCanPrepare.

The OS identity sample now reads sysctl KERN_PROC_PID microsecond start time for any user. The
real-child case proves disappearance through the real process probe; injected
probes force reuse and unverifiable cases deterministically. Legacy records without start time prove reuse only when the current PID birth is strictly later than the record mtime. Equal/earlier/unavailable evidence remains blocking.
Reason-file publication failure retains the original record; crash durability
of retirement evidence is not established by the model.

Surface sweep: entry points are updater commands and drain ACK snapshots under
G1; clients are installer/daemon/CLI through the shared adapter; provider is
Darwin process identity (unsupported platforms keep unknown owners); contracts
retain locked empty-ledger checks; reverse states retain live/unknown/malformed
owners and never reap locks; connection modes share the same adapter; admission
documentation and G3 known gaps are updated. P0 DRAINING admission and bounded
wait behavior are unchanged; lead resolves integration with that branch.

NOT_RUN: full pre-push suite, routed review, native installed app and real-agent
qualification. No live VoiceBar, gate, socket, preferences or recording touched.

## Round 2

Against 02c4174e, the 11-case R2 suite has 3 pass / 8 fail. On the fix,
all 11 pass; the five focused suites total 94 pass / 0 fail, 648 assertions.
RED defects: cross-user sysctl 1, EPERM reuse 2, strict legacy mtime 1,
minute-throttled log 1, failed-reap reason 1, retention bound 1, zombie 1.
The three equal/earlier/unknown mtime controls already passed and stay passing.
Source command: `nice -n 10 bun test src/__tests__/update-gate-reap-r2.test.ts
src/__tests__/update-gate-reap.test.ts src/__tests__/update-gate-admission.test.ts
src/__tests__/update-gate-storage.test.ts src/__tests__/update-gate-installer-participant.test.ts`.
The sysctl test reads PID 1 on this Mac, rather than mocking the OS accessor.
The retirement test seeds 52 proofs and checks the newest 50, a retained live
admission and an untouched symlink. Zombie retirement requires positive SZOMB.

TLC rerun: 27/27 expected outcomes, including expanded ReapFixed PASS (1452
states), ReapMutantAge EXPECTED_FAIL NeverReapLiveOwner (259 states), and
ReapOld EXPECTED_FAIL DeadRegistrationsCanPrepare (512 states). All normalized
receipts/source hashes refreshed with `formal/check-model.py formal/update-gate
--record`. `bun run typecheck` passes.

P0 alignment: per-token ledger diagnostics report only registrations, once per
minute. P0's phase-change summary reports native/daemon participants. No extra
participant list is introduced here. Lead regenerates shared formal receipts
after merging A, B and P0. Native installed/live proof remains NOT_RUN.
