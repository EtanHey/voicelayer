# Paste-Once and Atomic Clipboard Restore Design

## Status

Amended by the VoiceLayer lead decision on 2026-07-17. The earlier immediate-restore requirement is withdrawn: clipboard restoration must retain the existing bounded production delay because `CGEvent.post` returns before the target is guaranteed to consume Cmd+V. This document records the implementation boundary; it does not authorize a paste-mechanism redesign.

## Goal

Make each VoiceBar dictation paste exactly once and restore the user's previous clipboard after the existing bounded post-paste delay, without changing the existing all-at-once two-tier paste mechanism.

## Constraints

- Preserve the first-tier Accessibility insertion path.
- Preserve the second-tier pasteboard write plus CGEvent Cmd+V path.
- Deliver the complete transcript in one operation; never chunk it.
- Do not rebuild, replace, terminate, or exercise the resident `/Applications/VoiceBar.app`, and do not touch `/tmp/voicelayer.sock` in this worker lane.
- Do not claim long-paste pane survival from this VoiceLayer-only change. That acceptance depends on the paired cmux bracketed-paste/PTY work.

## Root cause

`hotkeyAction` handles every matching key-up as a normal `.keyUp` before it classifies the exact Shift+F5 repaste chord. Shift+F5 key-down can also dispatch `.pasteLastTranscript` while a recording gesture is active. This lets one physical sequence mix a repaste request with recording-gesture release handling.

The clipboard fallback captures the user's pasteboard, writes the transcript, posts the synthetic Cmd+V, and schedules guarded restoration 0.5 seconds later. That bounded window is an accepted tradeoff: restoring immediately can race the target's asynchronous Cmd+V consumption and paste the user's old clipboard into the target, which is the worse corruption class.

## Considered approaches

1. Guard Shift+F5 at hotkey classification and retain the existing 0.5-second guarded clipboard restoration. **Selected by the VoiceLayer lead on 2026-07-17** because it prevents the target-consumption race while preserving proven production behavior.
2. Restore the clipboard immediately after `CGEvent.post` returns. Rejected because event posting does not acknowledge target consumption and can make the target paste the old clipboard.
3. Add target-consumption acknowledgement. Rejected for this PR because it changes the frozen paste mechanism and requires separate operator sanction.

## Design

Classify exact Shift+F5 key-downs separately from generic target key-up. When no gesture is active, key-down remains the sole `.pasteLastTranscript` dispatch and only its recorded paired key-up is consumed without dispatch so the target does not receive an unmatched release. Track pending pairings per keycode in the event-tap context so the key-up is still consumed if Shift is released before F5 and a second configured hotkey is pressed meanwhile. Modifier state alone must never establish a re-paste pairing: when an ordinary F5/F18 hold acquires Shift before release, its key-up remains `.keyUp`. When a gesture is active, Shift+F5 key-down is consumed without repasting, while key-up remains `.keyUp` so an active recording can unwind safely.

After `simulatedPasteHandler()` returns, schedule the existing change-count-guarded clipboard restoration using the production `pasteboardRestoreDelay` value of 0.5 seconds. Preserve the guard that refuses to overwrite clipboard content changed before restoration. Do not change the paste transport or add target acknowledgement.

## Verification

- Hotkey tests prove idle Shift+F5 dispatches one repaste, its later release dispatches none even when Shift is released first or another configured hotkey is pressed, an ordinary hold still releases if Shift is pressed in between, active-gesture key-down cannot repaste, and active-gesture key-up still unwinds.
- Paste tests prove the original clipboard is restored after the bounded delay and that a clipboard change made before restoration is preserved.
- Existing AX-success tests prove the clipboard fallback is not touched when insertion succeeds.
- The full Swift suites plus `bun test src/` provide regression coverage. No resident-app runtime verification is allowed in this worker lane.
