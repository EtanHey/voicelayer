# Contributing

Thanks for considering contributing to VoiceLayer! This guide covers development setup, testing, and the PR process.

## Development Setup

```bash
# Clone the repo
git clone https://github.com/EtanHey/voicelayer.git
cd voicelayer

# Install dependencies
bun install

# Install audio prerequisites (macOS)
brew install sox whisper-cpp
pip3 install edge-tts

# Download a whisper model for STT tests
mkdir -p ~/.cache/whisper
curl -L -o ~/.cache/whisper/ggml-base.en.bin \
  https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.en.bin
```

## Project Structure

```
voicelayer/
├── src/
│   ├── mcp-server.ts          # MCP server entry point
│   ├── tts.ts                 # Text-to-speech (edge-tts)
│   ├── input.ts               # Mic recording (sox)
│   ├── stt.ts                 # STT backends (whisper.cpp + Wispr)
│   ├── audio-utils.ts         # Shared audio utilities
│   ├── paths.ts               # /tmp path constants
│   ├── session-booking.ts     # Lockfile-based session mutex
│   ├── session.ts             # Session lifecycle
│   ├── report.ts              # QA report renderer
│   ├── brief.ts               # Discovery brief renderer
│   ├── schemas/               # QA + discovery category schemas
│   └── __tests__/             # Test files
├── scripts/
│   ├── speak.sh               # Standalone TTS command
│   └── test-wispr-ws.ts       # Wispr Flow WebSocket test
├── flow-bar/                  # SwiftUI macOS Voice Bar app
├── docs/                      # MkDocs documentation (this site)
├── package.json
├── tsconfig.json
├── mkdocs.yml
└── README.md
```

## Running Tests

```bash
# Run all tests
bun test

# Run a specific test file
bun test src/__tests__/tts.test.ts

# Run tests matching a pattern
bun test --grep "session booking"
```

The test suite covers 230 tests with 463 assertions across:

- TTS synthesis and playback
- STT backend detection and transcription
- Session booking (lock/release/stale cleanup)
- Input recording and silence detection
- QA report and discovery brief rendering
- MCP server tool routing

Most tests mock external tools (sox, edge-tts, whisper-cpp) so they run without audio hardware.

## Code Style

- **TypeScript** with strict mode
- **Bun** runtime (not Node.js)
- **No formatting tools** — keep consistent with existing code
- **JSDoc comments** on exported functions
- **Module header comments** describing purpose and dependencies

## Making Changes

### Branch from main

```bash
git checkout main
git pull origin main
git checkout -b feature/your-feature
```

### Commit Messages

Follow conventional commits:

```
feat: add new voice mode
fix: handle edge-tts timeout
docs: update STT backend comparison
test: add session booking race condition test
chore: update dependencies
```

### Submit a PR

1. Push your branch: `git push -u origin feature/your-feature`
2. Create a PR against `main`
3. CodeRabbit will auto-review within 1-2 minutes
4. Address any HIGH severity findings
5. Merge when clean

## Architecture Principles

- **Delegate audio I/O** — use system tools (sox, edge-tts, whisper-cpp), don't bundle audio libraries
- **File-based IPC** — lockfiles and touch-files for cross-process communication
- **Fail gracefully** — never throw from MCP tool handlers, always return structured errors
- **Local-first** — prefer local processing (whisper.cpp) over cloud services
- **Zero config** — sensible defaults, auto-detection for models and backends

## Adding a New Voice Mode

1. Define the tool in `mcp-server.ts` (ListToolsRequestSchema handler)
2. Add a handler function (`handleYourMode`)
3. Route it in the CallToolRequestSchema switch
4. Add tests in `src/__tests__/`
5. Document in `docs/modes/your-mode.md`
6. Add to the nav in `mkdocs.yml`

## Adding a New STT Backend

1. Implement the `STTBackend` interface in `stt.ts`:
   ```typescript
   interface STTBackend {
     name: string;
     isAvailable(): Promise<boolean>;
     transcribe(audioPath: string): Promise<STTResult>;
   }
   ```
2. Add detection logic in `getBackend()`
3. Add tests for availability detection and transcription
4. Document in `docs/architecture/stt-backends.md`
