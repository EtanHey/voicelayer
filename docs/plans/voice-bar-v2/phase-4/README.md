# Phase 4: Live Dictation (Streaming STT)

> [Back to main plan](../README.md)

## Goal

Stream audio to whisper-server in real-time so words appear in the Voice Bar as the user speaks (1.5–2s latency).

## Tools

- **Research:** whisper.cpp server API, streaming audio chunking strategies
- **Code:** Claude (TypeScript + Swift)
- **Blocker:** Needs Etan present for whisper-server compile + mic testing

## Prerequisites (before session)

```bash
# Must compile whisper-server from source (NOT in Homebrew)
git clone https://github.com/ggml-org/whisper.cpp
cd whisper.cpp
cmake -B build -DWHISPER_METAL=ON -DWHISPER_SDL2=ON -DWHISPER_BUILD_SERVER=ON
cmake --build build -j --config Release
./models/download-vad-model.sh silero-v6.2.0
```

## Steps

1. `voicelayer whisper-server` CLI command — start/stop whisper-server sidecar
   - Add to `src/cli/voicelayer.sh`
   - Health check endpoint: `GET /health`
   - Auto-start on MCP server startup if binary found
2. `src/streaming-stt.ts` — AudioChunker for streaming
   - Pipe `rec` stdout through Bun in 3s windows with 500ms overlap
   - PCM → WAV encoder (add WAV header to raw PCM chunks)
   - HTTP POST each chunk to whisper-server `/inference`
   - Parse partial transcription from JSON response
3. `src/dictation.ts` — orchestrate recording → chunking → transcription loop
   - Start `rec` to stdout (not file)
   - Pipe through AudioChunker
   - Each chunk → streaming-stt → partial text
   - Broadcast partial transcription events via socket
4. Socket protocol extension — partial transcription events
   - `{"type": "transcription", "text": "...", "partial": true}`
   - `{"type": "transcription", "text": "...", "partial": false}` (final)
5. VoiceState.swift — add `partialTranscript` property
   - Update on partial events
   - Clear on final event
   - Show in pill during recording state
6. Voice Bar recording UI — show live text as user speaks
   - Expand pill to show partial transcription below waveform
   - Words appear incrementally with animation
   - Final transcription replaces partial
7. Integration testing with real mic
   - Latency acceptance testing (target: < 2s)
   - Accuracy testing across accents
   - Background noise resilience

## Depends On

- Phase 2 (recording lifecycle) — nice-to-have but not blocking
- Etan present for steps 1 (compile) and 7 (mic testing)

## Status

- [ ] whisper-server CLI command
- [ ] AudioChunker + streaming STT
- [ ] Dictation orchestrator
- [ ] Partial transcription protocol
- [ ] VoiceState partial transcript
- [ ] Live text in recording UI
- [ ] Integration testing with real mic
