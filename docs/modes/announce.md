# Announce Mode

Fire-and-forget text-to-speech. The agent speaks a short message aloud — no response expected.

## When to Use

- Task completion alerts: *"Deploy finished successfully"*
- Status updates: *"Running tests now, 12 of 47 complete"*
- Narration during long operations: *"Moving on to the database migration"*

## MCP Tool

**Name:** `qa_voice_announce`
**Alias:** `qa_voice_say`

### Parameters

| Parameter | Type | Required | Default | Description |
|-----------|------|----------|---------|-------------|
| `message` | string | Yes | — | Text to speak aloud (non-empty after trimming) |
| `rate` | string | No | `+10%` | Speech rate override (e.g., `-5%`, `+15%`) |

### Returns

```json
{
  "content": [{ "type": "text", "text": "[announce] Spoke: \"your message\"" }]
}
```

### Errors

| Error | Cause | Fix |
|-------|-------|-----|
| Missing message | Empty or missing `message` param | Provide non-empty message |
| edge-tts failed | edge-tts not installed | `pip3 install edge-tts` |
| Audio playback failed | No audio player found | macOS: built-in. Linux: install `mpv` |

## Behavior

1. Text is synthesized via edge-tts to a temporary MP3
2. MP3 plays through system speakers
3. Temp file is cleaned up
4. Returns immediately after playback completes

No mic recording, no session booking, no blocking.

## Speech Rate

Default: **+10%** (snappy delivery for short updates).

Auto-adjusted for long text:

- 300-599 chars: +5%
- 600-999 chars: +0%
- 1000+ chars: -5%

Override with the `rate` parameter:

```
qa_voice_announce({ message: "Important update", rate: "-10%" })
```

## Stop Signal

User can end playback early:

```bash
touch /tmp/voicelayer-stop
```

The stop file is cleaned up automatically after detection.
