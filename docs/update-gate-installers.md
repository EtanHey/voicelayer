# Installer integration (G4, update-button §3 / §5 slice 8, script half)

Consumes the merged G1/G2 voice-side API on main: REQUEST → acknowledge → PREPARE → COMMIT,
without adding transitions. Only APPLIED COMMIT starts mutation. A second request
cannot repeat installation. Nested helpers validate the same committed lease and
live controller. Busy waits with the participant phase and Ctrl-C; precommit exit
CANCELs its own generation. No stop/cancel signals are used to drain. After commit,
admission remains closed for qualified completion/recovery; failure never reopens it.

The production participant provider now calls G3's authenticated
`voicelayer/speech` control endpoint with `update_gate_drain` and the exact lease.
It validates native and daemon zero-work/zero-archive ACKs plus their
PID/incarnation identities. Each new refresh invalidates the previous receipt;
PREPARE, COMMIT and the postcommit quit each require a fresh round trip. The
synchronous G2 verifier fences the same lease and receipt age under G1's lock.
Process births, executable names and the daemon's native parent are sampled just
before and after each locked proof; no process-table reads run inside the lock.
A receipt may be at most one second old, including time in flight and sampling.
Missing/UNKNOWN participants wait with Cancel; malformed/mismatched replies,
identity changes and transport faults refuse. A timeout never proves idle.

After APPLIED COMMIT, the controller waits a 100 ms fault-publication grace period,
refreshes G3 evidence (up to four drain attempts on UNKNOWN) and issues exactly
one authenticated `update_gate_quit`. Quit authorization retries only mkdir-lock
contention with the same eight-attempt backoff as the precommit controller; the
quit RPC itself is never retried. Exit verification retries lock contention
within its existing five-second deadline.
An ACK still requires observed exit. If a written quit loses its reply through
socket disconnect or timeout (or G3 reports UNKNOWN after its native connection
drops), the controller verifies the outcome rather than reporting a plain
install failure: both pinned processes must be absent, no
VoiceBar executable may remain in the process table, and G2 must still observe
the exact COMMITTED lease with no diagnostic or admission records. It observes
exit for at most five seconds; the deadline only refuses, never proves exit.
A same-start-time `<defunct>` participant is still exiting and is polled until
reaped within that deadline. An unreadable process table, reused PID, explicit
refusal, malformed reply, changed lease, retained process, diagnostic or ledger
entry stops UNKNOWN,
writes the recovery receipt and keeps admission closed. Nothing force-stops a
participant or reopens the gate. Nested helpers validate the retained COMMITTED
lease and the controller's PID, start time and executable name recorded in the
operation environment after participant exit, without requesting new ACKs.
Both identity samples bracketing lease validation must match that record.

**NOT_GREEN for installed use:** This wires the G3 participant contract; staged
target verification, bootstrap, durable owner/reconnect hardening and qualified
completion/recovery are still separate work. The target SHA environment value
alone proves nothing. Do not enable the updater button or claim installed-app
qualification from isolated tests.
The synthetic proof provider still requires the isolated preload flag, a
nonsymlink run root in this checkout's `.test-tmp`, a private random-token marker
naming the live preload PID, and a nonsymlink proof inside that run. Flags alone
do not qualify it. Invalid harness evidence never falls through to live sockets.
Programmatic participant injection for controller tests requires that same proof
and live capability; it is unavailable in production. A malicious same-user
process can forge test files, so this is not an authentication boundary or
installed-runtime evidence. On the production reply channel, the daemon builds
the native receipt from the HMAC-verified native ACK; the installer trusts the daemon
for that verification. A same-user socket owner can forge replies. Outside
isolation the controller refuses a noncanonical gate path, including state and HOME overrides; the canonical root
is the OS account home, not caller HOME. The installer also refuses a
noncanonical MCP socket path, including socket and temp-root overrides.

Recon inventory (scoped scripts, launchd, flow-bar/build-app.sh and src/cli):

| Entry/path | Guard before mutation |
| --- | --- |
| `voicelayer update` → `scripts/voicelayer-update.sh` | Before package git/bun/npm/formula mutation, cask sync, setup/hotkey repair and restart; both lifecycle opt-outs still gated |
| `scripts/lib/brew-cask-sync.sh` | Direct sync/reregister/tap/brew mutation requires an inherited operation; read-only queries and command simulation unchanged |
| `voicelayer build-app` → `flow-bar/build-app.sh` | Before stop, relaunch, any `/Applications` bundle write or resident launchd install; nonresident `.noindex` builds with both lifecycle opt-outs take no lease |
| `scripts/release-voicebar.sh` | Ungated artifact cleanup/build: changes only release output, with staging disabling resident lifecycle |
| `scripts/promote-voicebar-release.sh` | Ungated publication/tap writes, no local install; existing T3 release proof remains mandatory |
| `voicelayer setup` / direct `src/cli/setup.ts` | Before setup command plan/restarts; child env explicit |
| `launchd/install.sh` | Before retired agent unload/removal; backup-plist mode does not touch VoiceBar |
| `scripts/install-voicebar-autostart.sh` | Before plist writes, bootout/bootstrap/kickstart, including reload/no-start/preserve-load-state |
| `scripts/install-voicebar-f5-hidutil.sh` | Ungated standalone Settings relay configuration: only its hidutil helper/plist/LaunchAgent, never VoiceBar/daemon restart or replacement; legacy Karabiner installer delegates here |
| `voicelayer doctor` → dedupe `--apply` | Before quit, pkill, unload, bundle moves and autostart repair; inventory stays read-only |
| `scripts/voicelayer-verify.sh` | Confirmation precedes admission, including skip-build; inherited re-exec skips the already-approved prompt. Unusable for acceptance until verified completion reopens voice |
| `scripts/auto-f5-verify.sh` restoration | Requires an inherited operation before invoking an older main checkout's build. Restore remains unusable until the owning completion/recovery flow exists |
| UI e2e build/release staging helpers | Delegate to guarded build; isolated test process cleanup is not a resident installer |
| `bar-stop`, recording Stop/Cancel; runtime hidutil mapping | User/runtime controls, not installation; remain usable |

Follow-up rows: tap cask preflight/uninstall hook and old saved recipe ordering
(separate tap qualification); golems deploy-local-prod cross-repo integration;
staged-target proof; controller incarnation/reconnect hardening
and durable host job (slice 7); bootstrap/verified postcommit completion/recovery;
Swift/Bun and installed real-agent proof. SIGKILL/crash before commit leaves a closed
lease: proven owner-death recovery is a provider-slice blocker, never an age-based
reopen. The wired G3 live endpoint and postcommit exit check require installed
real-agent qualification. No updater button may ship enabled on this evidence.

Surface sweep: entry points/clients are listed above; providers use fresh
authenticated G3 round trips plus G2 callbacks (with qualified synthetic fixtures
in tests); G1/G2 wire contracts unchanged; reverse states tested
are busy→idle, precommit Cancel, duplicate update, stale/mismatched evidence,
controlled-quit reply loss, verified exit and UNKNOWN recovery; connections are local
persisted gate/ledger with inherited controller lease (SSH/job recovery deferred).

Final review: all updater transitions use `updateVoiceGate`; acknowledgements use
`acknowledgeVoiceDrain`, with no G4 commit implementation. Both structured
REFUSED/UNKNOWN (ack: null) plus observed lock presence, and legacy
UPDATE_GATE_LOCKED throws, receive 8 bounded attempts with 25–250 ms backoff.
REQUEST/PREPARE/COMMIT and initial/nested observations follow the same rule.
Polling can wait again while a lock remains; UNKNOWN without contention refuses.
Cancel exhaustion emits RECOVERY_REQUIRED and a private fsynced recovery receipt
beside the retained lease. No foreign lock or ledger entry is removed.
Proof callbacks return false on exceptions before G2's safeGateLock handles them;
a transient proof read cannot poison the gate or orphan its lock.
SIGINT/SIGTERM/SIGHUP/SIGQUIT before COMMIT Cancel the owned lease. After COMMIT,
the controller stays alive until its installer completes and reports the child's
exit status. The installer has a separate session/process group; terminal Ctrl-C
does not reach brew/ditto or invalidate nested owner-PID checks. The visible message
is “Ctrl-C will not stop the installer”. No postcommit signal cancels the lease.
Admission remains closed after success or failure pending verified completion.
Help/invalid arguments and simulations take no lease. A no-command helper validates
an inherited operation in a subprocess or returns refusal without exec.
The shell guard resolves Bun via `/opt/homebrew/bin/bun`, `~/.bun/bin/bun`, then
PATH; missing Bun refuses clearly before mutation. Preload fixtures may substitute
candidate paths so tests never execute a host installer binary. Cask helpers use
the refreshed PACKAGE_ROOT after formula upgrade, since the old keg can disappear.

Settings calls the F5 installer via `/bin/bash` from bundle resources (Swift
`runRelaySetup`). It must work without daemon sources or Bun on GUI PATH. The
relay-only installer is excluded from update admission; an update still owns its
gate across the whole job, including when it invokes this independent helper.
