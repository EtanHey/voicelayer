# Resident launchd ownership: local verification

Base: `849483ae6f04f0edc8310fcab1793c6e7614c0d0` (`origin/integration/2.3`).
The shared starter returns without mutation for an already verified resident. Otherwise
it enables the canonical job and bootstraps its installed plist if missing. RunAtLoad
owns a newly bootstrapped instance; the helper never kicks it a second time. A loaded
stopped job receives plain `kickstart`, never `-k`. Verification requires running state,
the current user's sole VoiceBar PID, expected executable, and two consecutive good
samples of the same PID. The default 250 × 100 ms budget exceeds the native
acceptedQuitWait (2 × 1 s + 1 s). Every failure is loud.

Supervised-bootstrap recovery preserves the original policy: after a committed
installer fault or non-OPEN gate, jobs stay disabled and admission stays closed.
Availability recovery opens the observed bundle, including old installs outside
/Applications. Only precommit OPEN recovery of the canonical bundle uses the
launchd helper. Nonresident QA paths retain their existing launches.

## Start inventory

| Resident path | Shared starter caller |
| --- | --- |
| Fresh install, reload, cask availability | `scripts/install-voicebar-autostart.sh` |
| Build relaunch (resolved resident predicate) | `flow-bar/build-app.sh` |
| Updater/verify/dedupe/retired-agent EXIT recovery | `scripts/lib/update-gate.sh` |
| Setup and supervised-bootstrap rollback | `src/cli/setup.ts`, `src/update-gate-bootstrap.ts` |
| CLI and MCP auto-start | `scripts/start-voicebar.sh`, `src/voice-bar-launcher.ts` |
| QA resident restore | `scripts/lib/qa-candidate-lifecycle.py` |

Update uses autostart repair/EXIT restore; release/promotion use no-relaunch builds
and cask setup. The exact requested git-grep plus a broader dynamic-open search
found all these sites. QA restore validates its plist, permits an unloaded job,
retires QA and refuses a resident respawn before start. VoiceBar warns on missing
launchd PPID/XPC identity after signal setup. The optional health UI/button is deferred
for S scope. `voicelayer bar` refuses arguments because launchd owns ProgramArguments.
Recording, microphone and F5 mechanics are unchanged.

## Evidence and limits

- RED: 0 pass / 4 fail against baseline restore. Final: launchd cases 4 pass / 0 fail; combined batch 386 pass / 3 deadline failures across 389 tests; serial recheck of all three 3 pass / 0 fail.
- New fake-launchctl cases cover loaded/missing jobs, non-running state and wrong PID, with canonical `open` forbidden.
- Swift debug product VoiceBar builds; typecheck, shell syntax, Python AST parsing, whitespace and docs.local hygiene pass.
- Existing TLC evidence refreshed: 24 expected outcomes (6 positives / 18 designated mutants); source hashes match. This does not prove native launchd behavior.
- Earlier combined run: 335 pass / 54 fail (4 stale expectations; 50 fixture errors quoting undefined environment values). Fixtures now copy defined strings, track the new executable, distinguish canonical/retired jobs and match the install sentinel as a whole line.
- Separate focused rerun: 48 pass / 3 fail, all child deadline exits 143; two canonical restore fixtures reported PID 202. Failed/interrupted receipts remain in `docs.local/install-reliability/` and are not regraded green. The combined run remains red despite the passing serial recheck.

Surface sweep: entries above; clients MCP/CLI/updater/cask/QA; provider canonical launchd;
contracts running state/PID/executable; reverse states missing/stopped/mismatched jobs,
startup failure and rollback; modes share one starter; docs retain inventory and limits.
NOT_RUN: full pre-push, routed review, installed/native/real-agent qualification,
live hotkey/audio/permission health. No live VoiceBar, gate, sockets, preferences or
recordings were touched. Tests use preload/private fixtures/fake tools. After the M1
capacity ruling, focused runs use nice 10; app builds check the exact push-hook process
and wait at 60-second intervals if present. No full suite was started.
The lead must regenerate formal receipts after integrating both branches and P0.

## Round 2

Fail-first against 4bd0f7c0: 0 pass / 10 fail across the ten selected R2 cases.
By defect: B1 recording no-op and bootstrap no-rekick (2); B2 committed failure
and durable-COMMIT sample failure preserve disabled jobs and restore the observed
noncanonical bundle (2); B3 current-user PID scope (1); B4 delayed readiness,
immediate crash and PID churn (3); unmanaged gate restore and auto-F5 helper
routing/native timeout contract (2). The recording test's fixture retains its
capture marker and asserts no enable/bootstrap/kickstart mutation.

The gate restore now refuses an already running unmanaged canonical VoiceBar;
it does not restart it. Auto-F5 restores VoiceBar through start-voicebar.sh.
Existing explicit restart of the retired MCP service is outside the VoiceBar helper.
Restoration tests now assert the original disabled-autostart policy and the exact
observed bundle path. Shell fixtures model RunAtLoad starting at bootstrap, and
the fake build uses the real shared helper rather than inventing an unmanaged PID.
No deadlines are raised.

Round 2 formal refresh: 24/24 expected outcomes (6 positive / 18 exact-property
mutants). This branch does not contain A's reap model. Both branches retain their
own source-consistent receipts; lead regenerates after integration with P0.
Source/typecheck and Bash syntax checks pass. Installed/native/live and full
pre-push qualification remain NOT_RUN under the no-live-state brief.

Final R2 receipts: nine targeted files ran 251 cases: 249 pass / 2 fixture
failures (1058 assertions). The failures were both in update-gate-script-exits:
its fake build manufactured an unmanaged PID and its missing-job bootstrap
ignored RunAtLoad. After correcting those fixtures, the complete caller and
autostart suites pass 62/62 (226 assertions). All ten R2 cases that fail against
4bd0f7c0 pass in the broader run, matched by exact test name. The remaining
189 cases in that run passed; no product source changed after that run started.
The earlier 43 pass / 1 stale enable-count expectation failure is also retained;
the broader run passes that corrected recovery assertion. Neither failed run
is relabeled green. The latest caller recheck covers both failures and every
changed shell fixture. No full pre-push or unified nine-file rerun is claimed.
