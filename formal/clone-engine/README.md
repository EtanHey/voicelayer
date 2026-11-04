# Clone lifecycle: exhaustive bounded model

Run `python3 -B formal/clone-engine/check.py`. Uses the checksum-pinned TLC jar
from `formal/tlc.lock.json`; logs stay in `.build.noindex/clone-engine-tlc/`.

| Configuration | Required result | Property |
|---|---|---|
| Fixed | PASS | AtMostOneEngine, NeverKillForeign, StopWins, EventuallyRunningIfAutostart |
| Old | expected temporal counterexample | EventuallyRunningIfAutostart |
| Mutant (skip adoption) | expected invariant counterexample | AtMostOneEngine |

The model separates the observation and kernel reservation steps. A foreign
engine can appear between them; fixed Reserve adopts that winner, while the
mutant adds a second engine. Ready, crash, positive backoff ticks, retry, explicit
Stop/Start/Restart, adoption, foreign exit and Quit are transitions. Stop removes
only the owned engine, clears wanted and cancels timers; Quit leaves foreign
engines alone. `foreignKilled` records an app removal of a foreign engine.

Autostart is ON initially. `wanted` is the current supervision request, which
explicit Stop/Quit revoke. Liveness is the leads-to property: a persistent
request eventually runs, or an explicit Stop/Quit supersedes that request.
Weak fairness covers attempt, kernel reservation, readiness, timer and retry.
Faults/external churn and explicit Restart have a shared finite budget of two:
a permanently broken runtime, never-ending crashes, or endlessly repeated user
restarts cannot reasonably promise eventual readiness. State exploration has
no depth/state constraint. Backoff abstracts the production 1–30-second timer
to two fair ticks; Foundation callbacks carry a generation fence implementing
StopWins. Authenticated PID validation, wall time, environment hygiene, OS
signals and HTTP are tested in source/fake-runtime tests, not proved by TLC.

This is documentary/model evidence, not native installation or acoustic proof.
The dictation lead owns independent design-conformance review.
