<!-- IDENTITY: voicelayer — owned by EtanHey — voice I/O layer (TTS+STT) for AI coding assistants via MCP server and macOS VoiceBar -->
# VoiceLayer

@CLAUDE.details.md

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
## MCP Daemon (preferred)
- Singleton daemon on `/tmp/voicelayer-mcp.sock` — replaces per-session `voicelayer-mcp` spawning.
- LaunchAgent: `com.voicelayer.mcp-daemon` (auto-start on login, auto-restart on crash).
- `.mcp.json` config: `{ "command": "socat", "args": ["STDIO", "UNIX-CONNECT:/tmp/voicelayer-mcp.sock"] }`
- Migration: `bash scripts/migrate-to-daemon.sh` (migrates all repos under ~/Gits).
