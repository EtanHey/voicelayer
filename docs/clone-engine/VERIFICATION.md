# V10 verification boundary

Implementer: GPT-6.1 Sol, high effort, T3 Code Nightly; M1 isolated worktree.
Owner/reviewer: dictation lead. No reviewer was spawned by the worker.

## Evidence so far

- RED commit `7f21b877`: Bun accepts-start contract fails (`null`); 2 pass / 1 fail.
  Swift fails to compile because the supervisor/probe types do not exist yet.
- Focused Swift before the additional wire/restart cases: 6 passed, 0 failures.
- Focused Bun: 5 passed, 0 failures, including standard correlated acknowledgements and a real kernel listener reservation
  under fake Python app/HTTP runtime. A competitor exits 1 before app construction;
  the winning fake remains healthy on its isolated OS-selected port.
- TypeScript `bunx tsc --noEmit`: exit 0.
- Fixed TLC: 105 states generated / 40 distinct / 0 pending, exit 0.
- Old TLC: 55 generated / 26 distinct, exit 13,
  `EventuallyRunningIfAutostart` violated (expected adverse receipt).
- No-adopt mutant TLC: 20 generated / 15 distinct, exit 12,
  `AtMostOneEngine` violated (expected adverse receipt).

- Full unfiltered Swift via `heavy.sh`, before final production-policy/slow-health hardening:
  2,559 tests, 73 skipped, 0 failures, exit 0. Compiler warning occurrences: 80,
  retained in the raw output (Sendable/actor-isolation and existing test warnings).
- Final focused Swift after that hardening: 11 tests, 0 failures, exit 0.
- The final hooked push reruns the full suites against the final source tree;
  its terminal receipt is included in the PR body.

The standalone full Bun run was still executing at this receipt commit; its
terminal result and the final hooked full-suite result are recorded in the PR body. Raw worker logs reside in
`.build.noindex/v10-results/`; TLC logs in `.build.noindex/clone-engine-tlc/`.
An early fixture run crashed on SwiftPM's flattened resource location (corrected).
Another fake-import test used macOS Python 3.9, which cannot parse the existing
Python union annotations; it now resolves modern python3 from the test PATH.
A runner attempt also found macOS /usr/bin/java is an unconfigured stub; the
runner now prefers the installed Homebrew JDK and has passed all three cases.
These adverse receipts are retained, not relabelled successful.

## Surface ledger

- Entry points: VoiceBar opening, direct Settings command, socket peer command,
  Python CLI. Native production startup only enables for the resident bundle ID,
  singleton/live socket, no test prefs/QA overrides. Fake entry point tests cover
  kernel bind races; no live entry point was run.
- Clients: VoiceState receives local state and decodes additive events; socket
  peers receive cached on-connect state and requester-only ack. Old clients can
  ignore the new event. The MCP child receives no lifecycle commands.
- Providers: Qwen lifecycle only; Edge fallback, synthesis and recording providers
  are unchanged. Fake HTTP never synthesizes or plays audio.
- Contracts: TS command parser, additive status type, Swift snapshot validation,
  local command routing, on-connect replay, and authoritative event protection.
- Reverse states: Stop cancels queued/in-flight work; manual Start after default
  OFF; adopted Stop/Restart rejection; crash backoff; owned quit; foreign quit; degraded HTTP after readiness leaves an active reply alive.
- Connection modes: socket connect/reconnect uses the retained snapshot; HTTP
  refuses unknown occupied endpoints; launch failure retries. QA apps skip live
  lifecycle ownership rather than inheriting the resident port.
- Docs: CURRENT inventory, U3 contract/ownership policy and formal assumptions.

Installed/native real-agent acceptance, actual Qwen execution, warm-model status,
acoustic quality and release proof are NOT_RUN. The mission explicitly forbids
replacing the installed app, touching live sockets/launchd or exercising the
resident engine. No UI views, capture mechanics, personal profiles, launchd
entries, Homebrew ledger or installed app were edited. Speaker output was observed
muted at volume 0; no voice tool or playback command was used.


## Round 1 changes requested (3 items)

The pre-review head is `84f6b656`; it is not the reviewed/fixed head. New RED
coverage starts at `cf0c7318`. The follow-up implementation is identified by the
PR's Review record, with no force-push.

1. Stop/Restart and inspect retirement now run termination/waits/SIGKILL on a
   utility worker, then publish on main. The exact retiring Process remains
   retained and gates replacements; newer intents supersede stale completions.
   Quit alone waits synchronously, with 3-second graceful and 1-second forced
   bounds and an observable stop_timeout failure.
2. Four consecutive preflight/early-exit failures before health latch failed
   with python_missing, script_missing, script_unresolved, launch_failed(code),
   exited_early(status), or startup_timeout(status). Verified health resets the
   budget; Start/Restart or a new app opening releases the latch. An unverified
   occupied endpoint fails closed until explicit retry.
3. The owned child's stdout/stderr and timestamped exit/preflight causes append
   to a private 1 MiB log plus one 1 MiB rotated file, including continuous
   output and oversized legacy files. Log I/O and pipe drains run off-main.

Focused coverage includes a SIGTERM-ignoring fake child with main-loop progress,
Start/Stop during retirement, late-adoption fencing, failed-retirement custody,
four-attempt missing-runtime/exit-code exhaustion and manual recovery, real
stdout/stderr capture, append preservation and rotation. All engines are fake;
all ports/state/logs remain isolated. No native/live qualification was added.

The model now retains owned engines through asynchronous Reap. Fixed exhausts
134 generated / 48 distinct states with all original properties plus
RetireRetainsOwner and EventuallyStopped. Old still fails autostart liveness
(55/26, exit 13), no-adopt still fails AtMostOneEngine (20/15, exit 12), and the
new unreaped mutant fails EventuallyStopped (126/48, exit 13). These failures are
expected adverse witnesses, not positive model runs. The model assumes an
eligible runtime and fair OS reap; permanent setup failures and bounded-stop
failure are handled by the focused tests and the explicit failed state.
