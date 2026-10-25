# Speech History disk contract — SPEECH-WIRE
Status: implementation contract, schema_version 1 additive extension.

Match Recording/Ask History: scan `~/.local/share/voicelayer/recordings/YYYY-MM-DD/<id>/metadata.json`, select `source == "speak"`. Test root is QA_VOICE_RECORDINGS_DIR under the isolation preload. No socket required.

Existing fields remain: id, request_id, request_source (selection/clipboard/voice_speak/ask_prompt/cli/preview/direct), created_at, updated_at, requested.{voice,profile,engine,rate}, parent_ask_id, artifacts. `input.txt` contains the exact original requested/selected text, including whitespace. Never substitute generated text for it.

New optional `speech` object (absent on old entries):
```json
{"state":"playing","reason":null,"played_ms":1200,"playing_since":"2026-10-26T12:00:00.000Z","transitions":[{"from":"requested","to":"preparing","at":"2026-10-26T11:59:59.000Z","reason":null}],"generated":[{"index":0,"text":"Actual engine input","audio_path":"audio/<sha256>.mp3","voice":"en-US-AndrewNeural","profile":"long","engine":"edge-tts","generated_at":"2026-10-26T12:00:00.000Z"}]}
```
States: requested → preparing → playing ⇄ paused → completed/stopped/cancelled/failed. Preparing may pause before the first player exists. Any nonterminal can fail, cancel, stop, or recover as interrupted. Terminal states cannot transition again. `reason` is a stable code, not an exception/text dump. `played_ms` accumulates actual player-on wall time (pauses/preparation excluded), a software measurement, not acoustic proof. Add `now-playing_since` only for an active playing record. Timestamps are UTC ISO8601.

`generated` is sorted by index; each item describes successfully generated audio and the exact engine input for that chunk, including pronunciation transforms and fallback. Join text with a space for a generated-text view; do not infer unsynthesized chunks. Resolve audio_path relative to the entry directory; only safe relative archive paths. Existing `artifacts` retain the corresponding MP3 bytes indefinitely. Missing/partial audio is valid for cancellation/failure; show the entry anyway. Legacy `status` remains for compatibility; prefer `speech.state` when present. Legacy interrupted_unknown maps to interrupted for display.

Do not mutate archive files from History. Reload metadata on refresh. Input and each audio file are published before their metadata references; metadata uses atomic rename and fsync. Recovery runs after singleton ownership is acquired, before accepting requests, and preserves terminal records.
