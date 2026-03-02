# VoiceLayer

@CLAUDE.details.md
@~/Gits/orchestrator/standards/autonomous-workflow.md

> Voice I/O layer for AI coding assistants. MCP server plus macOS Voice Bar.

## Purpose (WHY)
- Provide reliable TTS and STT for coding assistants with replay and toggle control.

## Stack (WHAT)
- TypeScript/Bun MCP server and CLI in `src/`
- SwiftUI macOS Voice Bar app in `flow-bar/`
- Python TTS daemon (Qwen3-TTS) plus edge-tts
- whisper.cpp or Wispr Flow STT backends

## Workflow (HOW)
- Start at `src/mcp-server.ts`; core runtime in `src/tts.ts`, `src/input.ts`, `src/vad.ts`, `src/stt.ts`.
- IPC uses `/tmp/voicelayer.sock` (Voice Bar is the server, MCP connects as client); protocol types in `src/socket-protocol.ts`.
- `voice_speak` is non-blocking; `voice_ask` blocks and uses Silero VAD by default.
- Keep session booking and ring buffer behavior stable (see `src/session-booking.ts`, `src/paths.ts`).
- Tests live in `src/__tests__/`; run `bun test`.
