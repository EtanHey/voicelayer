# Phase 7 STT Pipeline Hebrew Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Land a flag-gated chunked local STT pipeline that supports English, Hebrew, and code-switching on the same path while keeping the current one-shot recording flow as fallback.

**Architecture:** Add a new chunk/session layer above the existing mic/VAD/STT primitives. `input.ts` will route between legacy and chunked capture by feature flag, `vad.ts` will expose boundary helpers for speech windows and forced rollover, `stt.ts` will transcribe chunk windows with continuity prompts and dedup support, and `rules-engine.ts` will normalize final text for both English and Hebrew without a separate Hebrew pipeline.

**Tech Stack:** Bun, TypeScript, Silero VAD, whisper.cpp integration, existing VoiceBar socket flow, Swift verification for VoiceBar.

---

### Task 1: Baseline And Flag Wiring

**Files:**
- Modify: `src/input.ts`
- Modify: `src/socket-handlers.ts`
- Test: `src/__tests__/input.test.ts`

**Step 1: Write the failing test**

Add tests that assert the chunked pipeline is selected only when the Phase 7 feature flag is enabled and that the legacy path remains the fallback.

**Step 2: Run test to verify it fails**

Run: `bun test src/__tests__/input.test.ts`
Expected: FAIL because the flag-gated routing behavior does not exist yet.

**Step 3: Write minimal implementation**

Add a feature-flag check and a new routing seam in `input.ts`/`socket-handlers.ts` without changing default behavior.

**Step 4: Run test to verify it passes**

Run: `bun test src/__tests__/input.test.ts`
Expected: PASS.

**Step 5: Commit**

```bash
git add src/input.ts src/socket-handlers.ts src/__tests__/input.test.ts
git commit -m "feat: gate chunked stt pipeline behind feature flag"
```

### Task 2: Chunk Boundary Session Logic

**Files:**
- Modify: `src/vad.ts`
- Modify: `src/input.ts`
- Test: `src/__tests__/vad.test.ts`
- Test: `src/__tests__/input.test.ts`

**Step 1: Write the failing test**

Add tests for Silero-driven speech boundary tracking, 25-30 second forced chunk rollover, and 2-3 second overlap carry-forward.

**Step 2: Run test to verify it fails**

Run: `bun test src/__tests__/vad.test.ts src/__tests__/input.test.ts`
Expected: FAIL because the session/ring-buffer helpers do not exist yet.

**Step 3: Write minimal implementation**

Add a ring-buffer/chunk session model that accumulates PCM, closes chunks on VAD silence or max duration, and retains overlap bytes for the next chunk.

**Step 4: Run test to verify it passes**

Run: `bun test src/__tests__/vad.test.ts src/__tests__/input.test.ts`
Expected: PASS.

**Step 5: Commit**

```bash
git add src/vad.ts src/input.ts src/__tests__/vad.test.ts src/__tests__/input.test.ts
git commit -m "feat: add chunk boundary session logic for local stt"
```

### Task 3: Chunked STT Continuity And Dedup

**Files:**
- Modify: `src/stt.ts`
- Modify: `src/input.ts`
- Test: `src/__tests__/stt.test.ts`
- Test: `src/__tests__/streaming-stt.test.ts`

**Step 1: Write the failing test**

Add tests for passing prompt continuity into chunk transcription, overlap-aware dedup at the application layer, and assembly of multi-chunk utterances.

**Step 2: Run test to verify it fails**

Run: `bun test src/__tests__/stt.test.ts src/__tests__/streaming-stt.test.ts`
Expected: FAIL because chunk transcription metadata and dedup behavior do not exist yet.

**Step 3: Write minimal implementation**

Expose a chunk transcription API in `stt.ts` and add chunk-result assembly in `input.ts`.

**Step 4: Run test to verify it passes**

Run: `bun test src/__tests__/stt.test.ts src/__tests__/streaming-stt.test.ts`
Expected: PASS.

**Step 5: Commit**

```bash
git add src/stt.ts src/input.ts src/__tests__/stt.test.ts src/__tests__/streaming-stt.test.ts
git commit -m "feat: add chunk continuity and overlap dedup"
```

### Task 4: Rules Engine Normalization

**Files:**
- Modify: `src/rules-engine.ts`
- Test: `src/__tests__/hebrew-stt.test.ts`
- Create or Modify: `src/__tests__/rules-engine.test.ts`

**Step 1: Write the failing test**

Add tests for casing, punctuation, code-token preservation, alias expansion, and mixed Hebrew-English post-processing on the same pipeline.

**Step 2: Run test to verify it fails**

Run: `bun test src/__tests__/hebrew-stt.test.ts src/__tests__/rules-engine.test.ts`
Expected: FAIL because the Phase 7 post-processing behavior is incomplete.

**Step 3: Write minimal implementation**

Extend `rules-engine.ts` to preserve code tokens and normalize mixed-language output without splitting into a Hebrew-specific path.

**Step 4: Run test to verify it passes**

Run: `bun test src/__tests__/hebrew-stt.test.ts src/__tests__/rules-engine.test.ts`
Expected: PASS.

**Step 5: Commit**

```bash
git add src/rules-engine.ts src/__tests__/hebrew-stt.test.ts src/__tests__/rules-engine.test.ts
git commit -m "feat: normalize chunked dictation output with mixed-language rules"
```

### Task 5: Integration And Evaluation Scaffolding

**Files:**
- Modify: `src/socket-handlers.ts`
- Modify: `src/input.ts`
- Create or Modify: `src/__tests__/streaming-stt.test.ts`
- Create or Modify: `tests/eval_mcp_voicelayer.json`

**Step 1: Write the failing test**

Add integration coverage for hotkey-to-text routing through the rules engine and evaluation fixtures for Hebrew/code-switching on the same chunked pipeline.

**Step 2: Run test to verify it fails**

Run: `bun test src/__tests__/streaming-stt.test.ts`
Expected: FAIL because the integration/eval scaffolding is not wired.

**Step 3: Write minimal implementation**

Wire the feature-flagged socket path through the chunked session and land fixture-based evaluation scaffolding even if Distil/CoreML execution remains deferred.

**Step 4: Run test to verify it passes**

Run: `bun test src/__tests__/streaming-stt.test.ts`
Expected: PASS.

**Step 5: Commit**

```bash
git add src/socket-handlers.ts src/input.ts src/__tests__/streaming-stt.test.ts tests/eval_mcp_voicelayer.json
git commit -m "test: add eval scaffolding for phase 7 chunked stt"
```

### Task 6: Full Verification And PR

**Files:**
- Verify all modified files above

**Step 1: Run full verification**

Run: `bun test && swift test --package-path flow-bar`
Expected: PASS.

**Step 2: Pre-commit review**

Run: `cr review --plain`
Expected: No critical findings.

**Step 3: Create PR**

Run the standard GitHub flow:

```bash
git push -u origin phase7/stt-pipeline-hebrew
gh pr create --base main
gh pr comment <PR_NUM> --body "@coderabbitai review"
gh pr comment <PR_NUM> --body "@codex review"
gh pr comment <PR_NUM> --body "@cursor @bugbot review"
gh pr comment <PR_NUM> --body "@greptileai review"
```
