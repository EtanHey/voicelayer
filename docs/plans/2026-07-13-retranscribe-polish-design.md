# Re-transcribe Polish Persistence Design

## Problem

`retranscribeLastCapture()` finalizes STT output with a module-level polish surface. That value starts as `null` after the daemon restarts, so a retained WAV can bypass the LLM polish stage. Archived-recording retranscription already uses the non-null `dictation` surface.

## Approaches considered

1. Persist a JSON sidecar beside the retained WAV and read it for every retranscription. This preserves the original surface across process restarts and makes the WAV-path test override isolate both files.
2. Store the surface in a global VoiceLayer state file. This survives restarts but can drift from an overridden or replaced retained WAV.
3. Only default the in-memory value to `dictation`. This prevents the null bypass but loses the original surface and does not explicitly bind metadata to the retained capture.

## Approved design

Use a small versioned JSON sidecar derived from `retainedRecordingFilePath()`. Whenever VoiceLayer retains a capture, atomically persist a valid non-null surface; if the capture has no surface, remove stale sidecar metadata. `retranscribeLastCapture()` resolves its surface from the sidecar and falls back to `dictation` when the file is absent, malformed, or contains an unsupported value. It never passes `null` to the finalizer.

Keep `retranscribeRecordingCapture()` on `dictation`, because archived recordings are VoiceBar dictations and that path is already non-null. Do not change finalization semantics for live recordings, non-meaningful output suppression, or retry/error handling.

## Testing

- A retained WAV with no sidecar must call polish with `dictation`.
- A retained capture persisted with `voice_ask` must later call polish with `voice_ask`, proving the sidecar is the source of truth rather than daemon memory.
- Archived retranscription must continue calling polish with `dictation`.
- Existing retranscription durability tests, the full Bun suite, and TypeScript typecheck must remain green.
