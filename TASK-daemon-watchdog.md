# TASK — VoiceBar daemon: app-child watchdog + single-owner (3-part fix)

**Branch:** `fix/daemon-app-child-watchdog` (worktree off origin/main). **Owner:** voiceAudioLead-gen15.
**Hard constraint (R-013, Etan's LIVE tool):** BUILD + DEV-VERIFY ONLY. Do **NOT** mutate Etan's live system —
do NOT `launchctl bootout`/`unload` his running daemon, do NOT delete/move any plist from `~/Library/LaunchAgents`,
do NOT swap the resident `/Applications/VoiceBar.app`. All launchd/daemon changes are **code + repo files only**,
gated behind the disable flag / dev paths. The live-apply happens later, after Etan's explicit OK.

## ROOT CAUSE (confirmed, see collab 2026-06-09 22:50 + BrainLayer brainbar-0b8ead45-524)
The notch rebuild re-signed the app (new cdhash → mic TCC invalidated) and #252 reintroduced a SECOND daemon owner
(launchd daemon + app-child daemon). Two live symptoms:
1. **"mic busy"** = recording returns `rms≈0 / dbfs≈-96` (pure silence → `broken-mic`). The app's respawn net is BLIND
   because `terminationHandler` only fires on process EXIT — an alive-but-deaf daemon never restarts.
2. **"disconnected"** = the external-daemon "stand-down" (added in e204159) false-positives on stale orphan sockets,
   kills the app's own child, treats exit-0 as deliberate stand-down → never restarts → MCP reconnect storm.

The daemon MUST stay an app-child (a launchd PPID=1 daemon is fed silence by macOS — cannot inherit mic TCC).
Supervision chain stays: `launchd → VoiceBar.app (already KeepAlive-on-crash) → child daemon`. Harden the inner link.

## THE 3-PART FIX

### (1) Mic-health watchdog → respawn on silence  [fixes "mic busy"]
`flow-bar/Sources/VoiceBar/VoiceBarDaemonController.swift` (+ recording path).
- The existing monitor (`terminationHandler`, ~lines 374–460, Ollama pattern) only catches process exit. Add a
  **mic-liveness signal**: when a recording completes with `rms≈0 / dbfs≈-96` (the `broken-mic` capture failure the
  daemon already surfaces), treat it as a DEAD daemon: tear down the child process and respawn it (so it re-inherits a
  fresh mic TCC from the app), using the SAME backoff/restartCount machinery.
- If respawn still yields silence (TCC genuinely revoked), surface a LOUD user-facing prompt to re-grant Microphone
  permission (System Settings) — NEVER silently drop the recording.
- Wire the `broken-mic` signal from the daemon/recording path to the controller (socket event or callback). Look at how
  `Surfacing capture failure: broken-mic` is emitted and route it to the controller's restart logic.

### (2) Single owner: remove the false stand-down + retire the competing LaunchAgent  [fixes "disconnected"]
- In `VoiceBarDaemonController.swift`: remove/neuter the `externalDaemonProbe` STAND-DOWN path (the lines that log
  `External daemon is live — stopping owned fallback child` / `Owned daemon stood down for external daemon` and treat that
  exit as terminal). The app is the SOLE owner; it must not abdicate to a probe that false-positives on orphan sockets.
  Keep orphan-socket CLEANUP (removing a stale `/tmp/voicelayer-mcp.sock`), just don't let a stale socket suppress respawn.
- In `launchd/install.sh` (+ `flow-bar/build-app.sh` if it calls the installer): make the installer **REMOVE** the
  `com.voicelayer.mcp-daemon` daemon LaunchAgent as the canonical state (bootout + delete the plist) instead of
  installing/keeping it — single-owner model. **Repo + installer code only.** Do NOT run the installer against Etan's
  live `~/Library/LaunchAgents` here. If the repo still ships `launchd/com.voicelayer.mcp-daemon.plist`, delete it from
  the repo (the app owns the daemon now) and update any docs/tests that reference it.
- Update `CLAUDE.details.md` daemon section + `README.md` to reflect single-owner (app-child) — the daemon LaunchAgent
  is retired; launchd supervises the APP, the app supervises the daemon.

### (3) Exit-0 terminal ONLY when explicitly disabled  [no silent death]
- In the `terminationHandler` / `scheduleRestart` logic: an exit code 0 may be treated as a terminal "stand-down" ONLY
  when the explicit disable flag is set (`/tmp/.voicelayer-daemon-disabled` — confirm the exact constant). For every other
  unexpected death (including exit-0 with NO disable flag), ALWAYS reschedule a restart. Remove the path where a plain
  exit-0 permanently stops the daemon.

## TESTS / DEV-VERIFY (required before reporting done)
- Update/extend `flow-bar/Tests/VoiceBarTests/VoiceBarDaemonControllerTests.swift`:
  - broken-mic/silence signal → triggers respawn (new).
  - external-daemon stand-down no longer kills+abandons the child (assert respawn still scheduled).
  - exit-0 WITHOUT disable flag → reschedules; exit-0 WITH disable flag → terminal.
- `swift build` (or the project's build) green; `swift test` for the VoiceBar tests green.
- `bun test` green for any TS touched (daemon-startup, launchd-install tests — update expectations for the retired plist).
- `bun run typecheck` clean if TS changed.
- shellcheck `launchd/install.sh` clean if changed.
- DO NOT run `flow-bar/build-app.sh` against the live install, DO NOT touch `~/Library/LaunchAgents`, DO NOT bootout the
  live daemon. Dev verification only.

## REPORT BACK
Commit on `fix/daemon-app-child-watchdog`, push, open a PR titled `fix: app-child daemon watchdog + single owner`.
PR body: the 3 parts, test output, and an explicit "NOT applied to live system — awaiting Etan apply-OK (R-013)" note.
This touches daemon/socket/launchd → the daemon runtime-verify gate applies; the LIVE F5→speak→paste verify is Etan's
to run at apply time, NOT here. Report the PR # + build/test evidence back to voiceAudioLead-gen15.
