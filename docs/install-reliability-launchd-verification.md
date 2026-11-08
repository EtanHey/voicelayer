# Resident launchd ownership: local verification

Base: `849483ae6f04f0edc8310fcab1793c6e7614c0d0` (`origin/integration/2.3`).
The shared starter enables the canonical job, bootstraps its installed plist if missing,
kickstarts `-k gui/$UID/com.voicelayer.voicebar`, and requires running state plus the
sole VoiceBar PID and expected executable. Every failure is loud; resident startup
has no LaunchServices fallback. Nonresident QA paths retain their existing launches.

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
