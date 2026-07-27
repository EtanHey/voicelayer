# Push-to-End Rename and Gate Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Rename the misleading MCP `press_to_talk` option to `push_to_end`, keep VAD as the protected MCP default, and require an explicit environment opt-in before an MCP agent can request manual-stop capture.

**Architecture:** There are two distinct surfaces. The agent-facing MCP `voice_ask` parameter is renamed, gated, and audited. The trusted VoiceBar command socket continues to accept and honor `press_to_talk` without the MCP gate or a deprecation warning because it represents a physical F5/tap action. Keep the existing `"vad"`/`"ptt"` state and archive mode values because they are a stable VoiceLayer-to-VoiceBar wire contract. Add one TypeScript policy helper for MCP `push_to_end` requests; legacy MCP `press_to_talk` is warned about and discarded before capture. VoiceSDK's separate `"push_to_talk"` listen mode is documented as an out-of-scope follow-up.

**Tech Stack:** TypeScript, Bun tests, Zod, MCP JSON Schema, NDJSON socket protocol.

---

## Task 1: Specify the MCP-facing behavior

**Files:**
- Modify: `src/__tests__/mcp-schemas.test.ts`
- Modify: `src/__tests__/mcp-handler.test.ts`
- Modify: `src/__tests__/soundlayer-mcp-compatibility.test.ts`

**Step 1: Write failing schema and description tests**

- Require `push_to_end` in the Zod and JSON schemas.
- Require the tool description to state that automatic silence detection is disabled, speech silence will not stop recording, explicit user intent is required, and the environment gate is mandatory.
- Require `press_to_talk` to be absent from the advertised schema.

**Step 2: Write the four required capture-routing tests**

- Gate open plus `push_to_end: true` passes `true` to `waitForInput`.
- Missing `push_to_end` passes `false` to `waitForInput`.
- Legacy `press_to_talk: true` passes `false` and emits a deprecation warning naming `push_to_end`.
- Gate closed plus `push_to_end: true` passes `false` and emits a gate warning.

**Step 3: Run the focused tests and save the RED output**

Run:

```bash
bun test src/__tests__/mcp-schemas.test.ts src/__tests__/mcp-handler.test.ts src/__tests__/soundlayer-mcp-compatibility.test.ts
```

Expected: failures because `push_to_end`, warnings, and the gate do not exist yet.

## Task 2: Add the centralized gate and MCP rename

**Files:**
- Create: `src/push-to-end.ts`
- Modify: `src/schemas/mcp-inputs.ts`
- Modify: `src/mcp-tools.ts`
- Modify: `src/handlers.ts`

**Step 1: Implement the policy helper**

- Honor `push_to_end` only when `VOICELAYER_ALLOW_PUSH_TO_END=1`.
- Emit a single-line warning when a requested flag is ignored.
- Emit a single-line deprecation warning when legacy `press_to_talk` is present.
- Call `appendControlLayerEvent` every time the gate is honored with `caller` and `push_to_end: true`.

**Step 2: Rename the MCP schema and handler path**

- Advertise and validate only `push_to_end`.
- Detect legacy input from the raw MCP argument object, warn, and do not forward it.
- Resolve the gate immediately before calling `waitForInput`.
- Rename response-formatting identifiers to `pushToEnd`.

**Step 3: Run the focused tests**

Expected: the new MCP tests pass.

## Task 3: Rename internal capture identifiers and protect the socket boundary

**Files:**
- Modify: `src/input.ts`
- Modify: `src/format-response.ts`
- Modify: `src/soundlayer/contracts.ts`
- Modify: affected files under `src/__tests__/`

**Step 1: Rename TypeScript and telemetry fields**

- Rename `pressToTalk` to `pushToEnd`.
- Rename internal capture journal fields to `push_to_end`.
- Keep metadata/state `mode` values `"vad"` and `"ptt"` unchanged.

**Step 2: Preserve the trusted VoiceBar socket**

- Keep the VoiceBar command wire field as `press_to_talk`.
- Honor it without `VOICELAYER_ALLOW_PUSH_TO_END`, warnings, or deprecation.
- Keep the corpus replay harness on the existing VoiceBar socket contract.
- Add a regression test proving this physical-user surface remains distinct from MCP.

**Step 3: Run affected tests**

Run:

```bash
bun test src/__tests__/input.test.ts src/__tests__/ack-protocol.test.ts src/__tests__/corpus-replay-verify.test.ts src/__tests__/format-response.test.ts
```

Expected: all affected tests pass.

## Task 4: Verify real regression coverage

**Files:**
- No permanent file changes.

**Step 1: Save the production diff**

Create a temporary patch containing production changes only.

**Step 2: Reverse the production patch while keeping the new tests**

Run the focused required-behavior tests.

Expected: gate-open, legacy-warning, gate-closed-warning, schema, and description tests fail. The absent/default VAD test may still pass and must be labeled a regression guard.

**Step 3: Restore the production patch**

Re-run the same focused tests.

Expected: all focused tests pass.

## Task 5: Full verification and PR

**Files:**
- Create: `docs.local/qa/push-to-end/report.md` (gitignored terminal report)

**Step 1: Run required verification**

```bash
bun test src/__tests__/
npx tsc --noEmit
```

Swift tests are not required because no Swift file will be modified.

**Step 2: Review and commit**

- Confirm the branch is `fix/push-to-end-rename-gate`.
- Confirm `flow-bar/Sources/VoiceBarUI/VoiceState.swift` is untouched.
- Confirm the VoiceBar socket still accepts and honors `press_to_talk` without the MCP gate.
- Run the bounded local CodeRabbit review.
- Commit the verified TypeScript, tests, and plan.

**Step 3: Push and open a ready PR against `main`**

- Explain the env/config gate choice.
- Explain that legacy ignore-and-warn behavior is MCP-only.
- Explain why the trusted VoiceBar socket deliberately keeps `press_to_talk` without a gate.
- Explain the preserved `"vad"`/`"ptt"` wire values.
- Note the dormant VoiceSDK `"push_to_talk"` mode as an out-of-scope follow-up.
- Request `@codex review` and `@cursor @bugbot review`.
- Do not merge.

**Step 4: Write the terminal report**

Include the latest commit, RED output, GREEN output, PR URL, gate justification, and wire-value decision. End the file with exactly `TASK_DONE`.
