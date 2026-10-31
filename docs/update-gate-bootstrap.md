# Supervised legacy bootstrap (G4b)

Update-button plan §3 / §5 slice 8. This opt-in exception establishes a controlled
interval for the first protected install over a legacy build with no gate. It
does not upgrade the safety of arbitrary old Homebrew commands.

From the **qualified 2.2.59-converse.1 candidate checkout on the M4**, with the
matching release offered by the approved tap, in a local terminal:

```bash
VOICELAYER_UPDATE_TARGET_SHA="$(git rev-parse HEAD)" bash scripts/voicelayer-update.sh --supervised-bootstrap --data-mode skip
```

The human must type `AT THIS MAC`, finish voice work, and refrain from new voice
work, logins or manual app launches until completion. Ctrl-C cancels before commit.
Health, queue depth, direct CLI processes, audio/decoder processes and the last
VoiceBar diagnostic must remain idle for two seconds. Legacy MCP only implements
ping on its public socket; absent health may use the explicitly confirmed clean
process/diagnostic fallback. Malformed health, unreadable processes or diagnostics
never become idle. A resident whisper-server is not evidence of an active request;
it must exit with the other owners after normal app quit. Idle observation is
bounded to 60 seconds and owner exit to five seconds; expiry refuses the update,
never stops voice work and never promotes UNKNOWN to idle.

Disable launchd restart first, recheck idle, request normal app quit, wait for every
old voice owner to exit, and only then unload the empty jobs. No stop/cancel/kill
is sent to voice work. Bridges are transport clients and need not exit. Recovery
audio is never modified. Existing/corrupt gates require recovery, never bootstrap. Precommit cancellation
or failure removes only this invocation's initial OPEN gate or its exact G2 CANCEL
result, under the lock with an empty ledger and no diagnostic/controller evidence.
Any mismatch stays intact for recovery. A new supervised invocation can then retry.

G2 exclusively initializes the missing gate under G1's lock; G4 owns drain/commit and the
existing brew reconciliation path. G4c's synced `.controller` receipt, exact lease
and live controller identity authorize nested validators. The operation records
supervised-bootstrap as its source. Every changed enablement and unloaded job is
restored independently before reporting all restoration failures. The observed
VoiceBar bundle is restored on every exit, including committed failures; the gate
stays closed after COMMIT. The replacement's autostart repair re-enables VoiceBar
only after argument checks and gate validation, never the retired MCP owner.

Bootstrap process/launchd evidence is sampled outside G1's lock, bracketing each
acquisition. Its locked proof is memory-only. Expected proof exceptions in installer,
native readiness and the compatibility helper return false; unexpected storage
persistence failures retain their existing fail-closed behavior. The installer
reads back durable COMMIT before returning to acquisition wrappers. Matching
COMMITTED state skips their post-sample; later validation failures retain closed
admission with recovery evidence. Legacy restoration requires persisted OPEN.
See [the callback audit](update-gate-callback-audit.md).

Bootstrap obtains the loaded VoiceBar job's `stderr path` (`StandardErrorPath`)
from `launchctl print`, and also checks the current default diagnostics file.
For each file it reads the last `[diag]` line; when both have diagnostics, the
more recently modified file wins. Missing files or missing `[diag]` lines never
prove idle. This supports an in-place legacy job still logging to
`/tmp/voicebar-err.log` while the current default is
`~/Library/Logs/voicelayer/voicebar-err.log`.

`VOICELAYER_BOOTSTRAP_DIAG_PATH` changes the fallback file for an unusual legacy
setup. For example, set `VOICELAYER_BOOTSTRAP_DIAG_PATH=/tmp/voicebar-err.log` on
the supervised command when that is the active log. If no candidate has a
`[diag]` line, the UNKNOWN status names the files read and prints this override
hint; it never promotes the observation timeout to idle.

Qualification remains pending: real M4 launchd/quit/socket behavior, signed target
identity and postcommit recovery/readiness; the SHA above is lease bookkeeping,
not artifact verification. Tap saved-recipe hooks and the golems consumer remain
separate. No app build, install, real brew/launchctl or real-client run was done here.
G4c's postcommit signal handling, lock retry and resolved-path restore trap are retained.

Surface sweep: update CLI and opt-in env checked; nested installer validates the
persisted source; legacy providers use conservative observations; gate schemas
unchanged; busy→idle, refusal, Cancel and failed commit-child states tested;
local socket only, remote durable job deferred; usage and limitations above.
