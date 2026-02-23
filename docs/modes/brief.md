# Brief Mode

One-way explanation via TTS. The agent reads back a longer piece of content — decisions, summaries, findings — while the user listens. No response expected.

## When to Use

- Reading back analysis results: *"Here's what I found in the codebase..."*
- Summarizing a plan: *"The migration will happen in three phases..."*
- Explaining a decision: *"I chose Redis over Memcached because..."*

## MCP Tool

**Tool:** `voice_speak` with `mode: "brief"` (or auto-selected for messages >280 chars)
**Alias:** `qa_voice_brief`

### Parameters

| Parameter | Type | Required | Default | Description |
|-----------|------|----------|---------|-------------|
| `message` | string | Yes | — | The explanation or summary to speak (non-empty after trimming) |
| `rate` | string | No | `-10%` | Speech rate override (e.g., `-20%`, `+0%`) |

### Returns

```json
{
  "content": [{ "type": "text", "text": "[brief] Explained: \"your message\"" }]
}
```

### Errors

Same as [Announce](announce.md#errors) — edge-tts or audio player issues.

## Behavior

Identical pipeline to announce (edge-tts -> audio player -> cleanup), but with a **slower default rate** optimized for longer content.

## Speech Rate

Default: **-10%** (slower for comprehension of longer content).

Auto-adjusted for text length:

- 300-599 chars: -15%
- 600-999 chars: -20%
- 1000+ chars: -25%

This makes brief mode noticeably slower than announce — intentional, since brief content is typically 2-5 sentences that the user needs to absorb.

## Stop Signal

Same as all TTS modes:

```bash
touch /tmp/voicelayer-stop
```
