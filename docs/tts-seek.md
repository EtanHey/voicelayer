# Playback seek protocol

VoiceBar sends `{"cmd":"seek","offset_ms":2500}` through its existing command-owner socket.
The socket server targets the active playback owner, including passive legacy MCP clients.
After playback idle it falls back to the command daemon.
The optional scope defaults to `"current"`; offsets are finite, nonnegative milliseconds from the start
of the current utterance, including chunk zero of a long read. A request ID is echoed in its ack.
Retained readback word clicks use `"scope":"readback"` and echo the speaking event's
`readback_id`; they are accepted only while idle with that exact retained identity.
These requests route to the last playback client, falling back to the daemon if it disconnected;
the identity check refuses stale audio after a reconnect or daemon restart.
They replay the same displayed utterance from the measured word offset. The daemon keeps
one utterance's original chunks independently of ring-slot rotation and played-range history;
replay reuses the serial long-read runner and never synthesizes. A stopped long read can replay
its contiguous retained prefix, ending at the end of that available audio; offsets beyond the
prefix fail with `Replay position unavailable`. Gaps or missing audio return
`reject` with `Replay prefix audio unavailable`. Missing word timing displays
`Word timing unavailable`; estimated timings never become seek targets. Current-scope seeks
after Stop remain no-ops. Readback replay is cancelled and reaped through the same Stop and
capture fences as ordinary speech. Retained audio is replaced when the next utterance starts.
There is no pause state: a playing utterance continues playing from the accepted position.

The teleprompter scrubber stays mounted on an ended readback, showing the retained duration and
stop position, and its drag/click sends the same readback-scope seek as a word click. Every speaking
edge carries `duration_ms` (an idle history Replay reports the probed file length). A long read
broadcasts `{"type":"playback_duration","long_read_id":…,"duration_ms":…,"final":…}` as each chunk
synthesizes; once every chunk exists, `final` is true and the chunk's `long_read` carries
`estimated_total_ms`, which drops the scrubber's "so far" label.

The ack reports `accept`, `noop` (nothing playing, not ready, or duration unavailable), or
`reject` (`busy` while recording/transcribing). Before the first synthesized chunk exists,
`noop` with `reason: "not ready"` tells the scrub client to disable seeking until audio is ready.
Accepted requests include the effective `offset_ms` and `clamped` flag. Normal speech clamps
to its duration. Long reads clamp to the end of the synthesized contiguous chunks; they do not
wait for unsynthesized audio before acknowledging. At that end, playback waits for the next
chunk rather than starting an empty slice. At the utterance end, playback completes.

The daemon prepares the replacement slice while current playback continues. Only after the
slice succeeds does it reap the current player and start the replacement, bypassing amplitude
decoding (the seek waveform is unavailable). A conversion/resolution failure emits a recoverable
error with `source: "seek"` and preserves current playback and the Swift speaking clock.
ffmpeg resolves through `resolveBinaryAsync`, whose
ffmpeg candidate probes use `-version`; other binaries still use `--version`. Trimming uses
`-ss` before `-i` and produces an afplay-compatible PCM WAV. Seeking to zero, including Replay
after seek, uses the original audio without ffmpeg or amplitude decoding.
Repeated seeks always slice the original audio, never an earlier slice. Stop/preemption cancels
owned preparation; late decoder/conversion results cannot restart a stopped utterance.
Long reads retain synthesized audio until history and cleanup finish. Backward seeks reuse
those chunks and resume in order, while the single synthesis lookahead remains bounded.

Actual `speaking` events include `duration_ms` (the synthesized seek range for long reads).
For short speech, duration is the maximum of probed audio duration and the last word boundary,
so untimed speech is still seekable and timed speech includes its trailing audio.
Long-read handoffs and all seeks include `playback_offset_ms`, the global playback position.
`long_read` metadata and chunk-relative subtitle offsets retain their existing wire format.
Swift rebases those boundaries by `chunk_start_ms`, adjusts its playback clock to the global
position, and keeps same-text boundaries during seek. The amplitude clock starts at zero for
the new slice. `VoiceState.seek(offsetMs:)` provides the command seam for the scrub UI.
No estimated duration is emitted. History concatenates only the ranges actually heard,
including repeated segments after backward seek; all temporary slices are removed.

This change adds no gestures. Installed/native audio acceptance belongs to the lead's later
daemon verification and release gates. Local tests use preload-isolated paths and fake players;
the history test uses real ffmpeg without sending audio to a speaker.
