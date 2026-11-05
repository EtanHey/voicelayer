# P1 delivery audit

Status: baseline origin/integration/2.3, b53ba2f2 (2.2.61), before P1.

- `VoiceState.record` captures the frontmost external app, AX insertion closure and app/window/element predicate into `dictationTakeTargets`. VoiceBar itself is excluded.
- `handleOwnedRecordingEvent` retains each final in History, deduplicates delivery IDs, then uses that take's start-time target. Missing or changed targets produce `Not pasted: target changed`; replay acknowledges without inserting again.
- `pasteTranscript` rechecks the original identity around activation/paste delays. Native targets use a selection-local AX write; a possible write consumes the attempt even when readback is uncertain. A declined captured native target refuses rather than typing elsewhere.
- Terminals, T3, Helium, Gemini and detected Chromium/Electron/CEF apps skip AX and use synthesized Unicode key events (line breaks are Shift+Return). Terminals strip one trailing newline. Guarded posting checks focus once before posting the complete synchronous batch.
- Shift+F5 uses `.repaste`, resolves the current external app (or previous target when VoiceBar is frontmost), and types. Dictation has no clipboard fallback: Cmd+V remains the user's clipboard. Copy Last explicitly copies retained text.
- Legacy unkeyed finals prefer fresh external focus, but fall back to the start app and cannot target VoiceBar. MCP Ask and archive-only retranscription never auto-paste.

## P1 policy

Select the focused input when a final arrives, including VoiceBar's own editable fields. Preserve delivery-ID deduplication and History/Copy Last. Secure input, secure fields and absent/noneditable focus refuse; no-focus notice: `Nothing to paste into; kept in History` (kept in History, no implicit clipboard overwrite).

The selection-to-write phase runs synchronously on the main actor, with no activation or timer hop. Validate the ready-time target immediately before dispatch. Once a write/batch starts, finish that single attempt against its captured target; never retry or retarget a partial/uncertain write. AX readback may complete later and report uncertainty if focus moved. Synthetic typing has the existing final-check/post window: OS event routing cannot guarantee the same field if an external process changes focus during the synchronous batch. This residual macOS limitation requires lead-owned native acceptance; model results do not prove OS routing.
