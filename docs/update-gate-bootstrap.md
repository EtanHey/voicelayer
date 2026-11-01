# Supervised legacy bootstrap (G4b)

Update-button plan §3 / §5 slice 8. This opt-in exception establishes a controlled
interval for the first protected install over a legacy build with no gate. It
does not upgrade the safety of arbitrary old Homebrew commands.

G4d separates cask postflight availability from gated updating. The explicit
`setup --cask-postflight` marker selects it; no-flag setup with an installed
canonical bundle retains compatibility with the current cask. An absent gate
uses the exclusive G2/G1 initializer under the shared mutex and remains OPEN;
an existing OPEN gate is unchanged. A closed gate with a live controller writes
canonical plists only. The updater carries its exact operation through brew's
filtered environment as `HOMEBREW_VOICELAYER_INSTALL_OPERATION`; setup validates
it before trusting it. The owning re-exec alone restores after all mutations.

Faults never initialize, reopen or reap gate evidence. They print
`RECOVERY_REQUIRED` and restore availability, returning zero after verifying
VoiceBar runs from the final canonical bundle so brew keeps it. Failed canonical
startup returns nonzero with plists retained. Nested manual setup never restores,
even after validation failure. SIGINT/SIGTERM/SIGHUP/SIGQUIT unwind only the
owned bootstrap mutex, with cleanup errors reported separately. Both installers
and setup enforce isolated HOME and launchctl paths before actions. See
[installer integration](update-gate-installers.md#cask-postflight-availability-g4d)
for the contract and isolated script-chain proof. Real installed qualification
and tap hook ordering remain separate.

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
and live controller identity authorize nested validators. The operation and synced
controller receipt record
supervised-bootstrap as their source; nested validation compares both fields
and refuses unknown or mismatched sources. Every changed enablement and unloaded
job is
restored independently before reporting all restoration failures. The observed
VoiceBar bundle is restored on every exit, including committed failures; the gate
stays closed after COMMIT. The replacement's autostart repair re-enables VoiceBar
only after argument checks and gate validation, never the retired MCP owner.

Bootstrap process/launchd evidence is sampled outside G1's lock, bracketing each
acquisition. Its locked proof is memory-only. Expected proof exceptions in installer,
native readiness and the compatibility helper return false; unexpected storage
persistence failures retain their existing fail-closed behavior. The installer
records durable COMMIT custody before returning to acquisition wrappers. Matching
COMMITTED state skips their post-sample; later validation failures retain closed
admission with recovery evidence. If this invocation initialized the gate, legacy
restoration requires persisted OPEN; otherwise it restores only the enablement
and jobs it changed, without a gate read.
See [the callback audit](update-gate-callback-audit.md).

Bootstrap requires the running VoiceBar PID to match the loaded legacy job's
`pid` from `launchctl print`. It reads that PID's process start time and requires
the newest diagnostic line's own NSLog timestamp to be at or after that start.
A missing loaded job, mismatched PID, missing/undated diagnostic or older line is
UNKNOWN, even with human confirmation. A fresh file mtime or unrelated log write
cannot make an old idle line current.

The loaded job's `stderr path` (`StandardErrorPath`) and current default file are
candidates; the diagnostic with the newest line timestamp wins. This supports an
in-place legacy job still logging to `/tmp/voicebar-err.log` while the default is
`~/Library/Logs/voicelayer/voicebar-err.log`. `VOICELAYER_BOOTSTRAP_DIAG_PATH`
changes the fallback for unusual setups; it never bypasses PID or timestamp
validation. UNKNOWN names the fallback and prints this override hint.

An adopted whisper-server (owned by another process) or a still-running retired
`com.voicelayer.mcp-daemon` job can remain after normal VoiceBar quit. Bootstrap
then refuses after the bounded owner-exit wait and restores the observed app.
Before retrying, finish voice work and use the actual owner's normal shutdown
path. For an adopted whisper-server, close it through the application or terminal
that owns it. A retired MCP job needs a separate supervised maintenance interval:
disable its restart, use that legacy daemon's normal shutdown path, verify its
process has exited, then unload the empty job and retain its plist for recovery.
Restore its prior state if the maintenance cannot finish. Never bootout a running
owner or force-stop one to make bootstrap pass. On an already protected install,
`bash launchd/install.sh` is the gated retirement helper; it cannot clear this
pre-gate legacy shape by itself. VoiceBar must remain the sole daemon owner.

A failed precommit bootout is restored by observing load state and using the
loaded job's original plist `path`, even if bootout unloaded it but returned an
error. After COMMIT, the finalizer does not reacquire G1 or restore legacy jobs.
Each persistence readback has its own bounded contention retry budget, separate
from the pre-COMMIT identity freshness deadline; it always attempts a read.

A SIGKILL can leave `<gate>.bootstrap-lock`. It is never automatically reaped.
For manual recovery, first establish that the original supervisor and all its
installer descendants have exited, inspect the preserved gate/controller and
recovery receipts, and restore the observed app and prior launchd state as
appropriate. Do not reopen a committed or uncertain gate on a guess. Only after
exclusive ownership and recovery are established may the operator remove that
specific empty supervisor directory with `rmdir` and retry. Never remove G1's
`.lock`, gate evidence or another live supervisor's mutex this way.

Qualification remains pending: real M4 launchd/quit/socket behavior, signed target
identity and postcommit recovery/readiness; the SHA above is lease bookkeeping,
not artifact verification. Tap saved-recipe hooks and the golems consumer remain
separate. No app build, install, real brew/launchctl or real-client run was done here.
G4c's postcommit signal handling, lock retry and resolved-path restore trap are retained.

Surface sweep: update CLI and opt-in env checked; nested installer validates the
persisted source; legacy providers use conservative observations; gate schemas
unchanged; busy→idle, refusal, Cancel and failed commit-child states tested;
local socket only, remote durable job deferred; usage and limitations above.
