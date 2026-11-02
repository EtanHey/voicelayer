# PTT silence deadline — D3 11:00Z ruling

Recording times out only after ten minutes of continuous silence, including
silence at the start. Speech renews the deadline. There is no wall-clock cap
while speech remains active or recurs before the silence deadline.

One Tick represents one quiet minute. The wall counter saturates beyond the
former 20-minute boundary as an observation monitor, not a stopping condition.
Repeated speech can therefore keep the finite model recording indefinitely.
`ReintroducedCapMutant` restores a wall-clock cap and must fail
`RecurringSpeechNeverTimesOut`. `NoTimeoutMutant` disables the silence handler
and must fail `SilenceTimesOut`; a missing timeout cannot hide behind a cap.

The retained properties check renewal, qualified silence, settlement, complete
archive equality and raw text/PCM sequence equality. The sequence is a small
bounded sample, not proof of actual audio-byte durability. `CapStops` and its
old `NoCapMutant` are explicitly retired by Etan's new ruling. All ownership and
readability properties in the separate RuntimeOwnership model are unchanged.

Run through the recording-stack entrypoint, which preserves the full union:

```sh
~/.local/state/captain-2.2.61/heavy.sh G bash formal/record-while-processing/check.sh --record
```

No real mic, audio output, installed app or private archive is used. This model
checks the design; the recording source replay does not simulate ten real minutes.

## Source boundary at integration `1e6377b1`

| Model action | Production seam |
| --- | --- |
| `Frame(TRUE)` | `src/input.ts:2809`: classified speech renews `pttLastSpeechAtMs` |
| `Tick` / silence `Timeout` | `src/input.ts:2595`: remaining silence deadline; `:2676`: timer starts after mic opens |
| Cap regression | `src/input.ts:2678`: old 20-minute timer, superseded by this design ruling |
| Complete archive / raw transcription | `src/__tests__/input-durability.test.ts:902`: isolated PCM/archive/decoder fixture |

The pinned source still uses 60 seconds and a hard cap. Lane I owns its runtime
policy update; these models specify the newly authorized design, rather than
claiming that the pinned source already implements it. Temporal properties assume
fair clock, timeout and decoder settlement; archive failures and speech-classifier
accuracy remain outside this small model.
