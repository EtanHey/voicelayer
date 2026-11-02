# Ask no-answer deadline — D5 (11:00Z)

Three abstract ticks represent the 120-second post-question budget. `Speech` may
arrive on the last pre-deadline tick (the 119-second case). It permanently disarms
`NoAnswer`; `NormalSilence` may still close the answer. Only the no-answer close
is prohibited after speech. The existing 30-minute safety ceiling and manual Stop
are outside this small model. Captured PCM is archived before the away result.
Fair ticking and no-answer closure model a responsive event loop. Runtime drains
queued/in-flight Silero inference before concluding no speech occurred.

Run through the captain lock:
`~/.local/state/captain-2.2.61/heavy.sh J bash formal/voice-ask-no-answer/check.sh --record`

The shared runner uses `formal/tlc_support.py` and the checksum-pinned
`formal/tlc.lock.json`. Every mutant must fail on its exact property; a passing
mutant or another failure fails the gate. `results/MUTANTS.md` is the receipt.
`OldDeadlineMutant` reproduces the uncancelled wall deadline, not an entire
historical implementation. The other mutants disable closure and archive retention.
