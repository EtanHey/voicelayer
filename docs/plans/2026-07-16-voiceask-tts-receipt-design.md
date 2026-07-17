# Voice Ask TTS Receipt Design

## Context

Voice ask schema-v2 archives identify the STT backend but do not identify the engine and voice that actually synthesized `agent-audio.mp3`. VoiceLayer L1 §4 and §7 require selected engine/backend disclosure in every receipt. The lane owner designated this as the sole pre-merge must-fix for PR #345.

## Decision

Return two scalar fields from the successful `speak()` branch:

- `engine`: the synthesis engine that produced the audio (`xtts-v2`, `f5-tts-mlx`, `qwen3-tts`, or `edge-tts`)
- `voice`: the resolved clone profile or concrete edge-tts neural voice actually passed to the successful engine

Do not infer these fields from requested configuration, replay history, or filenames. Each successful synthesis branch already knows the actual engine and resolved voice, including cloned-voice shortcut and fallback paths.

`handleConverse` requires audio bytes, sanitized display text, engine, and voice before starting the microphone. It passes them through `voiceAskArtifacts`; the schema-v2 archive adds `agent_tts_engine` and `agent_tts_voice` without changing `schema_version`.

## Alternatives rejected

1. A nested receipt object would add indirection without improving the two-field schema-v2 mapping.
2. Parsing replay-history labels such as `xtts:<voice>` would couple durable receipts to mutable compatibility history and recreate a race-prone dependency.
3. Recording the requested voice would be incorrect on preset resolution, announce shortcuts, unknown-voice fallback, and cloned-engine fallback.

## Error behavior

If a successful TTS path cannot disclose its engine or voice, `voice_ask` fails before recording starts. The lane owner explicitly signed off the existing fail-closed behavior when TTS is disabled. Archive validation also rejects missing engine/voice metadata.

## Deferred scope

This change does not preserve computed transcripts in archive errors, archive no-speech rounds, add vocabulary stamps, add rotation, sweep crash-orphan staging directories, or deduplicate checksum aliases. Those items are deferred in the layer gap ledger.

## Verification

Tests must prove:

- edge-tts returns the concrete actual voice and `edge-tts` engine;
- handler transport uses returned actual-used fields rather than the requested voice;
- schema-v2 metadata persists both fields; and
- missing receipt metadata is rejected before mic capture or archive publication.
