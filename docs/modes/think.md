# Think Mode

Silent note-taking to a markdown log file. No audio, no mic — the agent captures insights, questions, and red flags that the user can view in a split-screen editor.

## When to Use

- During discovery calls: silently track unknowns and red flags
- During QA sessions: note patterns without interrupting the flow
- During code review: capture observations for later discussion

## MCP Tool

**Tool:** `voice_speak` with `mode: "think"` (or auto-selected for "insight:", "note:", "TODO:")
**Alias:** `qa_voice_think` (uses `thought` param; voice_speak uses `message`)

### Parameters

| Parameter | Type | Required | Default | Description |
|-----------|------|----------|---------|-------------|
| `message` / `thought` | string | Yes | — | The insight, suggestion, or note to append |
| `category` | string | No | `insight` | One of: `insight`, `question`, `red-flag`, `checklist-update` |

### Returns

```json
{
  "content": [{ "type": "text", "text": "Noted (insight): The auth flow has a race condition" }]
}
```

### Errors

| Error | Cause | Fix |
|-------|-------|-----|
| Missing thought | Empty or missing `thought` param | Provide non-empty text |
| File write failure | Permissions on think file path | Check path in `QA_VOICE_THINK_FILE` |

## Behavior

1. Formats the thought with timestamp, category icon, and text
2. Appends to the think log file
3. Returns confirmation text

The file is created on first write with a `# Live Thinking Log` header.

## Categories

| Category | Icon | When to Use |
|----------|------|-------------|
| `insight` | :bulb: | Observations, patterns, connections |
| `question` | :question: | Things to ask about or investigate |
| `red-flag` | :triangular_flag_on_post: | Concerns, risks, warnings |
| `checklist-update` | :white_check_mark: | Progress on a checklist or task |

## Output Format

The think log is a simple markdown file:

```markdown
# Live Thinking Log

- [10:32] (bulb icon) The auth module uses JWT but doesn't validate expiry
- [10:33] (question icon) Why is there a second database connection pool?
- [10:35] (flag icon) No rate limiting on the login endpoint
- [10:37] (checkmark icon) Navigation: mobile responsive - PASS
```

## Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `QA_VOICE_THINK_FILE` | `/tmp/voicelayer-thinking.md` | Path to the thinking log |

To persist the log across reboots, set `QA_VOICE_THINK_FILE` to a non-`/tmp` path:

```json
{
  "mcpServers": {
    "voicelayer": {
      "command": "bunx",
      "args": ["voicelayer-mcp"],
      "env": {
        "QA_VOICE_THINK_FILE": "/Users/me/notes/voicelayer-thinking.md"
      }
    }
  }
}
```

## Viewing the Log

Open the think file in a split-screen editor while your Claude Code session runs:

```bash
# Watch for updates in real-time
tail -f /tmp/voicelayer-thinking.md

# Or open in your editor's split pane
code /tmp/voicelayer-thinking.md
```
