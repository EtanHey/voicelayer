# Phase 7: Live Dictation (v1.5)

> [Back to main plan](../README.md)

## Goal

Add streaming transcription so words appear in the Flow Bar as the user speaks, not just at the end.

## Research Sources

- `docs.local/logs/research-1-whisper-streaming.md` — whisper-server sidecar, chunked HTTP POST, ~1.5-2s latency
- `docs.local/logs/research-4-macos-audio-state.md` — AVAudioEngine for native audio capture (future consideration)

## Architecture Change

**Current (batch):**
```
rec → WAV file → whisper-cli → full text (all at end)
```

**New (streaming):**
```
rec stdout → Bun chunks (3s windows, 500ms overlap) → HTTP POST to whisper-server → partial JSON → socket → bar
```

## Key Technical Decisions

- **whisper-server:** Compile from source (`cmake -DWHISPER_BUILD_SERVER=ON -DWHISPER_METAL=ON`). NOT included in Homebrew.
- **Endpoint:** `POST /inference` with multipart WAV, returns `{"text": "..."}`. One transcription at a time (mutex).
- **Built-in VAD:** whisper-server `--vad` flag uses Silero VAD in C++ — no JS-side VAD needed for dictation.
- **Chunking:** 3s chunks with 500ms overlap. AudioChunker ring buffer, PCM → WAV header, POST to server.
- **Latency:** ~1.5-2s per chunk on M1 Pro with large-v3-turbo. Good enough for dictation.
- **Partial events:** New protocol event `{"type": "transcription", "text": "...", "partial": true}` sent as each chunk completes.
- **Final event:** `{"type": "transcription", "text": "...", "partial": false}` when recording ends.
- **Bar UI:** Recording state expands pill vertically to show ~2 lines of live text, scrolling, word-by-word animation.

## Alternatives Evaluated

| Option | Latency | Quality | Integration | Verdict |
|--------|---------|---------|-------------|---------|
| whisper-server + chunked POST | ~1.5-2s | Excellent | HTTP fetch | **Chosen** — best quality/integration balance |
| WhisperLiveKit (mlx-whisper) | ~3.3s | Excellent | WebSocket | Higher latency, Python sidecar |
| sherpa-onnx | ~160ms | Good | Native npm | Lower quality, but fastest |
| whisper-stream (SDL2) | ~1s | Excellent | Cannot pipe from Bun | Not usable for our architecture |

## Setup Requirements

```bash
# Build whisper-server from source
git clone https://github.com/ggml-org/whisper.cpp
cd whisper.cpp
cmake -B build -DWHISPER_METAL=ON -DWHISPER_SDL2=ON -DWHISPER_BUILD_SERVER=ON
cmake --build build -j --config Release

# Download VAD model for server-side filtering
./models/download-vad-model.sh silero-v6.2.0
```

## Tools

- **Code:** Claude Code (Bun/TypeScript + Swift)
- **Tests:** `bun test`

## Steps

1. Add `voicelayer whisper-server` CLI command — start/stop the sidecar process
2. Create `src/streaming-stt.ts` — AudioChunker, PCM→WAV encoder, HTTP POST to whisper-server `/inference`
3. Write tests for AudioChunker (correct chunk sizes, overlap, WAV header generation)
4. Create `src/dictation.ts` — orchestrates rec → chunk → transcribe → emit partial events loop
5. Wire partial transcription events into socket broadcast: `{"type": "transcription", "text": "...", "partial": true}`
6. Modify `src/input.ts` — add `streamingTranscribe` option that uses dictation pipeline instead of batch
7. Update SwiftUI `VoiceState.swift` — add `partialTranscript` property, update on partial events
8. Update SwiftUI `BarView.swift` — show live text in recording state, expand pill height, word-by-word animation
9. Add whisper-server health check to MCP server startup (optional sidecar)
10. Test with real speech — verify words appear within ~2s
11. Update CLAUDE.md and README with streaming STT section

## Depends On

- Phase 1-6 (full v1 must be working)
- whisper-server compiled and accessible

## Status

- [ ] `voicelayer whisper-server` CLI command
- [ ] AudioChunker + WAV encoder (`src/streaming-stt.ts`)
- [ ] AudioChunker tests
- [ ] Dictation orchestration (`src/dictation.ts`)
- [ ] Partial transcription socket events
- [ ] Streaming option in `input.ts`
- [ ] VoiceState partialTranscript
- [ ] Live text UI in BarView
- [ ] whisper-server health check
- [ ] Real speech testing
- [ ] Docs update
