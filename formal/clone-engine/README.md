# Clone lifecycle: exhaustive bounded model

Run `python3 -B formal/clone-engine/check.py`. Uses the checksum-pinned TLC jar
from `formal/tlc.lock.json`; logs stay in `.build.noindex/clone-engine-tlc/`.

| Configuration | Required result | Property |
|---|---|---|
| Fixed | PASS | AtMostOneEngine, NeverKillForeign, StopWins, EventuallyRunningIfAutostart |
| Old | expected temporal counterexample | EventuallyRunningIfAutostart |
| Mutant (skip adoption) | expected invariant counterexample | AtMostOneEngine |
| Unreaped | expected temporal counterexample | EventuallyStopped |

The model separates the observation and kernel reservation steps. A foreign
engine can appear between them; fixed Reserve adopts that winner, while the
mutant adds a second engine. Ready, crash, positive backoff ticks, retry, explicit
Stop/Start/Restart, adoption, foreign exit and Quit are transitions. Stop clears wanted and timers, then retains the owned engine in `retiring`
until fair Reap removes it. Start may supersede Stop but cannot spawn until that
retirement finishes. `RetireRetainsOwner` checks custody; `EventuallyStopped`
requires completion unless a new Start supersedes the request. Quit leaves
foreign engines alone. `foreignKilled` records an app removal of a foreign engine.

Autostart is ON initially. `wanted` is the current supervision request, which
explicit Stop/Quit revoke. Liveness is the leads-to property: a persistent
request eventually runs, or an explicit Stop/Quit supersedes that request.
Weak fairness covers attempt, kernel reservation, readiness, timer, retry and
Reap. The unreaped mutant disables completion and must fail EventuallyStopped.
Faults/external churn and explicit Restart have a shared finite budget of two:
a permanently broken runtime, never-ending crashes, or endlessly repeated user
restarts cannot reasonably promise eventual readiness. State exploration has
no depth/state constraint. Backoff abstracts the production 1–30-second timer
to two fair ticks; Foundation callbacks carry a generation fence implementing
StopWins. Authenticated PID validation, wall time, environment hygiene, OS
signals and HTTP are tested in source/fake-runtime tests, not proved by TLC.
The eligible-runtime liveness assumption excludes a permanent preflight/startup
failure: production latches the fourth such failure until an explicit retry.
That failure budget, specific causes, output rotation and bounded OS-stop failure
are covered by focused tests; the positive model assumes the OS completes Reap.

This is documentary/model evidence, not native installation or acoustic proof.
The dictation lead owns independent design-conformance review.
