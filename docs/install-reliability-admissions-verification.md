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

The OS identity sample reads Darwin proc_bsdinfo's microsecond start time. The
real-child case proves disappearance through the real process probe; injected
probes force reuse and unverifiable cases deterministically. Legacy records
without start time cannot prove PID reuse and remain unless ESRCH proves absence.
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
