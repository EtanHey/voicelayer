# MCP Tools Reference

Complete reference for all VoiceLayer MCP tools. VoiceLayer exposes 7 tools (5 modes + 2 backward-compat aliases).

## qa_voice_announce

Fire-and-forget text-to-speech. Speaks a message aloud without waiting for a response.

| Property | Value |
|----------|-------|
| **Blocking** | No |
| **Requires mic** | No |
| **Session booking** | No |

**Parameters:**

| Name | Type | Required | Default | Description |
|------|------|----------|---------|-------------|
| `message` | `string` | Yes | — | Text to speak (must be non-empty after trimming) |
| `rate` | `string` | No | `+10%` | Speech rate (e.g., `-10%`, `+5%`). Pattern: `^[+-]\d+%$` |

**Returns:** `[announce] Spoke: "message"`
**Errors:** Empty message, edge-tts not installed, audio player missing

---

## qa_voice_brief

One-way explanation via TTS. Slower default rate for longer content.

| Property | Value |
|----------|-------|
| **Blocking** | No |
| **Requires mic** | No |
| **Session booking** | No |

**Parameters:**

| Name | Type | Required | Default | Description |
|------|------|----------|---------|-------------|
| `message` | `string` | Yes | — | Explanation or summary to speak (must be non-empty) |
| `rate` | `string` | No | `-10%` | Speech rate override |

**Returns:** `[brief] Explained: "message"`
**Errors:** Same as announce

---

## qa_voice_consult

Speak a checkpoint. User may want to respond — follow up with converse if needed.

| Property | Value |
|----------|-------|
| **Blocking** | No |
| **Requires mic** | No |
| **Session booking** | No |

**Parameters:**

| Name | Type | Required | Default | Description |
|------|------|----------|---------|-------------|
| `message` | `string` | Yes | — | Checkpoint question or status (must be non-empty) |
| `rate` | `string` | No | `+5%` | Speech rate override |

**Returns:** `[consult] Spoke: "message"\nUser may want to respond. Use qa_voice_converse to collect voice input if needed.`
**Errors:** Same as announce

---

## qa_voice_converse

Full voice Q&A. Speaks a question, records mic, transcribes, returns text. **Blocking.**

| Property | Value |
|----------|-------|
| **Blocking** | **Yes** |
| **Requires mic** | **Yes** |
| **Session booking** | **Yes** (auto-books on first call) |

**Parameters:**

| Name | Type | Required | Default | Description |
|------|------|----------|---------|-------------|
| `message` | `string` | Yes | — | Question to speak aloud (must be non-empty) |
| `timeout_seconds` | `number` | No | `300` | Max wait time (clamped to 10-3600) |

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

## qa_voice_think

Silent note-taking to a markdown log. No audio.

| Property | Value |
|----------|-------|
| **Blocking** | No |
| **Requires mic** | No |
| **Session booking** | No |

**Parameters:**

| Name | Type | Required | Default | Description |
|------|------|----------|---------|-------------|
| `thought` | `string` | Yes | — | Insight, suggestion, or note to append |
| `category` | `string` | No | `insight` | One of: `insight`, `question`, `red-flag`, `checklist-update` |

**Returns:** `Noted (category): thought text`
**Errors:** Empty thought, file write failure

**Output file:** `QA_VOICE_THINK_FILE` (default: `/tmp/voicelayer-thinking.md`)

---

## qa_voice_say (alias)

Backward-compatible alias for `qa_voice_announce`. Same behavior, same parameters (minus `rate`).

| Name | Type | Required | Description |
|------|------|----------|-------------|
| `message` | `string` | Yes | Text to speak |

---

## qa_voice_ask (alias)

Backward-compatible alias for `qa_voice_converse`. Same behavior, same parameters.

| Name | Type | Required | Default | Description |
|------|------|----------|---------|-------------|
| `message` | `string` | Yes | — | Question to speak |
| `timeout_seconds` | `number` | No | `300` | Max wait time (10-3600) |

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
| announce, brief, consult | `python3` + `edge-tts`, audio player |
| converse | All of the above + `sox`, STT backend (whisper.cpp or Wispr) |
| think | None (file system only) |
