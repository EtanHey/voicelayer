# Daemon Gate Proof Integrity Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Make hosted daemon verification depend on signed, exact-head runtime evidence and eliminate the spawned-daemon XCTest teardown crash.

**Architecture:** A shared shell predicate validates an SSH-signed annotated Git tag whose target and marker equal the PR head. The local verifier creates the existing local receipt, signs/publishes the detached tag, and CI invokes the shared predicate. The runtime test replaces an unsupported `NSRunningApplication` subclass with an AppKit-owned application instance.

**Tech Stack:** Bash, Git annotated tags, OpenSSH signatures, GitHub Actions, Bun tests, Swift/XCTest, GCD dispatch sources.

---

### Task 1: Add exact-head signed-proof predicate

**Files:**
- Create: `scripts/check-daemon-verification-proof.sh`
- Create: `src/__tests__/daemon-verification-proof.test.ts`

**Step 1: Write the failing tests**

Create temporary Git repositories and assert that the predicate:

- exits 0 when only non-daemon files changed;
- still requires proof when a daemon-sensitive source is renamed outside the path law;
- fails when daemon files changed and no tag exists;
- fails for unsigned, wrong-target, wrong-marker, and stale tags; and
- exits 0 only for an SSH-signed `runtime-verified/<head-sha>` tag targeting the exact head.

**Step 2: Verify RED**

Run: `bun test src/__tests__/daemon-verification-proof.test.ts`

Expected: FAIL because `scripts/check-daemon-verification-proof.sh` does not exist.

**Step 3: Implement the minimal predicate**

Use one `daemon_path_matches` function for the tracked path law, `git diff --no-renames` so sensitive rename sources remain visible, strict base/head inputs, native `git verify-tag` against a caller-supplied trust-root file, exact target comparison, and an exact `Verified-Runtime: <head-sha>` line check.

**Step 4: Verify GREEN**

Run: `bun test src/__tests__/daemon-verification-proof.test.ts`

Expected: all proof-predicate tests pass.

### Task 2: Make the local verifier publish signed proof

**Files:**
- Modify: `scripts/voicelayer-verify.sh`
- Modify: `src/__tests__/voicelayer-verify-script.test.ts`

**Step 1: Write failing verifier tests**

Generate an isolated SSH test key and bare remote. Assert that a successful runtime run creates the local receipt, creates the exact signed tag, pushes it, and that the predicate accepts it. Assert signing/push failures produce a non-zero exit and no claimed publish success.

**Step 2: Verify RED**

Run: `bun test src/__tests__/voicelayer-verify-script.test.ts`

Expected: new signed-tag assertions fail.

**Step 3: Implement receipt signing and publishing**

Add one receipt finalizer used by interactive and corpus modes. It writes atomically, creates an SSH-signed annotated tag without overwriting conflicts, verifies it locally with the allowlist, pushes the exact tag ref, and prints the marker only after publication succeeds.

**Step 4: Verify GREEN**

Run: `bun test src/__tests__/voicelayer-verify-script.test.ts src/__tests__/daemon-verification-proof.test.ts`

Expected: all verifier and proof tests pass.

### Task 3: Replace PR-body trust in GitHub Actions

**Files:**
- Modify: `.github/workflows/daemon-verification-gate.yml`
- Modify: `src/__tests__/daemon-verification-proof.test.ts`

**Step 1: Add a failing workflow contract assertion**

Assert that the workflow invokes the tracked predicate, passes base/head SHAs, fetches the exact runtime tag, and no longer reads the PR body as proof.

**Step 2: Verify RED**

Run: `bun test src/__tests__/daemon-verification-proof.test.ts`

Expected: workflow contract test fails against the current body-marker implementation.

**Step 3: Update the workflow**

Construct a temporary allowed-signers file from the repository Actions variable `VOICELAYER_RUNTIME_SIGNER`, extract the predicate from the immutable base SHA, fetch the exact tag ref if present, and invoke that extracted predicate with `"$BASE_SHA" "$HEAD_SHA" "$allowed_signers"`. For the one-time, exact-base-pinned bootstrap, require the PR predicate to match repository Actions variable `VOICELAYER_DAEMON_PROOF_PREDICATE_SHA256`; never accept unanchored trust material from the checkout.

**Step 4: Verify GREEN**

Run: `bun test src/__tests__/daemon-verification-proof.test.ts`

Expected: all predicate and workflow contract tests pass.

### Task 4: Reproduce and repair the runtime-test Objective-C teardown

**Files:**
- Modify: `flow-bar/Tests/VoiceBarTests/SocketServerTests.swift`

**Step 1: Reproduce and capture the fault**

Run the isolated corpus/runtime leg until it fails, then inspect the macOS crash report rather than inferring a lifecycle cause from the non-zero status.

**Step 2: Identify the lifetime boundary**

The reproduced report faults on the main thread in `objc_release` during XCTest autorelease-pool memory checking. Run the exact interaction with Zombies; a clean completion confirms an invalid Objective-C lifetime. Inspect AppKit objects created directly by the test.

Expected: find the directly constructed `NSRunningApplication` test subclass; do not add a socket API or retry without supporting stack evidence.

**Step 3: Remove the unsupported AppKit test double**

Use `NSRunningApplication.current` for stable target identity and pass `com.cmuxterm.app` directly to the pure insertion-strategy function. Preserve every runtime assertion.

**Step 4: Verify GREEN and stress without retries**

Run the isolated corpus/runtime leg five consecutive times without Zombies. Expected: five passes, no SIGSEGV, and no deterministic retry path.

### Task 5: Security and regression verification

**Files:**
- Review every changed file.

**Step 1: Run focused suites**

Run:

- `bun test src/__tests__/daemon-verification-proof.test.ts src/__tests__/voicelayer-verify-script.test.ts`
- `swift test --package-path flow-bar --filter SocketServerTests`
- `shellcheck scripts/check-daemon-verification-proof.sh scripts/voicelayer-verify.sh`

Expected: 0 failures and no ShellCheck warnings.

**Step 2: Run full tracked suites**

Run:

- `bun test $(git ls-files 'src/__tests__/*.test.ts')`
- `swift test --package-path flow-bar`

Expected: 0 failures.

**Step 3: Run the cyber grep protocol**

Run the mandatory critical/high/medium patterns against changed shell, workflow, and Swift files; read every match in context and record the verdict in the PR.

**Step 4: Verify exact-head runtime proof**

Commit the final code, run `./scripts/voicelayer-verify.sh --corpus 1` (and interactive F5 if the gate policy requires it), then run the shared predicate against `origin/main` and `HEAD`.

Expected: the exact signed tag exists, targets `HEAD`, verifies under the allowlist, and the predicate exits 0.

### Task 6: Deliver through the PR loop

**Files:**
- Append: `/Users/etanheyman/Gits/orchestrator/collab/2026-07-17-voicelayer-notch-w1-w2.md`

**Step 1: Review, commit, and push**

Run the local CodeRabbit review with a bounded timeout, address critical findings, commit atomically, and push `fix/daemon-gate-proof-integrity`.

**Step 2: Open a ready PR**

The PR body must explain the signed-tag design, exact-head behavior, test evidence, and the explicit threat-model limitations. It must not claim that CI observes the microphone interaction.

**Step 3: Invoke required reviewers**

Post `@codex review` and `@cursor @bugbot review`, plus available repository reviewers. Wait for and read the review results, reply to every critical/high/major finding, and request re-review after fixes.

**Step 4: Post the seam**

Append the PR URL, design, test evidence, and honest prevention/limitation statement to the required orchestrator collab file.

**Step 5: Merge only after all gates**

Use a merge commit, do not self-merge before the review/CI/runtime gates are satisfied, verify the remote merge result, update tracking, and store the WHAT+WHY milestone in BrainLayer.
