# Speech queue verification

Status: bounded backend verification; **the four installed-app bugs remain unresolved**. No product fix, install, microphone, speaker, live socket or private archive access is part of this change.

Run `formal/speech-queue/check.sh` from the repository. Requires Python 3, Bun dependencies (`bun install --frozen-lockfile`), Java and `~/.local/bin/tlc`. Tested with the existing tla2tools-1.7.4.jar launcher, which reports TLC2 2.19, revision `5a47802`. Logs, graph and generated replay corpus stay in a unique `.build.noindex/formal-speech-queue/run-*` directory. An unexpected TLC result, parse failure, timeout or real-code mismatch exits nonzero.

## What changed from TLA3

The October 20 model treated QUEUE1 as a proposal, replaced the user chain on main, and assumed stale receipts were ignored. This extracts and refines its QUEUE1 actions against the implemented `SelectionReadQueue`: append/replace, scoped Next, all settlement outcomes, F5 suspension, explicit Stop, direct ownership and published counts. The older priority-player, parked-audio and capture-admission models are **not** revalidated or silently imported here. Source anchors and their sync SHA are in [coverage.json](coverage.json).

Four fresh request IDs, two pending slots and eight operations are explored; four IDs make overflow reachable. Every request deliberately has identical text and text hash in the real-code replay. Successful starts return immediately without audio or archive context. Each synchronous start also delivers the former owner's stopped receipt before returning, exercising ownership-before-preemption. Failures of the start callback and async preparation are outside this model.

TLC checks unique ownership/starts, count publication, stale Next rejection and Stop clearing the chain. `check.py` exports the current reachable graph, finds a shortest prefix for each state, and replays **each outgoing edge** from that prefix against the actual production class. It compares start IDs, pending count, published owner/count and return value. This is bounded observational conformance, not every possible trace, a refinement proof, real player execution or macOS acceptance. The ordinary Bun suite skips the generated-corpus test; `check.sh` makes it mandatory.

## Expected counterexamples

`StaleNext.cfg` deliberately removes Next ownership validation. Its shortest trace is an idle queue receiving Next for request 1: it returns stopped instead of stale. With a live chain, the same missing guard lets an old Next skip the new owner. `Current.cfg` requires `StaleCannotAdvance`; the broken config must fail that exact invariant, not merely exit with any error.

`StopLeaves.cfg` deliberately retains pending items in Clear. Submit A, append B, then Stop leaves B queued and violates `StopClearsQueues`. This is checker sensitivity, not evidence that the current source has that defect. The real-code experiments below are the separate source-fidelity check.

`History.cfg` checks the current nine-state relation in `src/speech-state.ts:4-10,25-34` for four operations. `FirstAcceptedTerminalImmutable` freezes both the first terminal state and the accepted-transition count; even a repeated terminal cannot add another accepted edge. The conformance harness executes the real transition function and checks state plus transition count. It does not model producer routes, retries, durable writes or reasons/timings. Existing producer-route fixtures and runtime code remain unchanged. `MutableTerminal.cfg` accepts later terminal transitions and must violate this invariant: accept stopped, then accept completed, overwriting the first terminal.

## Real-code scratch experiments

The production source was saved byte-for-byte, edited only in this worker checkout, and restored in a `finally` block after each experiment. The live installed application was never changed. The full `check.sh` still passed the corresponding current TLC config (`Current.cfg` or `History.cfg`), **then failed its mandatory real-code conformance test**. This distinction matters: TLC does not read TypeScript; the adapter connects its transitions to the source.

1. In `SelectionReadQueue.next`, change `if (!requestId || requestId !== this.current) return "stale";` to `if (!requestId) return "stale";`. The idle Next trace disagrees on the return value. A stale Next can also consume a pending successor once a different request owns playback.
2. In `SelectionReadQueue.clear`, change `this.items = [];` to `this.items = this.items;`. The first mismatching replay is submit A, append B, replace with C (opcodes `1,2,7`): B survives the replacement's Clear and the published count stays 1 instead of 0. Explicit Stop uses the same Clear helper and is also covered.
3. In `src/speech-state.ts:9`, change `stopped: []` to `stopped: ["cancelled"]`. The real transition function now accepts stopped then cancelled: expected stopped/one accepted move, observed cancelled/two moves. `History.cfg` conformance fails. Restored source SHA256: `f052ef9455a2d6a8baed20c0c28d71420ab27ff60bfd12469ab0c6c5d762bd42`; queue source: `f4573ad6f63c8a53d0cafc3271557291cad690b9edfb7699afd08ae75f2d8247`.

The restored baseline passed: `Current.cfg` explored 11,163 states and 148,728 real-code edge replays; `History.cfg` explored 297 states and 1,368 real-code edge replays. All three negative configs violated exactly their expected invariant. `bun run typecheck` passed. Neither model assumes fairness or proves liveness; stuttering and the explicit operation bounds are allowed. These are intentional negative experiments, not live-bug reproductions.

The unchanged fixtures passed, 301 tests / 0 failures, with the canonical preload:
```sh
bun test src/__tests__/{selection-read-queue,socket-stop-queue,wordtime-history,speech-state,speech-state-store,speech-state-followups,mcp-speak-archive-ingress,socket-raw-speak-archive-ingress,cli-local-speak-archive-ingress,ask-preview-speak-archive-ingress}.test.ts
```

## Live bug disposition

**1. Same text playing/queued breaks the queue — outside the ingress boundary.** The backend model and identical-text conformance pass: this class uses request IDs and never compares text hashes. Swift explicitly compares the latest submitted selection and the playing selection in `flow-bar/Sources/VoiceBarUI/VoiceState.swift:1262-1282`, then calls `stopSelectionRead()` on equality before enqueueing. Fresh selections use a UUID at line 1303. This matches the older TLA3 same/empty-means-Stop contract and can explain clearing the chain, but does not prove the recordings' exact failure. Swift capture/receipt races, non-latest queued matches, and repeated client IDs are unmodelled; a source-level queue pass does not clear them.

**2. Pause/Play/Next/Stop “nothing sticks” — partly covered, live cause unproven.** Backend Next, Stop, stale settlements and F5 suspension conform within the bound. Pause/Play operate on the separate player lifecycle: `src/socket-handlers.ts:190-200` routes scoped controls to `pausePlayback`/`resumePlayback`; `src/tts.ts:1292-1401` parks/releases audio and fences generations. Those async player, socket, ack and Swift UI states are absent here. No installed control interaction was performed, so this report cannot identify or clear the live cause.

**3. Replay after completion loses markdown — outside queue ownership.** Fresh selection ingress projects structured display in `src/socket-handlers.ts:219-235`. The idle replay branch at `src/socket-handlers.ts:324-335` instead retrieves history and supplies text, voice and timings; it supplies no structured display. The separate retained-readback path preserves more metadata (`src/tts.ts:2154-2188`). This is a concrete source-path mismatch to investigate, not a formatting reproduction or fix; the model has neither display payload nor renderer.

**4. History stuck Playing/PID reuse — outside in-memory queue state.** `src/speech-archive-recovery-worker.ts:43-47` trusts numeric-PID liveness via `process.kill(pid, 0)` and skips recovery when that PID exists, without process-start identity. `flow-bar/Sources/VoiceBarUI/SettingsSpeechHistoryArchive.swift:101-118` renders the stored playing state. A reused PID can therefore evade that recovery branch, but no private entry or restarted daemon was tested. Durable writer/recovery ownership needs its own model and real recovery regression; a queue pass provides no History proof.

The brief's optional B-queue QA findings file was absent during source reconnaissance. No video-derived claim is made. Use `/statechart` to interpret TLC traces and `/maintain-formal-verification-skill` when updating the model: reread mapped source, rerun conformance and negative experiments, then advance `sync_sha`; do not weaken an invariant to clear a source finding.

## API constraints for NL T3 alignment

**Current verified properties:** Next and settlement are fenced by request ownership; Stop forgets all queued work; identical text/hash with distinct accepted request IDs stays distinct in the backend; a History record's first accepted terminal status is immutable. Preserve the existing History producer-route fixtures. These checks do not transfer VoiceLayer's admission, microphone, UI or History ownership to an engine.

**Future contract properties, not established by these models:** fence every attempt and playback generation so late results cannot commit or revive cancelled work; check cancellation before commit (client abort is not confirmed backend drain); retain the Stop and accepted-request identity guarantees across the adapter; keep first accepted History terminals immutable across producers and retries; carry the original structured display through completed-read replay. Current Swift same-text-means-Stop ingress and idle replay metadata loss remain findings above, not claims that those future properties hold today. No clone adapter or NarrationLayer migration is implemented here.
