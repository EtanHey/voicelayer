# Playback seek protocol

VoiceBar sends `{"cmd":"seek","offset_ms":2500}` through its existing command-owner socket.
The socket server targets the active playback owner, including passive legacy MCP clients.
After playback idle it falls back to the command daemon for a no-op acknowledgement.
The optional scope is `"current"`; offsets are finite, nonnegative milliseconds from the start
of the current utterance, including chunk zero of a long read. A request ID is echoed in its ack.
There is no pause state: a playing utterance continues playing from the accepted position.

The ack reports `accept`, `noop` (nothing playing or duration unavailable), or `reject`.
Accepted requests include the effective `offset_ms` and `clamped` flag. Normal speech clamps
to its duration. Long reads clamp to the end of the synthesized contiguous chunks; they do not
wait for unsynthesized audio before acknowledging. At that end, playback waits for the next
chunk rather than starting an empty slice. At the utterance end, playback completes.

The daemon reaps the current player before starting a replacement. ffmpeg resolves through
`resolveBinaryAsync`, trims with `-ss` before `-i`, and writes an afplay-compatible PCM WAV.
Repeated seeks always slice the original audio, never an earlier slice. Stop/preemption cancels
owned preparation; late decoder/conversion results cannot restart a stopped utterance.
Long reads retain synthesized audio until history and cleanup finish. Backward seeks reuse
those chunks and resume in order, while the single synthesis lookahead remains bounded.

Actual `speaking` events include `duration_ms` (the synthesized seek range for long reads).
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
