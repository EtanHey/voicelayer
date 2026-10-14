# Streaming text reads

The command-owning TypeScript daemon accepts this VoiceBar-to-daemon NDJSON command:

```json
{"cmd":"speak_text","text":"Text to read aloud.","profile":"auto","format":"plain","source":"selection","id":"request-1"}
```

`text` must contain non-whitespace content and be at most 200,000 JavaScript string characters.
`profile` is optional (`auto`, `short`, `long`); `format` is optional (`plain`, `markdown`).
`source` is optional metadata, at most 256 characters. An `ack` carries the request ID and
`accept` or `reject`; asynchronous synthesis failures arrive as recoverable `error` events.
Malformed commands fail `parseCommand`, as with the other socket commands.

This is the existing VoiceBar command channel, not a new listening socket or an MCP tool.
The `voice_speak` and `voice_ask` input limits are unchanged. Recording/transcription and a
reserved voice operation refuse the command with `reason: "busy"`.

## Pipeline and cancellation

`src/tts.ts` exports `speakLongRead(text, {engine, voice, rate})`, returning `{id, done}`.
`engine` is `edge` or `clone`. The clone path uses Qwen3 directly, bypassing the short-read
XTTS/F5 truncation paths. The pipeline offers chunk zero to playback as soon as it is ready.
Synthesis refills on chunk completion, even while playback is preparing: one chunk ahead for
edge and up to two for clone, with only one synthesis request in flight. Bounded lookahead
reduces preparation gaps; sustained synthesis slower than playback still causes gaps.
Chunks prefer sentence boundaries; overlong sentences fall back to words, then hard cuts. Pronunciation changes apply to engine
input while the chunk's original display text labels the teleprompter.

`stopPlayback()` aborts the read's shared AbortController and clears/kills the playback queue.
Socket stop/cancel (including VoiceBar's playback Stop/Escape commands) use that same function.
A new long read, ordinary `speak`, or `voice_ask` preempts the read. A late synthesis result is
owned by the cancelled generation and can only be cleaned up, never played. Owned edge/ffmpeg
children receive SIGTERM and, if still alive after 250 ms, SIGKILL. An HTTP abort cancels the
Qwen3 client request; the current Python daemon's synchronous MLX computation may finish on
the server. Cancelling a client never kills the shared Qwen3 daemon.

Each actual chunk playback emits `state: speaking` and edge's chunk-local subtitle offsets.
The additive state field is:

```json
{"long_read":{"id":"long-read-id","chunk_index":0,"chunk_count":4,"chunk_start_ms":0}}
```

`chunk_start_ms` sums prior audio durations; it is an audio position, not wall-clock synthesis
or inter-chunk waiting time. Existing Swift clients ignore the new field. Playback idle is
suppressed between chunks. Before first playback, a speaking state with text `Preparing speech…`
and `long_read.preparing: true` activates the existing Swift Stop/Escape routing. This is preparation,
not an audio-start claim; actual chunk playback replaces that text and resets the clock/timings. Chunk-only
Replay is refused as busy during a read because restarting one chunk would invalidate its
global timeline/history. After completion, normal history replay remains available.

The ring receives one concatenated MP3 per read once it completes or is stopped. Only chunks
that actually started playback contribute audio; the interrupted final chunk is trimmed to its
reported playback position. Synthesized lookahead that never played is excluded. History
assembly, synthesis reaping and cleanup finish before a successful stop/cancel acknowledgement
or voice_ask prompt proceeds. Pending cancelled teardown remains busy, including repeat
stop/cancel requests. The complete playback wait has a 35-second outer deadline: a warning
is logged and the wait rejects if playback/cleanup still has not settled. Stop/cancel return
a rejection acknowledgement with the timeout reason; voice_ask returns an error without
starting its prompt or capture. Pending ownership remains retained for eventual cleanup. Audio stop and playback idle remain
immediate. Replacement long reads and ordinary speech also wait for cancelled-generation cleanup before synthesis starts,
so post-stop history ffmpeg never races a replacement. History text labels include only chunks
that actually played; the final partially played chunk retains its chunk label. The existing
twenty-slot ring remains bounded. A history conversion failure is logged even for a cancelled
read. `done` settles after history/cleanup; synthesis failures are published as events rather than rethrown from this background handle.

## Profile wiring

`src/tts.ts: resolveLongReadProfile(kind, text)` is the sole transitional settings seam.
It currently resolves the existing default voice/rate; all three kinds use that default until
PR A is integrated. Replace its body with `resolveSpeakProfile(kind, text)` after rebasing onto
PR A. The socket calls `speakText(text, command.profile ?? "auto")`, which passes the result to
`speakLongRead`. No profile file or short-limit policy is duplicated here.

`src/tts/markdown-to-speech.ts` exports the pure `markdownToSpeech` function for socket/selection
callers. It strips emphasis at word boundaries (preserving snake_case and dunder identifiers),
heading/inline-code markers, keeps link labels, replaces bare URLs with `link`, and reads
list/table rows as sentences. Complete fenced code becomes `code block`. For incomplete
selections, a bare fence after a code-only prefix or before obvious prose is treated as a
closing boundary; other unmatched fences suppress only recognizable code syntax and preserve
unknown/prose lines. Recovery requires whole statements/calls or strong bracket/punctuation
evidence; a keyword prefix alone never marks a line as code. Sentences ending in `.`, `?`,
or `!` (with letters and spaces), and four plain words without code punctuation, are always
spoken. Ambiguous content is spoken rather than silently dropped.

## Verification boundary

The Bun suites use the repository preload and owned synthesis/player fixtures. Replay assembly
has a real ffmpeg/ffprobe check without speaker output, and cancellation has a real owned-child
reaping check. These prove local code behavior, not installed VoiceBar audio, native Escape,
audible continuity, real edge network latency, or real Qwen3 model output. Installed Mac
acceptance remains a separate release step; do not replace a resident build while recording.
