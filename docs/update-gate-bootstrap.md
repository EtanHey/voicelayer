# Supervised legacy bootstrap (G4b)

Update-button plan §3 / §5 slice 8. This opt-in exception establishes a controlled
interval for the first protected install over a legacy build with no gate. It
does not upgrade the safety of arbitrary old Homebrew commands.

From the **qualified 2.2.59-converse.1 candidate checkout on the M4**, with the
matching release offered by the approved tap, in a local terminal:

```bash
VOICELAYER_UPDATE_TARGET_SHA="$(DEVELOPER_DIR=/Library/Developer/CommandLineTools git rev-parse HEAD)" bash scripts/voicelayer-update.sh --supervised-bootstrap --data-mode skip
```

The human must type `AT THIS MAC`, finish voice work, and refrain from new voice
work, logins or manual app launches until completion. Ctrl-C cancels before commit.
Health, queue depth, direct CLI processes, audio/decoder processes and the last
VoiceBar diagnostic must remain idle for two seconds. Legacy MCP only implements
ping on its public socket; absent health may use the explicitly confirmed clean
process/diagnostic fallback. Malformed health, unreadable processes or diagnostics
never become idle. A resident whisper-server conservatively blocks, even if idle.

Disable launchd restart first, recheck idle, request normal app quit, wait for every
old voice owner to exit, and only then unload the empty jobs. No stop/cancel/kill
is sent to voice work. Bridges are transport clients and need not exit. Recovery
audio is never modified. Existing/corrupt gates require recovery, never bootstrap.

G2 exclusively initializes the missing gate under G1's lock; G4 owns drain/commit and the
existing brew reconciliation path. A synced `.bootstrap` receipt beside the gate
records the controller, lease and evidence source for nested validators. Cancel
restores changed launchd enablement and unloaded jobs. After commit the gate stays
closed; a failed install keeps autostart disabled for supervised recovery. The
replacement's autostart repair re-enables VoiceBar, never the retired MCP owner.

Qualification remains pending: real M4 launchd/quit/socket behavior, signed target
identity and postcommit recovery/readiness; the SHA above is lease bookkeeping,
not artifact verification. Tap saved-recipe hooks and the golems consumer remain
separate. No app build, install, real brew/launchctl or real-client run was done here.
G4's pending postcommit signal-liveness fix must land before the live install.

Surface sweep: update CLI and opt-in env checked; nested installer validates the
persisted source; legacy providers use conservative observations; gate schemas
unchanged; busy→idle, refusal, Cancel and failed commit-child states tested;
local socket only, remote durable job deferred; usage and limitations above.
