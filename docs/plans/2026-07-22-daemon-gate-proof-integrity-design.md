# Daemon Gate Proof Integrity Design

**Status:** Approved by the autonomous implementation brief in `docs.local/handoffs/ci-daemon-gate-integrity-boot.md`.

**Date:** 2026-07-22

## Problem

The local merge hook requires a machine-local `.verified/` receipt, but the hosted `daemon-verification-gate` trusts a `Verified-Runtime: <sha>` sentence in the pull request body. An actor with permission to edit the body can therefore satisfy the hosted check without running VoiceBar. The receipt cannot simply be committed: adding it changes the commit SHA, so it cannot bind to the exact PR head it is meant to attest.

The corpus runtime leg also intermittently exits with SIGSEGV. The initial theory was a `SocketServer.stop()` race. Reproduction produced a macOS crash report whose faulting main-thread stack is `objc_release` → autorelease-pool pop → XCTest memory checking. Enabling Zombies made the same runtime interaction complete. Inspection then found that the runtime test directly constructs a subclass of AppKit-managed `NSRunningApplication`, which is not a valid test-double lifecycle. The fix removes that unsupported Objective-C object rather than adding a retry or changing production socket behavior without evidence.

## Evidence Mechanism

Use a signed annotated Git tag named `runtime-verified/<full-head-sha>`.

The verification script will continue to create the local `.verified/verified-runtime-*.txt` receipt. After a successful interactive or corpus run, it will create an SSH-signed annotated tag that:

- points to the exact tested commit;
- carries the exact `Verified-Runtime: <full-head-sha>` marker and the receipt body;
- is SSH-signed by an allowlisted public key; and
- is pushed to `origin` without changing the tested commit.

The hosted workflow will call a tracked predicate script extracted from the immutable base commit rather than executing the PR copy. That script computes the daemon-sensitive diff with rename detection disabled so both the deleted sensitive source and added destination are visible, skips when no sensitive path changed, fetches/requires the exact tag for the PR head, checks the tag target, validates the marker, and runs native SSH signature verification. The trusted public key comes from the repository Actions variable `VOICELAYER_RUNTIME_SIGNER`, not from the PR checkout, so an attacker cannot authorize a new key in the same diff. PR-body text is informational only and has no authority.

The introducing PR has a one-time bootstrap exception pinned to its exact pre-gate base SHA because that base does not yet contain the predicate. The bootstrap PR copy must also match the SHA-256 digest stored outside the checkout in repository Actions variable `VOICELAYER_DAEMON_PROOF_PREDICATE_SHA256` (`bbe6f46f057027620b7ecddfc2d2215b62d0157c2cf975c00c36af2fd28d2098`). After the introducing PR merges, later base commits contain the trusted predicate and the bootstrap SHA cannot match a current base. The introducing PR still depends on code review of the workflow that enforces this digest; this design does not claim that a workflow can cryptographically self-bootstrap its own definition.

During review, the lead merged current `main` into the PR branch to clear its behind state, advancing the immutable PR base from `5396e4cfb87b9e0d715af9fc9dd39cb2d1ae5284` to `d292366078594e900f9e3f4201297a104e650e47`. The one-time bootstrap was re-pinned to only that new base; the older base is no longer accepted and no general fallback was added.

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
- pointing the expected tag name at a different commit; and
- renaming a sensitive source to a non-sensitive destination to evade path matching.

The design does not prevent:

- a trusted signer from attesting dishonestly;
- compromise of the signing private key; or
- a local process that is already authorized to invoke the signing key from requesting a false signature.

The signing key should therefore be hardware- or user-presence-backed, with per-use approval. GitHub stores only the public key in a repository Actions variable. CI proves provenance and exact-SHA binding; it cannot independently observe what happened in front of the microphone. A repository administrator who can change that Actions variable or the base-branch workflow remains inside the trust boundary.

## Runtime Test Lifetime Design

The runtime interaction test uses `NSRunningApplication.current` as the stable paste-target identity and passes the cmux bundle identifier directly to the insertion-strategy function under test. It no longer subclasses and default-constructs `NSRunningApplication`, whose instances are owned by AppKit.

The complete isolated corpus/runtime leg is the regression because the failure occurred during XCTest autorelease-pool teardown after that long interaction. Five consecutive non-Zombie runs must pass after the change. A deterministic retry is intentionally not added: it would hide an invalid-object fault rather than repair it.

## Error Handling

- A missing signing key, failed signature, failed tag push, mismatched target, stale SHA, missing tag, or malformed marker fails closed.
- Signer configuration is validated only after the predicate finds a sensitive path, so unrelated PRs retain the intended skip even during signer rotation.
- Existing tags are never silently overwritten. A matching valid tag is idempotent; any conflicting tag fails with remediation instructions.
- The verifier writes no publishable proof until runtime verification and the clean-tree/head-stability checks have completed.
- Shell temporary files use `mktemp` and traps; paths and arguments are quoted.

## Verification

- Bun tests exercise skip behavior, sensitive-path renames, missing/unsigned/stale/wrong-target proofs, valid signed proof, verifier tag creation, and failure to publish.
- A captured pre-fix crash report demonstrates the invalid Objective-C teardown; five consecutive isolated corpus/runtime legs stress the corrected test lifetime.
- `shellcheck` and the cyber grep protocol cover all changed shell/workflow surfaces.
- Full tracked TypeScript tests and the full Swift package suite run before PR creation.
- The final branch must be runtime-verified at its exact head, producing a signed tag that the hosted predicate accepts.
