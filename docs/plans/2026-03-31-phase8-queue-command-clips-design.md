# Phase 8 Queue Command Clips Design

**Status:** Approved from task prompt and ready for implementation

## Goal

Turn VoiceBar from raw dictation into a usable voice interface by adding:
- interruptible queued TTS with visible queue state
- selection-aware Command Mode with AX-first writes and clipboard fallback
- FieldCut-style clip markers that emit downstream events for the gem pipeline

## Constraints

- Keep the existing VoiceLayer socket architecture.
- Use the same VoiceBar pill/panel rather than a separate app surface.
- Prefer AX for Command Mode selection reads and writes.
- Verify AX writes by reading back `kAXValueAttribute`.
- Fall back to clipboard paste only when AX is unavailable or unverifiable.
- Clip markers must be emitted as first-class protocol events, not inferred from logs.
- TDD is mandatory.

## Recommended Approach

Use the existing Bun playback queue as the core and extend it rather than replacing it. The queue already serializes playback, handles priorities, and exposes queue snapshots. Phase 8 will add command-oriented metadata, fade-to-stop style barge-in semantics, and protocol events that the Swift app can render as explicit queue/command/clip UI states.

For Command Mode, keep orchestration in Swift because AX and clipboard APIs are native there. Bun should emit intent and transcript payloads; Swift should resolve current selection, apply transformation text, verify the result via AX readback, and only then fall back to pasteboard-based replacement. This keeps the same speech pipeline for all modes while using the platform-native control plane for app text fields.

For clip marking, treat markers as transport events with stable payloads. Bun can emit marker boundaries during playback or command execution, and Swift can surface them in the pill/panel immediately while downstream consumers subscribe to the same event stream.

## Architecture

### Bun

- `src/tts.ts`
  Add richer queue metadata for interruption policy, collapse keys, and clip marker payloads.
- `src/socket-protocol.ts`
  Extend the socket schema with command-mode commands and clip-marker events.
- `src/socket-handlers.ts`
  Route VoiceBar-issued command-mode requests and replay/stop interactions into the queue and event pipeline.

### Swift

- `flow-bar/Sources/VoiceBar/VoiceState.swift`
  Track command-mode state, pending selection context, queue emphasis, and clip marker HUD state.
- `flow-bar/Sources/VoiceBar/BarView.swift`
  Render queue state more explicitly and add command/clip affordances in the pill and panel.
- New helper files
  Add AX and clipboard command helpers as separate native seams so they can be tested without socket coupling.

## Data Flow

1. VoiceBar issues a command-mode request over the existing socket.
2. Bun receives the request, emits command-mode state, and either queues speech or accepts a final transcript payload.
3. Swift resolves current selection via AX, applies or replaces text, then verifies by reading `kAXValueAttribute`.
4. If AX read/write fails verification, Swift falls back to clipboard-driven replace/paste.
5. Bun emits clip marker events with stable payloads.
6. Swift shows the marker state immediately; downstream gem consumers read the same event stream.

## Error Handling

- If AX selection lookup fails, surface a recoverable Command Mode error and move to clipboard fallback.
- If AX write succeeds but readback mismatches, treat that as a failed write and use fallback.
- If queue barge-in occurs, emit explicit queue snapshots so the UI never infers stale items.
- If clip marker emission fails validation, drop the marker and emit a recoverable error instead of sending malformed events downstream.

## Testing Strategy

- Red tests first for:
  - queue interruption, fade-to-stop/barge-in, and debounce collapse
  - protocol parsing/serialization for command-mode and clip-marker events
  - socket command routing for command mode
  - Swift VoiceState handling for command-mode state and clip markers
  - AX helper read/write verification and clipboard fallback seams
- Full verification at the end:
  - `bun test`
  - `swift test --package-path flow-bar`

## Notes

- BrainLayer lookup failed in this session because the MCP transport was closed, so this design is based on local repo context plus the Phase 8 task spec.
