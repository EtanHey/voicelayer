# Contributing to VoiceLayer

## Development Setup

```bash
git clone https://github.com/EtanHey/voicelayer.git
cd voicelayer
bun install
```

### Prerequisites

- [Bun](https://bun.sh) v1.0+
- [sox](https://sox.sourceforge.net/) — `brew install sox` (macOS) or `apt install sox` (Linux)
- [edge-tts](https://github.com/rany2/edge-tts) — `pip3 install edge-tts`
- [whisper.cpp](https://github.com/ggerganov/whisper.cpp) (optional) — `brew install whisper-cpp`

## Running Tests

```bash
bun test              # All tests
bun test src/__tests__/tts.test.ts   # Single file
```

Tests mock external dependencies (sox, edge-tts, whisper.cpp) — no hardware required.

## Architecture

```
MCP Client (Claude Code)
    │
    ▼
mcp-server.ts          # Request handler + arg validation
    │
    ├── tts.ts          # Text-to-speech (edge-tts CLI → audio player)
    ├── input.ts        # Mic recording (sox) → STT transcription
    │   └── stt.ts      # Backend abstraction (whisper.cpp / Wispr Flow)
    ├── session-booking.ts  # Lockfile mutex for mic access
    ├── session.ts      # Session persistence (JSON files)
    ├── paths.ts        # Centralized /tmp path constants
    └── audio-utils.ts  # Shared audio utilities (RMS calculation)
```

## Code Style

- TypeScript strict mode (`useUnknownInCatchVariables`, `noImplicitReturns`)
- `catch (err: unknown)` — never `catch (err: any)`
- MCP tool handlers validate `args: unknown` via typed validators
- Log prefix: `[voicelayer]` on stderr (MCP uses stdout for protocol)
- No external linter — keep it simple

## Pull Request Process

1. Create a branch from `main`
2. Make changes, add tests for new functionality
3. Run `bun test` — all 230+ tests must pass
4. Push and open a PR against `main`
5. Address review comments from Cursor Bugbot / CodeRabbit

## Adding a New Voice Mode

1. Add tool definition in `mcp-server.ts` (ListToolsRequestSchema handler)
2. Add validator function (e.g., `validateNewModeArgs`)
3. Add handler function (e.g., `handleNewMode`)
4. Wire it in the switch statement (CallToolRequestSchema handler)
5. Add tests in `src/__tests__/`

## File Paths

All `/tmp` paths are centralized in `src/paths.ts`. Don't hardcode paths — import from there.

| Constant | Path | Purpose |
|----------|------|---------|
| `LOCK_FILE` | `/tmp/voicelayer-session.lock` | Session mutex |
| `STOP_FILE` | `/tmp/voicelayer-stop` | User stop signal |
| `ttsFilePath()` | `/tmp/voicelayer-tts-{pid}-{n}.mp3` | TTS audio (ephemeral) |
| `recordingFilePath()` | `/tmp/voicelayer-recording-{pid}-{ts}.wav` | Recording (ephemeral) |
