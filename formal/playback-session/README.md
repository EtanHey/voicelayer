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
| NoSameQueued | Etan (2026-11-08): Option+F5 on the text being read must dedupe, never queue it behind itself | SameQueuesMutant |
| ParkedEventuallyReleased (temporal, under FairSpec) | #818 review: a read an ask parked is eventually restored or ended, never left parked | NoRestoreMutant |

TeleTracksAudio allows one word event of lag on purpose: the teleprompter learns each word after the audio speaks it
(Advance then TeleSync). It is exact after every TeleSync, and a resume/restore resets it to the stored word.

Option+F5 over a read (OptF5Empty / OptF5Same / OptF5Other, Etan 2026-11-08): an empty selection pauses or
resumes the read, the same text sets the "Already reading this" notice, different text joins the narration queue.

Liveness: `Liveness.cfg` checks ParkedEventuallyReleased under FairSpec, weak fairness on the ask's progress
steps (prompt start/end, mic open, capture end, recorder exit, reap, restore).

`W == 2` keeps Fixed at 655,402 states (teleprompter-handoff checks 677k); every mutant still trips. "Previous read" holds the read on screen (prevHeld) and PrevReturn brings it back paused at its word.

Stop during an ask ends the ask, never the read it parked: the read comes back paused at its word.

Run: `bash formal/playback-session/check.sh` (recorded evidence in `results/`).
