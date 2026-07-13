# Corpus Replay Runtime Verify Harness Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Finish Phase 1 so `scripts/voicelayer-verify.sh --corpus N` certifies a daemon-touching commit without human input while never touching VoiceLayer's live sockets.

**Architecture:** Keep the preserved Bun harness as the lifecycle owner for specimen selection, isolated sockets, daemon startup, corpus replay, and teardown. After corpus assertions, release the Bun-owned VoiceBar socket while the isolated daemon remains alive, then run a Swift XCTest that binds the same isolated socket and drives production F18, Escape, and stop-button event paths against that daemon. Write the runtime marker only after both legs succeed.

**Tech Stack:** Bun/TypeScript, Bash, Swift/XCTest/AppKit, Unix-domain NDJSON sockets.

---

### Task 1: Require a genuinely polished corpus result

**Files:**
- Modify: `src/__tests__/corpus-replay-verify.test.ts`
- Modify: `src/corpus-replay-verify.ts`

1. Add a failing assertion showing that a transcription with `polished: false`, including a safety-rejected fallback, cannot self-certify.
2. Run `bun test src/__tests__/corpus-replay-verify.test.ts` and confirm the new assertion fails for the expected reason.
3. Add `polished` to `assertCorpusReplayResult`, require `polished === true`, and require the matching `applied` status.
4. Pass the daemon event's `polished` field into the assertion and rerun the targeted test.

### Task 2: Keep the real daemon alive for the event-driven Swift interaction leg

**Files:**
- Modify: `src/__tests__/corpus-replay-verify.test.ts`
- Modify: `src/corpus-replay-verify.ts`
- Modify: `scripts/voicelayer-verify.sh`
- Modify: `src/__tests__/voicelayer-verify-script.test.ts`

1. Add a failing unit test for the interaction-runner contract: the Bun VoiceBar socket server must be stopped before the Swift runner starts, and daemon teardown must remain outside that handoff.
2. Replace the post-daemon shell Swift invocation with a Bun-owned interaction subprocess launched before the daemon's `finally` teardown.
3. Pass only the isolated socket and a staged corpus audio fixture into the Swift subprocess.
4. Keep custom shell runners testable without reintroducing the production sequencing bug.

### Task 3: Drive F18, Escape, and the stop button against the spawned daemon

**Files:**
- Modify: `flow-bar/Tests/VoiceBarTests/SocketServerTests.swift`
- Modify: `src/corpus-replay-verify.ts`

1. Add a runtime-only XCTest fixture that reads the isolated socket path from the verifier environment and refuses either live `/tmp` spelling.
2. Start production `SocketServer` on that path and wait for the already-running MCP daemon to reconnect and register as command owner.
3. Construct real `CGEvent` values for F18 and Escape, route them through production hotkey dispatch, and assert recording then idle state from daemon NDJSON.
4. Start a second F18 recording, render `BarView`, send real AppKit mouse events to the stop button, and assert the daemon produces transcribing/final transcription/idle behavior and VoiceState's paste surface fires.
5. Feed the recorder shim raw PCM from a staged corpus WAV so the stop-button leg has deterministic real audio rather than a fake transcription event.

### Task 4: Verify Phase 1 and publish the worker PR

**Files:**
- Verify: all changed files
- Generated, untracked runtime receipt: `.verified/verified-runtime-<branch>-<short-sha>.txt`

1. Run targeted Bun and Swift tests, then `bun test` and `bash flow-bar/build-app.sh`; record exact pass/fail counts from fresh output.
2. Run an independent Codex review against the mission and current diff; fix all critical or important findings and rerun affected tests.
3. Run bounded `coderabbit review --agent`, commit the exact scoped files, and then run `bash scripts/voicelayer-verify.sh --corpus 10` on the committed SHA.
4. Confirm the live socket paths were not bound or removed, open the generated marker, and verify its `Verified-Runtime` SHA matches `HEAD`.
5. Push the branch, open a ready-for-review PR, include the marker and verification receipt, invoke `@codex review` plus `@cursor @bugbot review`, and stop without merging because merge authority belongs to the lead.

## Review disposition

- CodeRabbit CLI: **PARTIAL** — the first bounded review timed out after reporting one major path-isolation issue; a follow-up was rate-limited. The Swift runtime leg now requires the exact canonical `<verify-work-dir>/voicebar.sock` path before binding, and independent/fallback reviews cover the remaining diff.
- Fallback red-team: runner overrides, dirty-tree certification, and an unbounded Swift subprocess were valid findings and are fixed with regression tests.
- Independent Codex: dirty-tree certification, one-sided transcript similarity, recorder orphaning, and missing production-handoff coverage were valid findings and are fixed with regression tests plus an actual isolated daemon/Swift run.
- Subtitle-only assertion: **not applicable to this STT leg** — the actual paste surface is asserted; `subtitle`/`wordBoundaries` is emitted by the separate TTS playback queue and belongs to the non-blocking Phase 2 visual/TTS work.
- First committed 10-specimen acceptance run failed closed on a real polish rejection. Diagnosis found a grounding false-positive for grammatical `a`→`an` agreement inside a correction-cue sentence; canonicalizing indefinite articles fixed the exact regression, and the same six-specimen prefix then passed with `polish_status=applied` throughout.
