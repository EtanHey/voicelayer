# Converse Mode

Full bidirectional voice Q&A. The agent speaks a question, records the user's voice response via microphone, transcribes it with whisper.cpp (or Wispr Flow), and returns the text.

This is the **only blocking mode** — the tool call doesn't return until the user finishes speaking or the timeout expires.

## When to Use

- Interactive Q&A sessions: *"What did you think of the prototype?"*
- Drilling sessions: *"Walk me through how the auth flow works"*
- Discovery calls: *"What are the main pain points with the current system?"*
- QA testing: *"How does the checkout page look on your screen?"*

## MCP Tool

**Name:** `qa_voice_converse`
**Alias:** `qa_voice_ask`

### Parameters

| Parameter | Type | Required | Default | Description |
|-----------|------|----------|---------|-------------|
| `message` | string | Yes | — | Question or prompt to speak aloud (non-empty) |
| `timeout_seconds` | number | No | `300` | Max wait time for response (clamped to 10-3600) |

### Returns

**On success** — the user's transcribed text:

```json
{
  "content": [{ "type": "text", "text": "The hamburger menu is cut off on mobile" }]
}
```

**On timeout / no speech:**

```json
{
  "content": [{ "type": "text", "text": "[converse] No response received within 300 seconds. The user may have stepped away." }]
}
```

**On busy (another session has the mic):**

```json
{
  "content": [{ "type": "text", "text": "[converse] Line is busy — voice session owned by mcp-12345 (PID 12345) since 2026-02-21T10:00:00Z. Fall back to text input, or wait for the other session to finish." }],
  "isError": true
}
```

### Errors

| Error | Cause | Fix |
|-------|-------|-----|
| Line busy | Another session has the mic | Wait or fall back to text |
| sox not installed | `rec` command not found | `brew install sox` |
| Mic permission denied | Terminal not authorized | macOS: System Settings > Privacy > Microphone |
| No STT backend | Neither whisper.cpp nor Wispr available | Install whisper-cpp or set `QA_VOICE_WISPR_KEY` |

## Behavior

### Full Flow

1. **Session booking** — auto-books if not already booked (lockfile check)
2. **Clear state** — removes leftover input/stop signals
3. **Speak question** — edge-tts synthesizes and plays the question
4. **Record mic** — sox starts recording 16kHz 16-bit mono PCM
5. **Wait for stop** — user touches `/tmp/voicelayer-stop` (primary) or silence detected (fallback)
6. **Transcribe** — whisper.cpp or Wispr Flow converts audio to text
7. **Return** — transcribed text returned to the agent

### Stop Methods (in priority order)

1. **User stop signal** (PRIMARY): `touch /tmp/voicelayer-stop`
2. **Silence detection** (FALLBACK): 5 seconds of silence after speech is detected
3. **Timeout** (SAFETY NET): `timeout_seconds` parameter (default 300s)

!!! info "Why user-controlled stop is primary"
    Silence detection can misfire — background noise, thinking pauses, or mic sensitivity issues cause premature cutoff. The touch-file approach gives the user explicit control over when they're done speaking.

## Session Booking

Converse mode requires exclusive mic access. The first `converse` call auto-books a session:

- **Lockfile:** `/tmp/voicelayer-session.lock`
- **Contains:** PID, session ID, start timestamp
- **Stale lock cleanup:** dead PIDs are auto-detected and removed
- **Race condition safe:** uses atomic exclusive file creation (`wx` flag)

Other Claude Code sessions that try to use `converse` see "line busy" and should fall back to text input.

The lock is released when the MCP server process exits (SIGTERM/SIGINT/exit handlers).

## Recording Details

| Setting | Value |
|---------|-------|
| Sample rate | 16,000 Hz |
| Channels | 1 (mono) |
| Bit depth | 16-bit signed |
| Format | Raw PCM -> WAV |
| Silence threshold | RMS 500 (configurable) |
| Silence duration | 5 seconds (converse-specific) |

Audio is recorded as raw PCM via sox, wrapped in a WAV header, then passed to the STT backend.

## Speech Rate

Default: **+0%** (natural conversational pace).

No auto-slowdown applied — converse questions are typically short.
