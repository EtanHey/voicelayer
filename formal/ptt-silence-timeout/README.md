# PTT silence deadline (Lane I)

`bash formal/ptt-silence-timeout/check.sh` checks the fixed design and every
per-property mutant. Any unexpected pass, wrong invariant, missing config or
changed source during checking fails the runner. One worker, 512 MB heap,
fixed seed/fingerprint, no depth/state constraint. Receipts are in `results/`.

This model is deliberately separate from Lane G's concurrent-lifecycle model.
The real PTT path in `src/input.ts` now runs speech detection to renew its
silence deadline. It starts the budget after mic opening and defers timeout
while PCM classification is outstanding. Detection failure disables this
silence timeout; explicit stop/cancel and retention remain available. VAD does
not select PTT audio, change the physical-stop drain, or trim any words.

`Frame(TRUE)` maps to the PTT `processVADChunk`/`isSpeech` branch updating
`pttLastSpeechAtMs`; `speech` is a fresh observed-speech interval and each
`Tick` ages that observation and its silence budget (continued speech supplies
new frames and renews it); `Timeout` maps to
`onTimeout`'s silence-budget check and `finish`. `saved` represents the complete
archived sequence and `Transcribe` the complete decoder input/output contract.
Actual speech recognition accuracy is outside this model. The fixture in
`input-durability.test.ts` feeds synthetic PCM through the real capture/archive/
STT path, advances five virtual minutes beyond the former 90s cap, and checks
all captured PCM bytes reach both the archive and decoder after silence.
No real microphone, audio emission, installed app, or live recognition proof.

| Property | Mutant | Required result |
| --- | --- | --- |
| `NoTimeoutDuringSpeech` | `WallClockMutant` uses total wall time | invariant FAIL, TLC 12 |
| `EveryEndedTakeRetained` | `DropArchiveMutant` loses the archive | invariant FAIL, TLC 12 |
| `RawAccurate` | `TrimWordsMutant` omits the final captured symbol | invariant FAIL, TLC 12 |
| `SettlesAfterSilence` | `StallMutant` never transcribes an ended capture | temporal FAIL, TLC 13 |

`Fixed` checks all four. `SettlesAfterSilence` concerns an already ended
silence-timeout capture reaching transcription with fair backend settlement;
continuous speech may remain recording forever. This bounded model does not
prove filesystem durability on disk failure, VAD accuracy, or backend liveness.
