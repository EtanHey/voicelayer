# Voice Ask Paired Archive Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Persist every completed `voice_ask` round as one durable archive folder containing the agent prompt audio, the user recording, and both transcripts.

**Architecture:** Extend the existing date/id recording archive in `src/input.ts` with a `voice_ask` source and a paired-artifact variant, while preserving the existing VoiceBar/F5 archive schema and call path unchanged. `handleConverse` will request immutable synthesized prompt bytes from TTS and pass them with the prompt transcript through `waitForInput`; the input layer will atomically publish the completed pair under the existing recordings root using the compatible `audio.wav` and `voicelayer-transcript.txt` user-artifact names, while `/tmp/voicelayer-last-recording.wav` remains only a recovery pointer.

**Retention policy:** Paired `voice_ask` folders are retained indefinitely by default. Each completed ask gets a unique date/id folder; VoiceLayer does not automatically delete evidence after two same-night single-slot losses.

**Tech Stack:** TypeScript, Bun test runner, Node filesystem primitives, Swift VoiceBar build verification.

---

### Task 1: Prove the missing voice_ask archive wiring

**Files:**
- Modify: `src/__tests__/soundlayer-mcp-compatibility.test.ts`
- Modify: `src/__tests__/input.test.ts`

1. Add a handler regression assertion that `handleVoiceAsk` passes `archiveSource: "voice_ask"`, the agent transcript, and the synthesized agent-audio artifact to `waitForInput`.
2. Add an archive regression test that requests a `voice_ask` archive and expects exactly one date/id folder with `agent-audio.mp3`, `agent-transcript.txt`, `audio.wav`, `voicelayer-transcript.txt`, and `metadata.json`.
3. Run the two targeted tests and verify they fail because `voice_ask` is not an accepted archive source and `handleConverse` passes no archive options.

### Task 2: Extend the existing archive without changing F5

**Files:**
- Modify: `src/input.ts`
- Modify: `src/soundlayer/contracts.ts`

1. Expand the internal archive source type to include `voice_ask` while keeping dictation polish mapped only from `voicebar`.
2. Generalize the existing atomic date/id archive writer just enough to publish the paired `voice_ask` filenames and metadata.
3. Keep the `voicebar` writer, filenames, metadata shape, cancel behavior, and `src/socket-handlers.ts` call unchanged.
4. Run the archive test and existing input tests until green.

### Task 3: Carry the synthesized prompt artifact into the paired archive

**Files:**
- Modify: `src/tts.ts`
- Modify: `src/handlers.ts`
- Modify: `src/__tests__/soundlayer-mcp-compatibility.test.ts`

1. Return immutable bytes for the exact synthesized prompt as optional internal TTS-result metadata, without depending on the mutable replay ring.
2. In `handleConverse`, pass those bytes plus the original agent transcript to `waitForInput` with `archiveSource: "voice_ask"`.
3. Keep `voice_speak` response formatting and the blocking `voice_ask` playback order unchanged.
4. Run the targeted handler test and relevant TTS/SoundLayer tests until green.

### Task 4: Verify the complete change

**Files:**
- Verify only: all changed files and frozen `src/socket-handlers.ts`

1. Run the targeted regression tests.
2. Run `bun test` and report exact pass/fail counts from fresh output.
3. Run `bun run typecheck`.
4. Run Swift package tests and `bash flow-bar/build-app.sh` as required by the repo contract.
5. Run the VoiceLayer daemon/runtime verification gate without exercising or modifying the frozen F5 implementation.
6. Inspect the final diff and confirm `src/socket-handlers.ts` has no changes.

### Task 5: Publish for review without merging

**Files:**
- Create outside repo: `/Users/etanheyman/Gits/orchestrator/docs.local/handoffs/2026-07-16-lane1-b16-REPORT.md`

1. Run a bounded local CodeRabbit review and address actionable findings.
2. Commit scoped files, push `fix/b16-voiceask-archive`, and open a ready-for-review PR against `main`.
3. Cite L1 §7 and GAPS B16, document the paired folder structure, and include fresh test evidence in the PR body.
4. Invoke `@codex review` and `@cursor @bugbot review`; inspect available feedback and checks, but do not merge.
5. Write and reread the required report with the verified PR URL, test counts, files touched, and final `LANE1_DONE` line.
6. Store the WHAT+WHY milestone in BrainLayer.
