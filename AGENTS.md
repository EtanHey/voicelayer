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

<!-- IDENTITY: voicelayer — owned by EtanHey — voice I/O layer (TTS+STT) for AI coding assistants via MCP server and macOS VoiceBar -->
# VoiceLayer

> Voice I/O layer for AI coding assistants. MCP server plus macOS Voice Bar.

<!-- ARCHITECTURE: key stack components, IPC socket pattern, blocking vs non-blocking tools, session booking -->
## Purpose (WHY)
- Provide reliable TTS and STT for coding assistants with replay and toggle control.

<!-- STACK: TypeScript/Bun MCP server, SwiftUI VoiceBar, Python TTS daemon, whisper.cpp/Wispr STT -->
## Stack (WHAT)
- TypeScript/Bun MCP server and CLI in `src/`
- SwiftUI macOS Voice Bar app in `flow-bar/`
- Python TTS daemon (Qwen3-TTS) plus edge-tts
- whisper.cpp or Wispr Flow STT backends

<!-- COMMANDS: bun test (run tests) | bun run src/mcp-server.ts (stdio mode) | bash scripts/migrate-to-daemon.sh (migrate all repos) | bash flow-bar/build-app.sh (build VoiceBar) -->
## Workflow (HOW)
- Start at `src/mcp-server.ts` (stdio) or `src/mcp-server-daemon.ts` (singleton daemon).
- Core runtime in `src/tts.ts`, `src/input.ts`, `src/vad.ts`, `src/stt.ts`.
- IPC uses `/tmp/voicelayer.sock` (Voice Bar is the server, MCP connects as client); protocol types in `src/socket-protocol.ts`.
- `voice_speak` is non-blocking; `voice_ask` blocks and uses Silero VAD by default.
- Keep session booking and ring buffer behavior stable (see `src/session-booking.ts`, `src/paths.ts`).
- Tests live in `src/__tests__/`; run `bun test`.

<!-- MCP-SERVERS: add new MCP server entries to .mcp.json — current servers: playwright, voicelayer-daemon (socat to /tmp/voicelayer-mcp.sock) -->
## Playwright MCP (browser automation)

- `.mcp.json` config: `{ "mcpServers": { "playwright": { "command": "npx", "args": ["@playwright/mcp@latest"] } } }`
- Provides `browser_navigate`, `browser_snapshot`, `browser_click`, etc.
- Hebrew text renders as proper Unicode in the accessibility tree (verified against he.wikipedia.org).
- Verification tests in `tests/playwright-mcp-verify.test.ts`.

<!-- PATHS: src/mcp-server.ts (entry), src/tts.ts, src/input.ts, src/vad.ts, src/stt.ts, src/session-booking.ts, src/socket-protocol.ts, src/paths.ts, flow-bar/ (SwiftUI), src/__tests__/ (tests), scripts/migrate-to-daemon.sh -->
<!-- TESTING: bun test — tests in src/__tests__/ | Playwright MCP tests in tests/playwright-mcp-verify.test.ts -->
## MCP Daemon — VoiceBar.app is the SOLE owner
- **Never install a second owner.** `com.voicelayer.mcp-daemon` is RETIRED: `launchd/install.sh`
  boots it out and deletes its plist, printing *"Retired. VoiceBar.app now owns the MCP daemon child
  process."* A second owner is the double-owner bug that took five commits to fix.
- Singleton daemon on `/tmp/voicelayer-mcp.sock` — replaces per-session `voicelayer-mcp` spawning.
- `.mcp.json` config: `{ "command": "socat", "args": ["STDIO", "UNIX-CONNECT:/tmp/voicelayer-mcp.sock"] }`
- Migration: `bash scripts/migrate-to-daemon.sh` (migrates all repos under ~/Gits).
