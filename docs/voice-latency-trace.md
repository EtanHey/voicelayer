# Voice turn latency trace

Set `VOICELAYER_TRACE_FILE` to an NDJSON file in an existing directory to enable
diagnostic tracing. It is off by default. Appends are synchronous, best effort,
and add measurement overhead; an unavailable destination never fails the turn.
New files use mode 0600. Events contain request identity, stage, process clock
identity, monotonic nanoseconds as a decimal string, and optional routing/status
fields. No prompt, transcript, voice name, paths, or audio content is recorded.

Analyze an existing file with:

```sh
bun scripts/measure-voice-turn-latency.ts path/to/trace.ndjson
```

This command only reads the supplied trace. It opens no microphone or sockets.
Spans are grouped by request and process clock; unrelated process clocks are
never subtracted. `player_spawn` is a proxy: output onset is always UNMEASURED.
The existing `first_audio_ms` metric means **prep → player-spawn**.

`first_pcm` observes the first nonempty native stdout chunk before normalization
or VAD. Recorder exit is observed only on fulfillment of the owned child's
`exited` promise; rejection, EOF, stop, and termination timeout provide no proof.
`end_decision` observes committed timeout/silence/stop callers; manual stop marks
the decision before tail draining. Barrier, drain, and retention internals are
unchanged. Failure/abort paths can omit stages. `handler_returned` marks settlement
of the Ask handler's conversation call in its `finally`, before reservation
release; early validation refusals can omit it. No transport emission hook is
installed: `tool_result_emitted` is absent and result-emission spans stay UNMEASURED,
even if a real `last_speech` timestamp is supplied.

There is no real `last_speech` timestamp yet, so last-speech latency is UNMEASURED.
The analyzer accepts a future `last_speech` event on the same clock and otherwise
never substitutes first VAD speech or the stop decision. Native acoustic onset
and installed-app acceptance require a separate coordinated session.
