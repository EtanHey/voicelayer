# Ask/Speak Substance Residuals Design

## Scope

Resolve the four substance residuals from the July 18 live VoiceLayer session plus the July 19 very-long terminal-paste incident in one bounded PR: ask punctuation, MCP keepalives, no-speech completion/archive, playback interruption telemetry, and wedge-safe cmux insertion. This change does not touch renderer, geometry, or VoiceBar UI code.

## Root causes

1. `waitForInput()` calls `polishSurfaceForWaitOptions()`, which returns `"dictation"` for VoiceBar/F5 and `null` for `voice_ask`. Ask therefore gets deterministic cleanup but skips the optional surface-aware polish pass used by F5.
2. Both MCP entry points execute tool handlers without a request-scoped notification channel. A blocking ask can produce socket/UI state while remaining silent on the MCP connection.
3. VAD pre-speech timeout resolves `recordToBuffer()` with `null` even though PCM was captured. `waitForInput()` returns before the voice-ask capture archive and `onCaptureEnd` boundary, and the caller receives the generic configured-timeout message rather than a prompt no-speech outcome.
4. The playback queue already computes elapsed progress for its socket queue snapshots, but `PlaybackHandle.exited` is `Promise<void>`. Stop, barge-in, skipped playback, and natural completion are indistinguishable to the TTS handler and MCP caller.
5. `CommandModeAXHelper` routes any payload above 2048 UTF-16 units to repeated `kAXSelectedText` writes, including cmux/Ghostty. Etan observed that stream wedge a pane twice with very-long dictated transcripts. The corpus runtime leg covered only a normal transcript, so it could not catch the size branch.

## Approaches considered

### A. Request-scoped callbacks and typed queue outcomes — selected

Thread one small tool-event context from each MCP transport into the existing handlers. Use standard `notifications/progress` when the client supplied a progress token and standard `notifications/message` otherwise. Preserve silent PCM only for voice-ask capture archives. Promote playback completion to a typed outcome containing ID, status, elapsed position, percent, and word position.

This is the smallest coherent change: it reuses the current cleanup, archive, queue-progress, and socket structures without introducing a second pipeline.

### B. Global VoiceLayer event bus

Publish all capture and playback state globally, then let MCP transports subscribe. This could support future observers, but it introduces lifecycle, filtering, and multi-client ownership concerns that the four residuals do not require.

### C. Polling tools or blocking `voice_speak`

Return a playback ID and require a second polling tool, or make `voice_speak` block until playback finishes. Polling adds API surface and delays telemetry; blocking violates VoiceLayer's established non-blocking speak contract.

## Design

### Ask punctuation

Map `archiveSource: "voice_ask"` to the existing `"voice_ask"` STT polish surface. Both F5 and ask continue through the same deterministic cleanup and punctuation floor; the optional polish layer receives the correct surface label and keeps its existing fallback behavior.

### MCP progress

Add a transport-neutral tool event context. A voice ask starts a heartbeat when recording begins, changes its phase to transcribing at the existing input boundary, and stops the heartbeat in `finally`. Heartbeats are monotonic and include phase plus elapsed time. The stdio SDK transport uses its request handler's notification sender. The persistent socket daemon writes notifications on the same client connection and preserves Content-Length versus NDJSON framing.

If `_meta.progressToken` exists, emit `notifications/progress`. Otherwise emit `notifications/message` as a protocol-valid keepalive. Notification delivery is best effort and cannot fail the voice operation.

### No-speech completion and archive

Allow `recordToBuffer()` to retain captured no-speech PCM only when `waitForInput()` is serving `voice_ask`. That PCM then crosses the existing capture-end archive boundary, producing the paired folder with `transcription_status: "captured"`. The no-speech gate invokes a dedicated outcome callback and returns `null` immediately. `handleConverse()` formats that outcome as a no-speech status instead of claiming the full configured timeout elapsed.

Zero-byte/mic-disabled input cannot produce a truthful audio archive and retains existing behavior.

### Interruption telemetry

Give every queued playback a stable ID. Replace `Promise<void>` playback exits with typed outcomes: completed, interrupted, skipped, or failed. Active stop/barge-in captures elapsed milliseconds, normalized progress, and a zero-based word index (exact boundary when available, duration-based estimate otherwise). The queue broadcasts the outcome as a non-visual socket event and invokes the initiating handler callback.

For non-blocking `voice_speak`, the immediate result includes the playback ID and a later MCP logging notification carries the outcome. For the blocking ask prompt leg, the same notification is emitted and an interrupted prompt summary is also appended to the eventual tool result.

### Very-long terminal insertion

Treat `com.cmuxterm.app` as an atomic value-rewrite target before applying either size threshold. This preserves the reliable one-write path for normal and very-long cmux/Ghostty transcripts while leaving size-based selected-text streaming available to nonterminal targets. Shift+F5 and manual paste do not use this strategy branch and remain unchanged.

Extend the isolated corpus runtime interaction with a second synthetic transcript above 10,000 UTF-16 units. The leg reuses the production `VoiceState` auto-paste flow and the cmux model that accepts selected-text writes without rendering them, so it fails if the terminal path ever returns to streaming.

## Error handling

- MCP notification send failures are logged and do not change the tool result.
- Capture archive failures remain fail-closed for `voice_ask`.
- No-speech archives remain unfinalized (`captured`) because no transcript exists.
- Playback outcome callbacks are isolated so observer failures cannot wedge the queue.

## Verification

Each residual gets a RED-first regression test. Targeted suites cover surface routing, simulated long heartbeat activity, no-speech archive/status behavior, daemon framing, stopped-at playback position, and a 10k+ terminal insertion. Final verification runs `bun test` serially and `scripts/voicelayer-verify.sh --corpus 10` on the exact head, including normal and very-long terminal paste gates.
