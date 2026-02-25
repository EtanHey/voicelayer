# Converse Mode

Full bidirectional voice Q&A. The agent speaks a question, records the user's voice response via microphone, transcribes it with whisper.cpp (or Wispr Flow), and returns the text.

This is the **only blocking mode** — the tool call doesn't return until the user finishes speaking or the timeout expires.

## When to Use

- Interactive Q&A sessions: *"What did you think of the prototype?"*
- Drilling sessions: *"Walk me through how the auth flow works"*
- Discovery calls: *"What are the main pain points with the current system?"*
- QA testing: *"How does the checkout page look on your screen?"*

## MCP Tool

**Tool:** `voice_ask` (blocking voice Q&A)
**Alias:** `qa_voice_converse`, `qa_voice_ask`

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
| No STT backend | Neither whisper.cpp nor Wispr available | `brew install whisper-cpp` (binary: `whisper-cli`) or set `QA_VOICE_WISPR_KEY` |

## Behavior

### Full Flow

1. **Session booking** — auto-books if not already booked (lockfile check)
2. **Clear state** — removes leftover input/stop signals
3. **Wait for prior audio** — auto-waits for any playing `voice_speak` audio to finish (prevents overlap)
4. **Speak question** — edge-tts synthesizes and plays the question (blocking — waits for playback)
5. **Detect device rate** — probes default audio input for native sample rate (e.g., 24kHz for AirPods, 48kHz for built-in mic)
6. **Record mic** — sox records at device's native rate, audio resampled to 16kHz in real-time
7. **Silero VAD** — neural network detects speech vs. noise in each 32ms chunk
8. **Wait for stop** — user stop signal (primary), VAD silence detection (configurable), or timeout
9. **Transcribe** — whisper.cpp or Wispr Flow converts 16kHz audio to text
10. **Return** — transcribed text returned to the agent

### Stop Methods (in priority order)

1. **User stop signal** (PRIMARY): `touch /tmp/voicelayer-stop`
2. **Silero VAD silence detection** (FALLBACK): configurable silence duration after speech is detected
3. **Pre-speech timeout**: 15s of no speech → returns null early
4. **Timeout** (SAFETY NET): `timeout_seconds` parameter (default 300s)

!!! info "Why user-controlled stop is primary"
    Silence detection can misfire — background noise, thinking pauses, or mic sensitivity issues cause premature cutoff. The touch-file approach gives the user explicit control over when they're done speaking.

## Session Booking

Converse mode requires exclusive mic access. The first `voice_ask` call auto-books a session:

- **Lockfile:** `/tmp/voicelayer-session.lock`
- **Contains:** PID, session ID, start timestamp
- **Stale lock cleanup:** dead PIDs are auto-detected and removed
- **Race condition safe:** uses atomic exclusive file creation (`wx` flag)

Other Claude Code sessions that try to use `voice_ask` see "line busy" and should fall back to text input.

The lock is released when the MCP server process exits (SIGTERM/SIGINT/exit handlers).

## Recording Details

| Setting | Value |
|---------|-------|
| Recording rate | Device native (auto-detected, e.g., 24kHz, 48kHz) |
| Output rate | 16,000 Hz (resampled in code) |
| Channels | 1 (mono) |
| Bit depth | 16-bit signed |
| Format | Raw PCM → resample → WAV |
| VAD | Silero VAD v5 (neural network, 32ms chunks) |
| Default silence mode | Thoughtful (2.5s of silence after speech) |

Audio is recorded at the device's native sample rate via sox to avoid buffer overruns, resampled to 16kHz in real-time via linear interpolation, processed by Silero VAD for speech detection, then wrapped in a WAV header and passed to the STT backend.

!!! note "AirPods and Bluetooth devices"
    Bluetooth audio devices (e.g., AirPods) often only support specific sample rates (24kHz). VoiceLayer auto-detects the device rate and handles resampling transparently — no configuration needed.

## Speech Rate

Default: **+0%** (natural conversational pace).

No auto-slowdown applied — converse questions are typically short.
