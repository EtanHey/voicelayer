# VL-6 Developer ID Signing Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Make VoiceBar builds carry source provenance, use stable Developer ID signing, and produce notarized Homebrew release zips without touching the resident app during release builds.

**Architecture:** Keep `flow-bar/build-app.sh` as the single bundle builder and mirror BrainBar's proven stamp/sign/notary sequence. Extend the deploy freshness gate to compare the installed bundle's `Info.plist` `GitCommit` and `BuildTimeUTC` against the current checkout, then add a small release wrapper that builds to an isolated artifact directory for GitHub release/Homebrew cask bumps.

**Tech Stack:** Bash, Swift Package Manager, macOS `codesign`/`notarytool`/`stapler`/`spctl`, Bun tests.

---

### Task 1: RED Tests

**Files:**
- Modify: `src/__tests__/build-app-bundle.test.ts`
- Modify: `src/__tests__/deploy-check.test.ts`

**Steps:**
1. Add static tests requiring Developer ID identity, hardened runtime, real timestamp, plist stamp helpers, notarytool submit, stapler, and release zip notarization.
2. Add deploy-check tests that fail when `GitCommit` drifts or `BuildTimeUTC` is missing.
3. Run `bun test src/__tests__/build-app-bundle.test.ts src/__tests__/deploy-check.test.ts`.
4. Confirm the tests fail for the missing behavior.

### Task 2: Build Script GREEN

**Files:**
- Modify: `flow-bar/build-app.sh`

**Steps:**
1. Add `git_commit`, `build_time_utc`, `plist_set_string`, and `stamp_info_plist`.
2. Change the default signing identity to `Developer ID Application: Etan Heyman (PPN23G925Y)`.
3. Sign with `--options runtime --timestamp`.
4. Add optional notary auth via `VOICEBAR_NOTARY_PROFILE`/Apple ID/API key env vars.
5. Submit a temporary zip to `xcrun notarytool submit --wait`, staple, validate, and assess.
6. Add `VOICEBAR_RELEASE_ZIP` support and require notarization before writing a Homebrew zip.

### Task 3: Deploy Check GREEN

**Files:**
- Modify: `src/deploy-check.ts`
- Modify: `src/deploy-check-cli.ts`

**Steps:**
1. Add `repoGitCommit`, `installedGitCommit`, and `installedBuildTimeUTC` to `DeployProbe`.
2. Read `GitCommit` and `BuildTimeUTC` from `Info.plist` with `plutil`.
3. Read current checkout SHA with `git rev-parse HEAD` when available.
4. Fail stale installed `GitCommit` when the repo SHA is known.
5. Fail missing or invalid `BuildTimeUTC` and use it as the process freshness timestamp.

### Task 4: Homebrew Release Wiring

**Files:**
- Add: `scripts/release-voicebar.sh`

**Steps:**
1. Build to `dist/voicebar-release/<version>/VoiceBar.app`.
2. Pass `--no-stop --no-relaunch` so the resident `/Applications/VoiceBar.app` is untouched.
3. Default to the known local notary profile `notary-layers`.
4. Produce `VoiceBar.zip`, print its sha256, and print the matching `gh release upload` plus `EtanHey/homebrew-layers/Casks/voicebar.rb` bump instructions.

### Task 5: Verification And PR Loop

**Steps:**
1. Re-run targeted tests.
2. Run `bun test`, `bun run typecheck`, and `swift test`.
3. Build/sign/notarize to an isolated artifact path using `VOICEBAR_NOTARY_PROFILE=notary-layers`.
4. Inspect `Info.plist`, signature, stapler, spctl, and zip checksum.
5. Commit, push, open PR, invoke reviewers, watch CI, address critical/high feedback, and update the T6 collab file.
