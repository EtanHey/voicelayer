# PlaybackSession (Lane B, VoiceLayer 2.4)

One explicit session machine for Option+F5 reads, `voice_speak` and `voice_ask` narration and the
teleprompter. `src/playback/session.ts` implements the same states, events and invariants;
`src/playback/ledger.ts` is the daemon's single ledger, fed by the player driver in `src/tts.ts`.

States: `queued`, `preparing`, `playing`, `paused`, `seeking`, `parked` (by an ask), `ended`.
Events: start, ready, word, teleprompter sync, end, reap, pause, resume, seek, seek done, Esc,
previous read, ask preempt, prompt start/end, mic open, capture end, ask abort, recorder exit,
ask restore, stop.

Positions are word indices held by the session. `mark` is the ground truth (the word heard when
the read left the speaker); `pausedAt` is what the engine stored; a resume must land on `mark`.

| Invariant | Bug it prevents | Mutant config(s) |
| --- | --- | --- |
| ResumeExact | Etan: "pause sometimes jumps back" (QA 2026-11-08: the pause button rewound to 0:00) | JumpBackMutant, SecondAskMutant |
| OneAudible | two voices at once: a read or the ask prompt starting over a player still exiting | OverlapMutant |
| AskParksOne | "a second voice_ask over a paused read didn't resume": a read left parked after an ask | StrandMutant |
| MicExclusive | the mic records our own audio: prompt still exiting, or a read resumed before the recorder exited (capture-end r2) | EarlyMicMutant, RecorderWaitMutant |
| TeleTracksAudio | "wrong clock": the teleprompter restarting at 0 on resume/restore | ClockResetMutant |
| OneLiveSession | "overlap": previous read starting without ending the current one | PrevOverlapMutant |
| NoZombie | a stopped or replaced preparation still starting its player | ZombieMutant |

`W == 2` keeps Fixed at 275,479 states (teleprompter-handoff checks 677k); every mutant still trips. "Previous read" holds the read on screen (prevHeld) and PrevReturn brings it back paused at its word.

Stop during an ask ends the ask, never the read it parked: the read comes back paused at its word.

Run: `bash formal/playback-session/check.sh` (recorded evidence in `results/`).
