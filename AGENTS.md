# VoiceLayer — Codex Agent Instructions

## What This Is

VoiceLayer is the voice I/O layer for the golem ecosystem. TTS + STT + routing.

## Review Guidelines

- VoiceBar is a Swift macOS menu bar app at `/Applications/VoiceBar.app`
- MCP server is the TypeScript layer: `src/mcp-server.ts`
- voice_speak is async (returns immediately), voice_ask is blocking
- One voice operation at a time — never parallelize speak/ask calls
- Build: `bash flow-bar/build-app.sh`

## Key Paths

- `src/` — TypeScript MCP server
- `flow-bar/` — Swift VoiceBar app
- `tests/` — 29 tests

## MCP Tools

| Tool | Type | Notes |
|------|------|-------|
| `voice_speak` | Async | Returns immediately, audio plays in background |
| `voice_ask` | Blocking | Waits for speak to finish, records mic, returns transcription |

## Test & Build

```bash
bun test           # 236 tests
bash flow-bar/build-app.sh  # Build VoiceBar
```

## PR Workflow

- `@codex review` + `@cursor @bugbot review` on every PR
- VoiceLayer is enabled for Codex Cloud reviews

## BrainLayer

Use `brain_search` before reading files. VoiceLayer history is indexed.
