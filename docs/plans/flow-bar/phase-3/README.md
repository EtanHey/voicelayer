# Phase 3: SwiftUI App Scaffold

> [Back to main plan](../README.md)

## Goal

Create the Flow Bar SwiftUI macOS app — a frameless floating pill at the bottom of the screen with vibrancy, menu bar icon, and no dock icon.

## Research Sources

- `docs.local/logs/research-2-swiftui-window-socket.md` — Complete NSPanel + floating window code
- `docs.local/logs/research-5-waveform.swift` — WaveformView animation code

## Key Technical Decisions

- **Project:** Swift Package Manager executable (`swift build`, no Xcode project)
- **macOS target:** 14+ (required for `@Observable`, `spring(duration:bounce:)`)
- **Window:** `NSPanel` subclass with `.nonactivatingPanel` style mask (MUST be in init styleMask — known bug FB16484811)
- **No dock icon:** `.accessory` activation policy set in `applicationDidFinishLaunching`
- **Vibrancy:** `NSVisualEffectView` wrapper (`.hudWindow` material, `.behindWindow` blending, state forced `.active`) — more reliable than SwiftUI `.ultraThinMaterial` in transparent panels
- **Position:** Bottom of screen, 60% from left edge (20% right of center)
- **Size:** 280x44pt pill, capsule-shaped (24pt corner radius)
- **Not click-through:** `ignoresMouseEvents = false`, `canBecomeKey = true` (for button hit-testing), but `.nonactivatingPanel` prevents focus steal
- **Interaction:** Buttons use `.buttonStyle(.plain)` which responds in non-key windows

## Project Structure

```
flow-bar/
├── Package.swift                 # SPM, macOS 14+
├── Sources/
│   └── FlowBar/
│       ├── FlowBarApp.swift      # @main, AppDelegate, MenuBarExtra
│       ├── FloatingPanel.swift   # NSPanel subclass
│       ├── BarView.swift         # Main pill view
│       ├── WaveformView.swift    # Animated vertical bars
│       ├── VoiceState.swift      # @Observable state model
│       ├── SocketClient.swift    # (stub — wired in Phase 4)
│       └── Theme.swift           # Colors, sizes, animation constants
└── mock_server.py                # Python test harness
```

## Tools

- **Code:** Claude Code (Swift)
- **Build:** `swift build` / `swift run`
- **Preview:** Xcode SwiftUI previews for visual states

## Steps

1. Create `flow-bar/Package.swift` — SPM executable target, macOS 14+
2. Create `FlowBarApp.swift` — `@main` App struct, `@NSApplicationDelegateAdaptor`, MenuBarExtra with connection status + quit
3. Create `VoiceState.swift` — `@Observable` model with mode enum (idle, speaking, recording, transcribing, error, disconnected), transcript, isConnected, sendCommand closure
4. Create `FloatingPanel.swift` — NSPanel subclass with `.nonactivatingPanel`, `.floating` level, transparent background, `canJoinAllSpaces`, `positionAtBottom()` at 60% from left
5. Create `Theme.swift` — color constants (blue #4A90D9 speaking, red #E54D4D recording, gray #8E8E93 idle, yellow #E5A84D error), sizes, animation durations
6. Create `BarView.swift` — main pill view with vibrancy background, state icon, status label, action buttons (stop/finish/toggle/replay), spring animations between states
7. Create `WaveformView.swift` — 7-bar waveform with TimelineView 60fps, idle shimmer / listening sway / speech bounce modes, golden-ratio phase offsets
8. Create `SocketClient.swift` stub — empty class with `connect()`/`disconnect()`/`send()` (wired in Phase 4)
9. Wire everything in AppDelegate: create VoiceState, panel, hosting view, position, show
10. Create `mock_server.py` — Python Unix socket server that cycles through states for testing
11. Verify: `swift build` succeeds, `swift run` shows pill at bottom, menu bar icon visible
12. Test visual states by running mock server

## Depends On

- None (can develop in parallel with Phase 1-2, just needs mock server for testing)

## Status

- [ ] Package.swift
- [ ] FlowBarApp.swift (entry point + MenuBarExtra)
- [ ] VoiceState.swift (@Observable model)
- [ ] FloatingPanel.swift (NSPanel subclass)
- [ ] Theme.swift (colors + sizes)
- [ ] BarView.swift (pill UI)
- [ ] WaveformView.swift (animated bars)
- [ ] SocketClient.swift (stub)
- [ ] AppDelegate wiring
- [ ] mock_server.py
- [ ] Build + run verification
- [ ] Visual state testing with mock server
