# Flow Bar — VoiceLayer Floating Widget

> Native macOS SwiftUI app that shows voice state and provides stop/toggle/replay controls.
> Communicates with VoiceLayer MCP server via Unix domain socket.

## Vision

Free, open-source Wispr Flow alternative focused on Claude Code. A floating pill at the bottom of the screen that shows what VoiceLayer is doing (speaking, recording, transcribing) and lets the user control it without touching terminal commands.

## Architecture

```
┌─────────────────────┐       Unix socket        ┌──────────────────┐
│  VoiceLayer MCP     │  ◄──────────────────────► │  Flow Bar        │
│  (Bun/TypeScript)   │  /tmp/voicelayer.sock     │  (SwiftUI app)   │
│                     │                           │                  │
│  Creates socket     │  JSON newline-delimited   │  Reconnecting    │
│  Sends state events │  ────────────────────►    │  client          │
│  Receives commands  │  ◄────────────────────    │  Sends commands  │
└─────────────────────┘                           └──────────────────┘
```

**Socket ownership:** VoiceLayer creates `/tmp/voicelayer.sock` on startup. Flow Bar connects as a client and reconnects on disconnect. If VoiceLayer isn't running, the bar shows "disconnected" state.

## Socket Protocol (v1)

### Events (VoiceLayer → Bar)

```json
{"type": "state", "state": "idle"}
{"type": "state", "state": "speaking", "text": "What do you think about...", "voice": "jenny"}
{"type": "state", "state": "recording", "mode": "vad", "silence_mode": "quick"}
{"type": "state", "state": "recording", "mode": "ptt"}
{"type": "state", "state": "transcribing"}

{"type": "speech", "detected": true}
{"type": "speech", "detected": false}

{"type": "transcription", "text": "The user said this"}

{"type": "error", "message": "Mic not available", "recoverable": true}
{"type": "error", "message": "STT backend failed", "recoverable": false}
```

### Commands (Bar → VoiceLayer)

```json
{"cmd": "stop"}
{"cmd": "replay"}
{"cmd": "toggle", "scope": "all", "enabled": false}
{"cmd": "toggle", "scope": "tts", "enabled": false}
{"cmd": "toggle", "scope": "mic", "enabled": false}
```

### State Machine

```
idle → speaking → idle                              (voice_speak)
idle → speaking → recording → transcribing → idle   (voice_ask, speech detected)
idle → speaking → recording → idle                  (voice_ask, no speech / stop)
any  → error → (previous state or idle)
```

### Contracts

- `speaking → idle` fires when afplay process exits (TTS playback done)
- `recording → transcribing` fires when rec stops and whisper/STT starts
- `transcribing → idle` fires after transcription result is sent
- `speech` events fire during `recording` state only, true/false as VAD processes chunks
- Toggle scope matches existing flag files: `all` | `tts` | `mic`
- Per-user socket path deferred (single-user macOS for now)

## SwiftUI Bar Design

### Position & Size

- **Position:** Bottom of screen, 60% from left edge (20% right of center)
- **Size:** ~280x40pt pill with rounded corners (24pt radius)
- **Window level:** Always on top (`.floating` window level)
- **Background:** Translucent vibrancy material (`.ultraThinMaterial`)
- **When idle:** Semi-transparent, subtle presence
- **When active:** Full opacity with state-appropriate colors

### Visual States

```
IDLE:          [ 🎙 VoiceLayer          ]   Muted gray, subtle
SPEAKING:      [ ▶  ||||||||||||    ■   ]   Blue (#4A90D9), animated bars, stop button
RECORDING:     [ 🔴 ||||||||||||    ✓   ]   Red pulse (#E54D4D), live bars, finish button
TRANSCRIBING:  [ ⟳  Processing...      ]   Blue spinner, brief state
ERROR:         [ ⚠  Mic not found   ×  ]   Yellow (#E5A84D), auto-dismiss 3s
DISCONNECTED:  [ ○  Disconnected       ]   Dim gray, no controls
```

### Controls Per State

| State | Left | Center | Right |
|-------|------|--------|-------|
| idle | mic icon (gray) | "VoiceLayer" | — |
| speaking | play icon (blue) | waveform bars (animated) | stop (■) |
| recording | red dot (pulsing) | waveform bars (animated) | finish (✓) |
| transcribing | spinner | "Processing..." | — |
| error | warning icon | error message | dismiss (×) |
| disconnected | empty circle | "Disconnected" | — |

### Interactions

- **Click stop** during speaking → `{"cmd": "stop"}` → kills TTS playback
- **Click finish** during recording → `{"cmd": "stop"}` → ends recording, triggers transcription
- **Click pill** when idle → expand to show toggle controls (TTS on/off, mic on/off)
- **Right-click** → replay last message (`{"cmd": "replay"}`)
- **Drag** → reposition the bar (persist position in UserDefaults)

### Animations

- **Waveform bars:** 5-7 vertical bars that animate height based on `speech.detected` events. Idle shimmer when waiting, active bounce when speech detected.
- **Recording pulse:** Red dot with subtle scale pulse animation (1.0 → 1.2 → 1.0, 1.5s cycle)
- **State transitions:** 200ms crossfade between states
- **Error:** Slide in from bottom, auto-dismiss after 3s with fade out

## VoiceLayer Changes Required

### New: Socket Server (`src/socket-server.ts`)

- Create Unix domain socket at `/tmp/voicelayer.sock` on MCP server startup
- Accept multiple client connections (bar + potential future clients)
- Parse incoming JSON commands, dispatch to existing handlers
- Clean up socket file on shutdown (SIGTERM/SIGINT)

### Modified: State Emission Points

| File | Where | Event |
|------|-------|-------|
| `src/tts.ts` | `speak()` start | `state: speaking` |
| `src/tts.ts` | `playAudioNonBlocking()` process exit | `state: idle` |
| `src/input.ts` | `recordToBuffer()` start | `state: recording` |
| `src/input.ts` | VAD chunk loop | `speech: detected` |
| `src/input.ts` | `recordToBuffer()` finish | `state: transcribing` |
| `src/input.ts` | `waitForInput()` after transcribe | `state: idle` + `transcription` |
| `src/mcp-server.ts` | error catches | `error` event |

### Modified: Command Handlers

Socket `stop` command → write `/tmp/voicelayer-stop` (reuses existing mechanism)
Socket `replay` command → call `playAudioNonBlocking(getHistoryEntry(0))` directly
Socket `toggle` command → call existing toggle logic (write/delete flag files)

## SwiftUI Project Structure

```
flow-bar/
├── Package.swift              # SPM package definition
├── Sources/
│   ├── FlowBarApp.swift       # @main, NSApplication setup, floating window
│   ├── BarView.swift          # Main pill view with state-driven UI
│   ├── WaveformView.swift     # Animated vertical bars
│   ├── SocketClient.swift     # Unix socket connection + reconnect
│   ├── VoiceState.swift       # ObservableObject state model
│   └── Theme.swift            # Colors, sizes, animation constants
└── Resources/
    └── Assets.xcassets         # App icon
```

## v1 Scope (MVP)

- Socket server in VoiceLayer (create, accept, emit events, receive commands)
- State events: idle, speaking, recording, transcribing
- Commands: stop, toggle
- SwiftUI bar: state colors, stop/finish button, idle label
- Basic waveform animation (shimmer, not audio-driven)
- Reconnection logic (retry every 2s)
- Error display (auto-dismiss)

## v1.5 Scope (Live Dictation)

Live transcription in the bar — words appear as you speak, not just at the end.

**STT pipeline change:** Batch → streaming.
- Current: `rec → WAV file → whisper-cli → full text`
- New: `rec stdout → pipe to whisper-cli --stream → parse partial results in real-time`

**New protocol events:**
```json
{"type": "transcription", "text": "The user", "partial": true}
{"type": "transcription", "text": "The user said this", "partial": true}
{"type": "transcription", "text": "The user said this thing", "partial": false}
```

**Bar changes:**
- Recording state shows live text scrolling below the waveform bars
- Text animates in word-by-word as partials arrive
- Final (partial=false) is what gets returned to Claude
- Bar pill expands vertically to fit ~2 lines of text, then scrolls

**whisper.cpp streaming:**
- `whisper-cli --stream` reads from stdin, outputs partial transcripts
- Processes in ~1-2 second windows with overlap
- Latency: ~500ms for first words to appear
- Needs `--print-realtime` flag for streaming output

## v2 Scope (Later)

- Audio-level driven waveform (`{"type": "audio_level", "rms": 0.42}`)
- Pause/resume recording
- Replay controls (right-click menu with history)
- Draggable positioning with persistence
- Expanded idle view (toggles, status)
- Launch at login (Login Items)
- Context-aware STT post-processing (developer vocabulary)

## Development Approach

Red-green-refactor TDD:
1. Socket server tests first (Bun-side)
2. Protocol serialization tests
3. State emission at each integration point
4. SwiftUI previews for each visual state
5. Integration test: MCP → socket → bar state change
