# Paste-Once and Atomic Clipboard Restore Design

## Status

Approved by the binding paste-fix briefs dated 2026-07-15. This document records the implementation boundary; it does not reopen the paste-mechanism decision.

## Goal

Make each VoiceBar dictation paste exactly once and restore the user's previous clipboard immediately after the synthetic Cmd+V returns, without changing the existing all-at-once two-tier paste mechanism.

## Constraints

- Preserve the first-tier Accessibility insertion path.
- Preserve the second-tier pasteboard write plus CGEvent Cmd+V path.
- Deliver the complete transcript in one operation; never chunk it.
- Do not rebuild, replace, terminate, or exercise the resident `/Applications/VoiceBar.app`, and do not touch `/tmp/voicelayer.sock` in this worker lane.
- Do not claim long-paste pane survival from this VoiceLayer-only change. That acceptance depends on the paired cmux bracketed-paste/PTY work.

## Root cause

`hotkeyAction` handles every matching key-up as a normal `.keyUp` before it classifies the exact Shift+F5 repaste chord. Shift+F5 key-down can also dispatch `.pasteLastTranscript` while a recording gesture is active. This lets one physical sequence mix a repaste request with recording-gesture release handling.

The clipboard fallback captures the user's pasteboard, writes the transcript, posts the synthetic Cmd+V, and then schedules restoration for 0.5 seconds later. That timer creates a window in which a manual Cmd+V reads the transcript instead of the user's original clipboard.

## Considered approaches

1. Guard Shift+F5 at hotkey classification and restore the clipboard synchronously after Cmd+V returns. This is selected because the hotkey layer owns gesture state and the paste layer owns pasteboard state.
2. Add a repaste-suppression flag inside `VoiceState`. Rejected because `VoiceState` does not own raw key-down/key-up gesture identity, so the flag would add cross-layer state and could suppress explicit history/context-menu repastes.
3. Remove repaste support entirely. Rejected because the defect only requires hard-guarding release/active-gesture behavior, while explicit Shift+F5, history, context-menu, and local-control repaste remain intentional features.

## Design

Classify the exact Shift+F5 chord before the generic key-up path. When no gesture is active, key-down remains the sole `.pasteLastTranscript` dispatch and key-up is ignored. When a gesture is active, Shift+F5 key-down is consumed without repasting, while key-up remains `.keyUp` so an active recording can unwind safely.

After `simulatedPasteHandler()` returns, invoke the existing change-count-guarded clipboard restoration synchronously. Preserve the guard that refuses to overwrite clipboard content changed during the paste call. Remove only the restore timer and its delay setting.

## Verification

- Hotkey tests prove idle Shift+F5 dispatches one repaste, its later release dispatches none, active-gesture key-down cannot repaste, and active-gesture key-up still unwinds.
- Paste tests prove the original clipboard is restored before the fallback paste call returns to its caller and that a clipboard change made during the synthetic paste is preserved.
- Existing AX-success tests prove the clipboard fallback is not touched when insertion succeeds.
- The full Swift suites plus `bun test src/` provide regression coverage. No resident-app runtime verification is allowed in this worker lane.
