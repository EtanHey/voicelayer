# Installer integration (G4, update-button §3 / §5 slice 8, script half)

Consumes G1 storage/schema and G2 REQUEST → acknowledge → PREPARE → COMMIT,
without adding transitions. Only APPLIED COMMIT starts mutation. A second request
cannot repeat installation. Nested helpers validate the same committed lease and
live controller. Busy waits with the participant phase and Ctrl-C; precommit exit
CANCELs its own generation. No stop/cancel signals are used to drain. After commit,
admission remains closed for qualified completion/recovery; failure never reopens it.

**NOT_GREEN for installed use:** G2 supplies a synchronous proof callback contract,
not live native/daemon identity, target verification, handoff, competing-owner or
archive-durability probes. Production therefore refuses UNKNOWN, including bootstrap.
The synthetic proof provider is harness-only: isolated preload flag, a real run root
inside this checkout's `.test-tmp`, and a nonsymlink proof inside that run. It is not
installed-runtime evidence. The target SHA environment value alone proves nothing.
Never enable the updater button or ship these guards as a working installer until
the live provider, bootstrap and postcommit recovery are qualified.

Recon inventory (scoped scripts, launchd, flow-bar/build-app.sh and src/cli):

| Entry/path | Guard before mutation |
| --- | --- |
| `voicelayer update` → `scripts/voicelayer-update.sh` | Before package git/bun/npm/formula mutation, cask sync, setup/hotkey repair and restart; both lifecycle opt-outs still gated |
| `scripts/lib/brew-cask-sync.sh` | Direct sync/reregister/tap/brew mutation requires an inherited operation; read-only queries and command simulation unchanged |
| `voicelayer build-app` → `flow-bar/build-app.sh` | Before stop, compiler or bundle replacement; validation precedes admission |
| `scripts/release-voicebar.sh` | Before artifact cleanup/build; original argv retained for gated re-exec |
| `scripts/promote-voicebar-release.sh` | No local install helper; gate before recipe changes/publication; existing T3 release proof remains mandatory |
| `voicelayer setup` / direct `src/cli/setup.ts` | Before setup command plan/restarts; child env explicit |
| `launchd/install.sh` | Before retired agent unload/removal; backup-plist mode does not touch VoiceBar |
| `scripts/install-voicebar-autostart.sh` | Before plist writes, bootout/bootstrap/kickstart, including reload/no-start/preserve-load-state |
| `scripts/install-voicebar-f5-hidutil.sh` | Ungated standalone Settings relay configuration: only its hidutil helper/plist/LaunchAgent, never VoiceBar/daemon restart or replacement; legacy Karabiner installer delegates here |
| `voicelayer doctor` → dedupe `--apply` | Before quit, pkill, unload, bundle moves and autostart repair; inventory stays read-only |
| `scripts/voicelayer-verify.sh` | Before build/relaunch section, including skip-build; not executed in this lane |
| `scripts/auto-f5-verify.sh` restoration | Requires an inherited operation before invoking an older main checkout's build; not executed in this lane |
| UI e2e build/release staging helpers | Delegate to guarded build; isolated test process cleanup is not a resident installer |
| `bar-stop`, recording Stop/Cancel; runtime hidutil mapping | User/runtime controls, not installation; remain usable |

Follow-up rows: tap cask preflight/uninstall hook and old saved recipe ordering
(separate tap qualification); golems deploy-local-prod cross-repo integration;
live native/daemon/target proof provider; controller incarnation/reconnect hardening
and durable host job (slice 7); bootstrap/verified postcommit completion/recovery;
Swift/Bun and installed real-agent proof, full suite/build after M1 window closes.

Surface sweep: entry points/clients are listed above; providers use G2 callbacks
with synthetic fixtures only; G1/G2 wire contracts unchanged; reverse states tested
are busy→idle, precommit Cancel, duplicate update and UNKNOWN; connections are local
persisted gate/ledger with inherited controller lease (SSH/job recovery deferred).

Fix round 1: Cancel retries only lock contention (8 attempts; 25–250 ms exponential
backoff), then emits RECOVERY_REQUIRED and a private fsynced recovery receipt beside
the unchanged durable lease. Signal handlers are removed even when cleanup fails.
After COMMIT, SIGINT/SIGTERM write a receipt with installer PID and exit 130/143;
they never CANCEL the lease or signal the installer. Its outcome requires recovery.
Help/invalid arguments precede admission; simulation takes no lease. A no-command
shell helper validates an inherited operation or returns refusal without exec.
G4 uses G2 9196eff4's single admission-aware command path; voice-only missing-gate
bootstrap and ledger visibility semantics remain G2-owned.

Settings calls the F5 installer via `/bin/bash` from bundle resources (Swift
`runRelaySetup`). It must work without daemon sources or Bun on GUI PATH. The
relay-only installer is excluded from update admission; an update still owns its
gate across the whole job, including when it invokes this independent helper.
