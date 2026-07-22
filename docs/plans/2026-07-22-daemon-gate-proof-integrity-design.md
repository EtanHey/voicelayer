# Daemon Gate Proof Integrity Design

**Status:** Approved by the autonomous implementation brief in `docs.local/handoffs/ci-daemon-gate-integrity-boot.md`.

**Date:** 2026-07-22

## Problem

The local merge hook requires a machine-local `.verified/` receipt, but the hosted `daemon-verification-gate` trusts a `Verified-Runtime: <sha>` sentence in the pull request body. An actor with permission to edit the body can therefore satisfy the hosted check without running VoiceBar. The receipt cannot simply be committed: adding it changes the commit SHA, so it cannot bind to the exact PR head it is meant to attest.

The corpus runtime leg also intermittently exits with SIGSEGV. `SocketServer.stop()` only schedules cleanup, while `deinit` can immediately run queue-owned cleanup from an arbitrary thread. The spawned-daemon test releases the server as soon as the test body exits, making teardown race with socket callbacks and dispatch-source cancellation.

## Evidence Mechanism

Use a signed annotated Git tag named `runtime-verified/<full-head-sha>`.

The verification script will continue to create the local `.verified/verified-runtime-*.txt` receipt. After a successful interactive or corpus run, it will create an SSH-signed annotated tag that:

- points to the exact tested commit;
- carries the exact `Verified-Runtime: <full-head-sha>` marker and the receipt body;
- is signed under the `voicelayer-runtime` namespace by an allowlisted public key; and
- is pushed to `origin` without changing the tested commit.

The hosted workflow will call a tracked predicate script. That script computes the daemon-sensitive diff, skips when no sensitive path changed, fetches/requires the exact tag for the PR head, checks the tag target, validates the marker, and runs native SSH signature verification against the tracked allowlist. PR-body text is informational only and has no authority.

The local `.verified/` receipt remains compatible with the existing local hook. The shared predicate is tracked so the hook can converge on the same signature check without duplicating CI logic.

## Alternatives Considered

### Committed receipt

Rejected. A receipt committed into the PR changes the head SHA. It can only attest its parent or require a proof-only final commit, neither of which satisfies the exact-head requirement.

### Signed Git note

Viable, but not selected. A shared notes ref introduces concurrent-update/merge handling and requires a custom envelope parser. Signed annotated tags provide native signing, verification, target binding, and one independent ref per tested SHA.

### GitHub artifact or protected environment

Not selected as the primary proof. Hosted Linux cannot observe the local macOS F5 → speech → paste interaction. A protected Mac runner could become a future replacement, but that infrastructure does not exist in this repository today.

## Threat Model

The design prevents:

- making CI green by editing the PR body;
- fabricating or modifying proof text without invalidating its signature;
- replaying proof for an earlier commit after the PR head changes; and
- pointing the expected tag name at a different commit.

The design does not prevent:

- a trusted signer from attesting dishonestly;
- compromise of the signing private key; or
- a local process that is already authorized to invoke the signing key from requesting a false signature.

The signing key should therefore be hardware- or user-presence-backed, with per-use approval. The repository stores only the public key. CI proves provenance and exact-SHA binding; it cannot independently observe what happened in front of the microphone.

## Socket Shutdown Design

`SocketServer` will gain a synchronous, idempotent shutdown boundary that executes cleanup on its serial queue and does not return until cancellation has been scheduled and queue-owned state is stable. Queue-specific identity will avoid deadlock if shutdown is invoked from the server queue. `deinit` becomes a defensive fallback, not the normal test teardown path.

The runtime interaction test and reusable fixtures will call the joinable shutdown before releasing windows, sockets, and temporary directories. A focused stress test will repeatedly start, connect, stop, and release a server to make the pre-fix lifecycle failure reproducible without depending on the full corpus.

## Error Handling

- A missing signing key, failed signature, failed tag push, mismatched target, stale SHA, missing tag, or malformed marker fails closed.
- Existing tags are never silently overwritten. A matching valid tag is idempotent; any conflicting tag fails with remediation instructions.
- The verifier writes no publishable proof until runtime verification and the clean-tree/head-stability checks have completed.
- Shell temporary files use `mktemp` and traps; paths and arguments are quoted.

## Verification

- Bun tests exercise skip behavior, missing/unsigned/stale/wrong-target proofs, valid signed proof, verifier tag creation, and failure to publish.
- Swift tests demonstrate the shutdown race before the fix and stress the joinable shutdown after the fix.
- `shellcheck` and the cyber grep protocol cover all changed shell/workflow surfaces.
- Full tracked TypeScript tests and the full Swift package suite run before PR creation.
- The final branch must be runtime-verified at its exact head, producing a signed tag that the hosted predicate accepts.
