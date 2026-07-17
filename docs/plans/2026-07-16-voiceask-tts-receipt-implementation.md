# Voice Ask TTS Receipt Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Disclose the actual engine and voice that synthesized every archived `voice_ask` agent-audio artifact.

**Architecture:** Add actual-used engine and voice scalars to `TextToSpeechResult`, populate them at each successful synthesis branch, carry them through `handleConverse` and `WaitForInputOptions`, and persist them in the existing schema-v2 metadata. Keep signed-off fail-closed semantics and all deferred findings unchanged.

**Tech Stack:** TypeScript, Bun test runner, existing VoiceLayer TTS and recordings archive.

---

### Task 1: Prove actual-used metadata at the TTS seam

**Files:**
- Modify: `src/__tests__/tts.test.ts`
- Modify: `src/soundlayer/contracts.ts`
- Modify: `src/tts.ts`

1. Extend the edge-tts synthesis test to expect `engine: "edge-tts"` and the exact concrete voice used in the spawned edge-tts argv.
2. Run `bun test src/__tests__/tts.test.ts` and verify RED because `TextToSpeechResult` lacks the fields.
3. Add `engine` and `voice` result fields and populate all successful XTTS, F5-TTS, Qwen3, shortcut/fallback edge-tts, and direct edge-tts branches.
4. Rerun the test and verify GREEN.

### Task 2: Prove handler transport and schema-v2 persistence

**Files:**
- Modify: `src/__tests__/soundlayer-mcp-compatibility.test.ts`
- Modify: `src/__tests__/input.test.ts`
- Modify: `src/__tests__/input-durability.test.ts`
- Modify: `src/handlers.ts`
- Modify: `src/input.ts`

1. Make the handler test return actual-used fields different from the requested voice and expect those values in `voiceAskArtifacts`.
2. Expect `agent_tts_engine` and `agent_tts_voice` in the archive metadata tests.
3. Run the targeted tests and verify RED for missing transport/metadata.
4. Require result metadata before recording, add the two artifact fields, validate them at the archive boundary, and write them into `VoiceAskRecordingMetadata` with `schema_version: 2` unchanged.
5. Rerun the targeted tests and verify GREEN.

### Task 3: Verify and publish

**Files:**
- Modify: PR #345 body
- Modify: `/Users/etanheyman/Gits/orchestrator/docs.local/handoffs/2026-07-16-lane1-b16-REPORT.md`

1. Run the targeted B16 suite and `bun run typecheck`.
2. Run `git diff --check` and prove `src/socket-handlers.ts` and `flow-bar/` remain unchanged.
3. Commit and push to `fix/b16-voiceask-archive`.
4. Add one PR-body line documenting signed-off fail-closed behavior when TTS is disabled.
5. Wait for GitHub CI and daemon verification gates to pass; do not merge.
6. Update the report with final SHA, counts, must-fix disposition, signed-off behavior, and deferred scope; ensure its last line is `LANE1_DONE`.
7. Store and search-verify the WHAT+WHY milestone in BrainLayer.
