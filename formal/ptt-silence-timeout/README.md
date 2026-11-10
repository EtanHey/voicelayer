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

## Recording pause (Etan, 2026-11-08)

Pause/Resume extends the same take machine. `Pause` keeps one more frame (the
~200 ms click tail, so a word in flight is not clipped), then frames the mic
still hears are `"aside"` and never join `pcm`. `Resume` continues the same
`pcm`. A paused `Tick` leaves the silence counter alone and `Timeout` is
disabled while paused, so a pause never counts toward the deadline. `Stop` and
`Cancel` (`Finish`) work from either state, archive the whole take and close
the paused span. `said`, `quiet` and `owed` are spec ghosts: the frames owed to
the take, the unpaused quiet minutes, and the tail frame still owed after a click.

| Property | Killed by |
| --- | --- |
| `NoPausedAudio` | `AppendWhilePausedMutant` (the gate admits paused frames) |
| `UnpausedRetained` | `ClipAtPauseMutant` (no click tail), `NewTakeOnResumeMutant` (resume restarts the take) |
| `NoTimeoutDuringPause` | `PauseCountsTowardTimeoutMutant` (paused minutes count), `TimeoutWhilePausedMutant` (timeout ignores the pause) |
| `StopCancelFromPaused` | `NoStopWhilePausedMutant` |
| `PausedSpansClosed` | `OpenSpanMutant` (a take ending paused leaves its span open) |

`SilenceTimesOut` now reads "unpaused silence leads to an end, speech or a
pause": a user who stays paused is not silent ("time out on silence, not on
me"). `NoTimeoutDuringSpeech` is scoped to takes the timeout ended, since Stop
and Cancel now end takes too.

| Model action | Production seam |
| --- | --- |
| `Frame` gate | `src/input.ts` pipe reader: `pauseGate.admit()` before `chunkQueue.push` |
| click tail | `src/recording-pause.ts`: `RECORDING_PAUSE_TAIL_BYTES` (200 ms) |
| paused `Tick` / `Timeout` guard | `src/input.ts`: `activeNow()` deadline clock, `onTimeout` pause guard, re-arm on resume |
| `Finish` from paused | the unchanged Stop/Cancel signal path; `finish()` closes spans into `paused_spans` |

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

## Bare-stop scoping (2026-11-08)

A take now starts `opening` (record accepted, mic not yet open); `Open` applies any buffered control.
`ScopedStop` is the take's own stop (its take id: F5/side button, Stop button, PTT release).
`UnscopedStop` is a stop with no take id (`voicelayer speak --stop`, a read Stop, Hide over speech).
In the fixed design it stops speech only and never touches the capture.

`UnscopedStopNeverEndsCapture`: a dictation capture ends only through its scoped stop or its silence
timeout. Two mutants restore the pre-fix routes and must fail it:

| Mutant | Pre-fix route |
| --- | --- |
| `UnscopedEndsCaptureMutant` | `src/socket-handlers.ts` `hasF5Capture()` branch stamped the live take's id into an id-less stop |
| `OpeningFallbackMutant` | `src/f5-capture.ts` `bufferOpeningCaptureControl(undefined, …)` fell back to the first opening take |

`NoTimeoutDuringSpeech` now constrains takes the timeout ended (`endedBy = "timeout"`), since a take can also end
through its scoped stop. Its mutant (`WallClockMutant`) still fails it.
