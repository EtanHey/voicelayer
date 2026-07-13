# Re-transcribe Polish Persistence Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Ensure every retained or archived recording retranscription goes through STT polish after any daemon restart.

**Architecture:** Bind a versioned polish-surface JSON sidecar to the retained WAV path. Persist it with retained captures, resolve it on retranscription, and use `dictation` as the safe fallback for missing or invalid metadata.

**Tech Stack:** TypeScript, Bun test runner, Node-compatible filesystem APIs.

---

### Task 1: Specify fresh-daemon and persisted-surface behavior

**Files:**
- Test: `src/__tests__/input-durability.test.ts`

1. Spy on `polishTranscriptionText` and capture the requested surface.
2. Add a test that writes a retained WAV with no sidecar, retranscribes it, and expects `dictation` polish.
3. Run the focused test and confirm it fails because current code passes `null` and skips the spy.
4. Add a test that retains a capture with `voice_ask`, retranscribes it from persisted state, and expects `voice_ask`.
5. Add an archived-recording assertion that polish receives `dictation`.

### Task 2: Persist and resolve retained polish metadata

**Files:**
- Modify: `src/paths.ts`
- Modify: `src/input.ts`
- Test: `src/__tests__/input-durability.test.ts`

1. Add a retained-recording metadata path derived from the retained WAV path.
2. Atomically write a versioned sidecar for valid surfaces and delete stale sidecar state when the surface is null.
3. Add a defensive reader that accepts only `dictation` or `voice_ask` and otherwise returns the `dictation` fallback.
4. Make `retranscribeLastCapture()` use the resolved non-null surface.
5. Run the focused tests and confirm they pass.

### Task 3: Verify behavior and prepare the PR

**Files:**
- Verify all modified files.

1. Run the focused input durability tests.
2. Run `bun run typecheck`.
3. Run `bun test` from this clean worktree.
4. Run the bounded pre-commit review and address actionable findings.
5. Commit, push, open a ready-for-review PR to `main`, and request `@codex review` plus `@cursor @bugbot review`.
6. Report the runtime marker as pending for `voicelayerLead`; do not fabricate daemon verification.
