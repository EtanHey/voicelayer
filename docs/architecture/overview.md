# Architecture Overview

VoiceLayer is a lightweight MCP server that bridges Claude Code with your microphone and speakers. It's built with Bun and TypeScript, using system-level tools for audio I/O.

## System Architecture

```
Claude Code Session
    │
    │  MCP (JSON-RPC over stdio)
    │
    ▼
┌────────────────────────────┐
│     VoiceLayer MCP Server  │
│     (mcp-server.ts)        │
│                            │
│  ┌─────────┐  ┌─────────┐ │
│  │  TTS    │  │  Input  │ │
│  │ (tts.ts)│  │(input.ts)│ │
│  └────┬────┘  └────┬────┘ │
│       │            │       │
│  ┌────▼────┐  ┌────▼────┐ │
│  │edge-tts │  │   sox   │ │
│  │(python3)│  │  (rec)  │ │
│  └────┬────┘  └────┬────┘ │
│       │            │       │
│  ┌────▼────┐  ┌────▼────┐ │
│  │ afplay/ │  │   STT   │ │
│  │  mpv    │  │(stt.ts) │ │
│  └─────────┘  └────┬────┘ │
│                    │       │
│          ┌─────────┴──┐    │
│          │whisper.cpp │    │
│          │or Wispr API│    │
│          └────────────┘    │
│                            │
│  ┌──────────────────────┐  │
│  │  Session Booking     │  │
│  │  (session-booking.ts)│  │
│  └──────────────────────┘  │
└────────────────────────────┘
```

## Module Responsibilities

| Module | File | Responsibility |
|--------|------|---------------|
| **MCP Server** | `mcp-server.ts` | Tool definitions, request routing, argument validation |
| **TTS** | `tts.ts` | Text-to-speech via edge-tts, audio playback, rate adjustment |
| **Input** | `input.ts` | Mic recording via sox, silence detection, PCM/WAV handling |
| **STT** | `stt.ts` | Backend abstraction — whisper.cpp (local) or Wispr Flow (cloud) |
| **Session Booking** | `session-booking.ts` | Lockfile mutex for mic access, stale lock cleanup |
| **Paths** | `paths.ts` | Centralized `/tmp` path constants |
| **Audio Utils** | `audio-utils.ts` | Shared audio utilities (RMS calculation) |
| **Session** | `session.ts` | Session lifecycle management (save/load/generate) |
| **Report** | `report.ts` | QA report rendering (JSON -> markdown) |
| **Brief** | `brief.ts` | Discovery brief rendering (JSON -> markdown) |
| **Schemas** | `schemas/` | QA and discovery category/checklist definitions |

## Data Flow: Converse Mode

The most complex mode — full round-trip voice Q&A:

```
1. Agent calls voice_ask("How does it look?")
                │
2. Session booking check (lockfile)
                │
3. edge-tts synthesizes → /tmp/voicelayer-tts-PID-N.mp3
                │
4. afplay speaks the question (stop-signal polling at 300ms)
                │
5. sox starts recording → raw 16kHz 16-bit mono PCM to stdout
                │
6. PCM streamed in 1-second chunks, RMS calculated per chunk
                │
7. Stop condition met:
   - User: touch /tmp/voicelayer-stop
   - Silence: 5 consecutive chunks below threshold
   - Timeout: configurable (default 300s)
                │
8. PCM wrapped in WAV header → /tmp/voicelayer-recording-PID-TS.wav
                │
9. whisper.cpp transcribes WAV → text
                │
10. Text returned to agent, temp files cleaned up
```

## External Dependencies

VoiceLayer delegates audio I/O to battle-tested system tools rather than bundling audio libraries:

| Tool | Purpose | Install |
|------|---------|---------|
| **python3 + edge-tts** | Neural TTS (Microsoft, free) | `pip3 install edge-tts` |
| **sox/rec** | Mic recording (16kHz mono) | `brew install sox` |
| **afplay** (macOS) | Audio playback | Built-in |
| **mpv/ffplay/mpg123** (Linux) | Audio playback | Package manager |
| **whisper.cpp** | Local STT | `brew install whisper-cpp` |

This approach keeps VoiceLayer lightweight (~500 lines of TypeScript) while leveraging mature, well-tested audio tools.

## File-Based IPC

VoiceLayer uses the filesystem for inter-process communication:

| File | Purpose | Pattern |
|------|---------|---------|
| `/tmp/voicelayer-session.lock` | Mic mutex | Atomic `wx` create, read JSON |
| `/tmp/voicelayer-stop` | Stop signal | Touch to create, poll existence |
| `/tmp/voicelayer-thinking.md` | Think log | Append-only markdown |

This is intentional — MCP servers can't push UI updates to Claude Code. File-based signaling is the only reliable cross-process communication pattern available.
