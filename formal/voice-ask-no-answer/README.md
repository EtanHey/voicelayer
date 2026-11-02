# Ask no-answer deadline — D5, final review round

Two abstract ticks represent the configurable post-question no-answer deadline;
one grace tick represents the bounded 2s classification grace. `Capture` may
arrive at the exact deadline and `Classify` later, or `VadStall` may prevent it
from ever finishing. Unknown speech closes as retained/unclassified, never away.
The pending-speech invariant protects actual spoken frames, including at the
same instant as the deadline. The heard-speech invariant protects classified
answers. The stall property requires eventual closure despite stuck inference.

`held` selects a locked Ask, sharing the runtime ten-minute continuous-silence
rule with locked VoiceBar PTT (`SilenceLimit` abstracts ten minutes). Speech
resets silence; there is no wall-clock ceiling. `SpeechCapMutant` restores one.
Unlocked post-speech silence remains independent of no-answer closure.
The model abstracts recorder startup/HOLD pause transitions, which are pinned
by simulated-clock runtime tests. Fair ticks and timer delivery model a live
event loop. Strong timer fairness also covers repeated quiet candidate frames.

Run ONLY on M1 through its captain lock:
`~/.local/state/captain-2.2.61/heavy.sh J bash formal/voice-ask-no-answer/check.sh --record`
Use `/opt/homebrew/opt/openjdk/bin` on PATH. The shared runner imports
`formal/tlc_support.py` and verifies `formal/tlc.lock.json`'s checksum pin.
Each of the seven properties has an exact failing mutant; a passing mutant or
an unrelated failure fails `check.sh`. Evidence is in `results/MUTANTS.md`.
