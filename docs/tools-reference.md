# MCP Tools Reference

VoiceLayer exposes 2 primary tools. Backward-compat aliases are listed below.

## voice_speak

Non-blocking text-to-speech. Speaks a message aloud or logs it silently. Auto-detects mode from message content if `mode` is omitted.

| Property | Value |
|----------|-------|
| **Blocking** | No |
| **Requires mic** | No |
| **Session booking** | No |

**Parameters:**

| Name | Type | Required | Default | Description |
|------|------|----------|---------|-------------|
| `message` | `string` | Yes | — | Text to speak or log (must be non-empty after trimming) |
| `mode` | `string` | No | `auto` | `announce`, `brief`, `consult`, `think`, or `auto` (auto-detect from content) |
| `voice` | `string` | No | `jenny` | Profile name or raw edge-tts voice ID |
| `rate` | `string` | No | (per-mode) | Speech rate (e.g., `-10%`, `+5%`). Pattern: `^[+-]\d+%$` |
| `category` | `string` | No | `insight` | For think mode: `insight`, `question`, `red-flag`, `checklist-update` |
| `replay_index` | `number` | No | — | Replay cached message (0 = most recent). Ignores message. |
| `enabled` | `boolean` | No | — | Toggle voice on/off instead of speaking |
| `scope` | `string` | No | `all` | Toggle scope: `all`, `tts`, or `mic` (only with `enabled`) |

**Mode auto-detection:** `insight:`, `note:`, `TODO:` → think; `?` or "about to" → consult; >280 chars → brief; default → announce.

**Returns:** `[mode] Spoke: "message"` or `Noted (category): thought` for think mode.
**Errors:** Empty message, edge-tts not installed, audio player missing

---

## voice_ask

Blocking voice Q&A. Auto-waits for any playing `voice_speak` audio to finish, then speaks a question aloud, records mic at device's native rate (auto-detected), resamples to 16kHz, transcribes via Silero VAD + whisper.cpp/Wispr Flow, returns text.

| Property | Value |
|----------|-------|
| **Blocking** | **Yes** |
| **Requires mic** | **Yes** |
| **Session booking** | **Yes** (auto-books on first call) |
| **Auto-waits** | **Yes** (waits for prior `voice_speak` playback) |

**Parameters:**

| Name | Type | Required | Default | Description |
|------|------|----------|---------|-------------|
| `message` | `string` | Yes | — | Question to speak aloud (must be non-empty) |
| `timeout_seconds` | `number` | No | `300` | Max wait time (clamped to 10-3600) |
| `silence_mode` | `string` | No | `thoughtful` | `quick`, `standard`, or `thoughtful` |

**Returns (success):** The user's transcribed text (plain string)
**Returns (timeout):** `[converse] No response received within N seconds.`
**Returns (busy):** `[converse] Line is busy — voice session owned by... ` (with `isError: true`)

**Errors:**

| Error | Cause |
|-------|-------|
| Line busy | Another session has the mic |
| sox not installed | `rec` command missing |
| Mic permission denied | Terminal not authorized for mic |
| No STT backend | Neither whisper.cpp nor Wispr available |

---

## Backward-Compat Aliases

| Alias | Maps To |
|-------|---------|
| `qa_voice_announce` | `voice_speak(mode='announce')` |
| `qa_voice_brief` | `voice_speak(mode='brief')` |
| `qa_voice_consult` | `voice_speak(mode='consult')` |
| `qa_voice_think` | `voice_speak(mode='think')` (uses `thought` param) |
| `qa_voice_say` | `voice_speak(mode='announce')` |
| `qa_voice_replay` | `voice_speak(replay_index=N)` |
| `qa_voice_toggle` | `voice_speak(enabled=bool)` |
| `qa_voice_converse` | `voice_ask` |
| `qa_voice_ask` | `voice_ask` |

---

## Error Handling

All tools return errors in MCP format:

```json
{
  "content": [{ "type": "text", "text": "Error message here" }],
  "isError": true
}
```

Tools never throw exceptions — all errors are caught and returned as structured responses. Errors are also logged to stderr for debugging.

## Prerequisites Summary

| Tool | Depends On |
|------|-----------|
| voice_speak (TTS modes) | `python3` + `edge-tts`, audio player |
| voice_ask | All of the above + `sox`, STT backend (whisper.cpp or Wispr) |
| voice_speak (think mode) | None (file system only) |
