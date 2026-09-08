# Notch + Dictionary investigation evidence

**Baseline:** `e2aed94a98cf99ef11846d6b70f40ebd05874028`

**Run date:** 2026-08-20

**Scope:** current-behavior characterization only; no implementation or live-app verification

## Bug 1 focused characterization

Command:

```bash
bun test \
  src/__tests__/stt.test.ts \
  src/__tests__/input-durability.test.ts \
  src/__tests__/stt-cleanup.test.ts \
  src/__tests__/input.test.ts \
  --test-name-pattern '(includes promptOverride even when language mode is auto|includes language and prompt when an explicit language is configured|omits prompt in auto mode when no promptOverride is present|retranscribes a specific archived recording through the current finalizer and updates the history event in place|applies aliases from the VoiceBar vocabulary snapshot|preserves existing cleanup when QA_VOICE_CORRECTOR is unset or off)'
```

Observed exit: `0`.

```text
6 pass
226 filtered out
0 fail
17 expect() calls
Ran 6 tests across 4 files.
```

These tests prove the current prompt/finalizer/cleanup seams, including the currently intentional auto-prompt omission. They do not prove a future request-scoped policy or real-model safety.

## Bug 2 TypeScript characterization

Command:

```bash
bun test \
  src/__tests__/stt-vocabulary-store.test.ts \
  src/__tests__/cli-vocab.test.ts \
  src/__tests__/socket-handlers-vocab.test.ts
```

Observed exit: `0`.

```text
27 pass
0 fail
66 expect() calls
Ran 27 tests across 3 files.
```

The output included the currently wrong expectations that canonical-equivalent variants are ignored and aliases are deduplicated by the stripping key. Green characterizes the defect; it does not disprove it.

## Bug 2 Swift silent-no-op characterization

Command:

```bash
swift test --package-path flow-bar \
  --filter SettingsViewTests/testAddVariantMatchingCanonicalAliasKeyIsNoOp
```

Observed exit: `0`.

```text
Executed 1 test, with 0 failures (0 unexpected).
```

This regression explicitly freezes the silent no-op that PR N1 must reverse failing-first.

## Swift vocabulary preview/payload characterization

Command:

```bash
swift test --package-path flow-bar \
  --filter 'STTVocabulary(PreviewSearch|CommandPayload)Tests'
```

Observed exit: `0`.

```text
STTVocabularyCommandPayloadTests: 9 tests, 0 failures
STTVocabularyPreviewSearchTests: 3 tests, 0 failures
Selected tests: 12 tests, 0 failures
```

These tests characterize the current mutation-then-list payload flow and draft/search helpers. They do not provide correlated ACK, persistence, or UI feedback proof.

## Evidence limits

- No branch VoiceBar was installed or swapped.
- No real microphone, backend/model, retained personal archive, F5, paste target, sound, seek, focus, or daemon-owner claim was tested.
- Temporary Dictionary probes used synthetic isolated state; no personal entry is reproduced here.
- Every future PR must create its own exact-head test/runtime receipt. This file cannot be reused as implementation evidence.
