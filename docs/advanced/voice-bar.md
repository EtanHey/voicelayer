# Voice Bar

The Voice Bar is a **floating macOS widget** that provides visual feedback and quick controls for VoiceLayer. Built with SwiftUI, it connects to the MCP server via Unix socket IPC.

## Requirements

- macOS 14+ (Sonoma or later)
- Swift toolchain (Xcode or `swift` CLI)
- VoiceLayer MCP server running

## Quick Start

```bash
# Build and launch
voicelayer bar

# Stop
voicelayer bar-stop
```

The Voice Bar appears as a floating pill at the top of your screen.

## Features

### State Display

The pill changes appearance based on VoiceLayer state:

| State | Appearance |
|-------|-----------|
| **Idle** | Collapses to a small dot after 5s of inactivity |
| **Speaking** | Expanded pill with teleprompter showing spoken text |
| **Recording** | Pulsing waveform visualization driven by audio levels |
| **Transcribing** | Loading indicator while whisper.cpp processes |
| **Error** | Red indicator with error message |

### Teleprompter

During `voice_speak`, the pill expands to show the text being spoken:

- Short text (8 words or fewer) renders centered
- Long text uses a scrolling view with automatic scroll-to-current
- Wider reading area (220pt, 11pt font) for comfortable reading
- Punctuation-aware timing — pauses at periods and commas

### Audio Waveform

During recording, a real-time waveform visualization shows microphone levels:

- RMS audio levels received every ~100ms via socket events
- Bar heights animated with spring physics
- Visual confirmation that the mic is picking up audio

### Click-to-Record

Tap the pill to start recording. When recording stops, the transcribed text is automatically pasted into the active application via `Cmd+V` (CGEvent).

### Draggable Positioning

- Drag the pill anywhere on screen
- Position saved as screen percentage (survives resolution changes)
- Restored on launch and when switching monitors

### Idle Collapse

After 5 seconds of idle state, the pill collapses to a minimal dot. It expands automatically when any voice activity starts, or on hover.

## Architecture

```text
VoiceLayer MCP Server
    │
    │  /tmp/voicelayer.sock (NDJSON)
    │
    ▼
Voice Bar (SwiftUI)
    ├── NWConnection (Unix socket client)
    ├── @Observable VoiceLayerState
    ├── PillView (main UI)
    ├── TeleprompterView (text display)
    └── WaveformView (audio levels)
```

### Socket Protocol

The Voice Bar communicates via NDJSON events over `/tmp/voicelayer.sock`:

**Events (server → client):**

| Event | Fields | Description |
|-------|--------|-------------|
| `state` | `state`, `text?` | State change (idle, speaking, recording, transcribing, error) |
| `speech` | `text`, `index` | Text being spoken |
| `audio_level` | `level` | RMS 0.0-1.0, every ~100ms during recording |
| `transcription` | `text` | Transcription result |
| `error` | `message` | Error message |

**Commands (client → server):**

| Command | Description |
|---------|-------------|
| `stop` | Stop current playback or recording |
| `cancel` | Cancel current operation |
| `replay` | Replay last TTS output |
| `toggle` | Toggle TTS/mic on/off |
| `record` | Start recording |

## Building from Source

```bash
cd flow-bar
swift build -c release
.build/release/FlowBar
```

The Voice Bar uses `NSPanel` with `.nonactivatingPanel` style so it never steals focus from your editor.
