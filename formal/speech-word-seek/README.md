# U5 word timing and seek contract

The logic is additive. VoiceBar UI integration is a separate lane.

```json
{"type":"state","state":"speaking","utteranceId":"long-read-123-1"}
{"type":"speech_words","utteranceId":"long-read-123-1","wordOffset":0,"words":[{"text":"Hello","startMs":100,"endMs":300}],"approximate":false}
{"cmd":"speech_seek","utteranceId":"long-read-123-1","wordIndex":0,"id":"click-1"}
{"type":"ack","command":"speech_seek","id":"click-1","outcome":"accept","offset_ms":100,"clamped":false}
```

Clients upsert `words` starting at the zero-based global `wordOffset`. All times
are absolute milliseconds from the utterance's original audio start. A long read
keeps the same ID across chunk handoffs and seeks; a replay gets a new ID. Chunks
are published as synthesized, before or at playback, and later clone alignment
replaces the same word indices. Unsynthesized words cannot be sought yet. Keep
the approximation flag per update range. A new speaking ID replaces the client's
old table. Preparing events have identity but no audio clock; playing state uses
the existing `playback_offset_ms` and duration fields to anchor that clock.

Edge uses its existing WordBoundary events, projected onto display tokens. Qwen
starts with proportional timing over the synthesized duration, explicitly marked
approximate, then publishes existing forced-alignment results when available.
Partial/invalid alignment retains approximate fallback for missing tokens.

Both engines reuse the original synthesized file. The existing seek pipeline
prepares an ffmpeg PCM slice with `-ss`, cancels superseded preparations, and
waits for the old player's physical exit before starting the replacement. This
preserves delivery and avoids synthesis cost or network latency. Seek acceptance
is admission, not proof that decoding/player startup succeeded; existing
`error` events with `source: "seek"` report later failure. Stop cancels preparation;
the identity is checked before a seek can touch the current audio. Paused and
busy playback reject word seeks. Optional command IDs deduplicate the last 32
accepted requests per utterance; reuse with another word is refused. Unkeyed
clicks are absolute cursor assignments and may intentionally replay the same word.
The old `seek`, `subtitle` and playback state contracts are preserved. Older
VoiceBars ignore the unknown event in `VoiceState.handleEvent`'s default arm.

Run `python3 formal/check-model.py formal/speech-word-seek` (add `--record` only
to refresh committed evidence). The model bounds two unique utterances and four
arrival/seek admissions, interleaving delayed decoder results, physical reaping,
new speech and Stop. It models cancelled callbacks as still able to arrive.

| Config | Distinct states | Result |
| --- | ---: | --- |
| Fixed (FairSpec) | 593 | PASS, four invariants + AcceptedSeekVisible |
| OverlapMutant | 42 | Expected FAIL: SinglePlayer |
| StaleMutant | 27 | Expected FAIL: FreshSeek |
| StopMutant | 41 | Expected FAIL: StopWins |
| OldReplayIdentityMutant | 47 | Expected FAIL: ReplayIdentityFresh |
| OldReplayInvisibleMutant | 570 | Expected FAIL: AcceptedSeekVisible (temporal) |

2.4 teleprompter freeze (V3-6/V3-7): the model now carries each utterance's submission (request) id, the
client's retired set and the player the client shows (`shown`). `Finish` retires the ended read's submission, as
VoiceState does on completion. `Replay` is `replayReadback` (readback scope, idle only): a new utterance and player.
Under `CopyIdentity` (the 85ea16f4 daemon, which spreads the ended read's `speechIdentity`) it carries the retired
request id. `Start` is the speaking frame, and VoiceState drops it as `retired-request`. `ReplayIdentityFresh` forbids
the reuse. `AcceptedSeekVisible` (under `FairSpec`: weak fairness on Decode, Start, Reap) says every accepted start
(an arrival, a seek or a replay) that nothing supersedes eventually becomes the client's player.

This lives here, not in playback-session. This model already has per-utterance identity and the daemon's identity
gate (`FreshSeek`), and the client's retired-request gate mirrors it. PlaybackSession has no request identity, and
adding it there would multiply an 837,722-state space.

Mapping: `Start` represents PlaybackQueueManager's reap gate; `Decode` represents
the preparation/controller and owning-job checks; `Stop` represents cancellation
and clearing pending restarts. Deterministic Bun barriers exercise the real TTS
queue with silent synth/player stubs. This is bounded model and source/runtime
logic proof, not installed VoiceBar, audible timing or UI acceptance. The lead
must arrange Claude review, including model design conformance, before merging.
