# PR #344 Bounded Clipboard Restore Implementation Plan

> Lead approval: 2026-07-17 Option 1. No additional design checkpoint is required.

**Goal:** Rebase PR #344 over merged #329/#328, retain its paste-once and Shift+F5 ordering fixes, and replace its unsafe immediate clipboard restoration with the existing bounded 0.5-second guarded restore.

**Scope:** No target-consumption acknowledgement, paste transport redesign, resident VoiceBar operation, or daemon disruption.

## Task 1: Rebase and preserve merged behavior

1. Rebase `fix/paste-once-atomic-restore` onto current `origin/main`.
2. Resolve `VoiceState.swift` and paste-test conflicts in favor of current main's #329 completion-aware AX flow and #346 development-state behavior.
3. Confirm the branch remains limited to the #344 hotkey fix, bounded restore documentation/tests, and no unrelated mechanism changes.

## Task 2: Restore bounded clipboard behavior test-first

1. Restore/add the focused test asserting the transcript remains on the pasteboard until the 0.5-second scheduled restore executes.
2. Run that test against the immediate-restore branch state and record RED.
3. Restore `pasteboardRestoreDelay`, `scheduleClipboardRestoreIfNeeded`, and the existing change-count-guarded restore call.
4. Run the focused restore tests and confirm the old clipboard is restored only after the callback while newer clipboard content is preserved.

## Task 3: Verify preserved PR behavior

1. Run `swift test --filter HotkeyManagerTests`.
2. Run `swift test --filter VoiceStatePasteTests`.
3. Run `swift test --filter VoiceBarDevStateTests`.
4. Run full `swift test` and full `bun test`.
5. Run `bash scripts/voicelayer-verify.sh --corpus 10` using isolated sockets only.

## Task 4: Publish and converge

1. Commit only the approved #344 amendment and force-push the rebased branch.
2. Update the PR body with the exact runtime receipt and bounded-delay decision.
3. Reply to the blocker comment with the lead decision, new head, and fresh evidence.
4. Request CodeRabbit, Codex, and Cursor/Bugbot reviews; address event-ordering findings test-first, including modifier release before F5 key-up and independent F5/F18 pairings; and confirm the latest required checks.
5. Update the revival report with a fresh `PR344_READY` line and final merged/open state.
