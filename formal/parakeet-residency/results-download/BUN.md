# Focused Bun verification

`bun install --frozen-lockfile`: exit 0, 132 installs across 133 packages checked,
no changes. Repository preload remained enabled for every test run.

Command:

```sh
bun test src/__tests__/recognizer-download.test.ts src/__tests__/recognizer-management.test.ts src/__tests__/recognizer-picker.test.ts src/__tests__/parakeet-server.test.ts
```

Actual terminal summary: 68 pass, 0 fail, 210 expect calls, 4 files.
Includes requests completing while Parakeet transfer and runtime are paused,
same-engine download/delete/load exclusion, independent other-engine download,
publication during capture and during an admitted active request, atomic
hash-pinned publication, cancellation, checksum refusal, runtime failure, and
external-tree preservation.

Additional command:

```sh
bun test src/__tests__/whisper-server.test.ts src/__tests__/whisper-lifecycle-gate.test.ts src/__tests__/recognizer-lifecycle-repairs.test.ts
```

Actual terminal summary: 74 pass, 0 fail, 173 expect calls, 3 files.
Combined: 142 tests passed across 7 files, no failures.

## Checked surfaces

- Entry points: download/cancel, picker, explicit residency, delete.
- Clients: shared request admission remains independent of download ownership.
- Providers: Parakeet ensure and Whisper ensure reject same-engine download.
- Contracts: socket/status shapes unchanged; download states still reported.
- Reverse states: cancel/retry, hash/runtime failure, busy arrival tested.
- Connection modes: no transport change; owner abort remains connected to download signal.
- Docs: model projection and raw TLC results included alongside this receipt.

No live app, microphone, audio, installation, or actual model download was used.
Parent still owns full-suite and installed E2E qualification.

## Prepared child checkout rerun

All seven files above were rerun together in `t3-26cd88d9` after a fresh
`bun install --frozen-lockfile` (132 packages installed, exit 0).
`Bun-focused.log` is the complete captured output: 142 pass, 0 fail,
383 expect calls, 7 files, exit 0. TLC logs were regenerated in this same child
checkout and include their actual process exit statuses.
