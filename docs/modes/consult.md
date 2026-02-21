# Consult Mode

Speak a checkpoint message — the user **may** want to respond, but no mic recording happens. Use for preemptive checkpoints before important actions.

## When to Use

- Before destructive actions: *"About to drop the staging database. Okay?"*
- Before commits/pushes: *"I'm ready to push to main. Want to review first?"*
- Decision points: *"Should I use Redis or the built-in cache?"*

## MCP Tool

**Name:** `qa_voice_consult`

### Parameters

| Parameter | Type | Required | Default | Description |
|-----------|------|----------|---------|-------------|
| `message` | string | Yes | — | The checkpoint question or status (non-empty after trimming) |
| `rate` | string | No | `+5%` | Speech rate override |

### Returns

```json
{
  "content": [{
    "type": "text",
    "text": "[consult] Spoke: \"your message\"\nUser may want to respond. Use qa_voice_converse to collect voice input if needed."
  }]
}
```

### Errors

Same as [Announce](announce.md#errors) — edge-tts or audio player issues.

## Behavior

1. Text is spoken aloud via edge-tts (same as announce/brief)
2. Returns immediately — **no mic recording**
3. The return text hints that the agent should follow up with `converse` if input is needed

Consult is a "heads up" — it doesn't block. If the user says nothing (types nothing), the agent can proceed. If the user wants to respond verbally, the agent should call `qa_voice_converse` as a follow-up.

## Speech Rate

Default: **+5%** (slightly faster than natural — checkpoints should be brisk).

## When to Follow Up with Converse

The consult tool's response includes a hint:

> *"User may want to respond. Use qa_voice_converse to collect voice input if needed."*

The agent should decide based on context whether to:

1. **Wait for text input** — if the user typically types
2. **Call converse** — if in a voice session and input is expected
3. **Proceed** — if the checkpoint was informational only
