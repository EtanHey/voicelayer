# G0 first-install and mixed-version recovery

The canonical bundle placed by Homebrew selects setup's availability path, even
when an old cask invokes plain `setup`. Explicit `--cask-postflight` selects the
same path. Neither requests a lease or requires VOICELAYER_UPDATE_TARGET_SHA.
With no gate or sidecars and no observed live voice participants, setup calls
`initializeSupervisedVoiceGate` under the bootstrap mutex. That uses G2's startup
initializer and G1's exclusive hard-link publication, yielding OPEN generation 0.
It never hand-writes or repairs a gate. Locks, diagnostic markers, registrations,
controllers, malformed state and live legacy owners refuse bootstrap. G4d still
restores canonical availability and loudly reports RECOVERY_REQUIRED; that does
not grant update authorization or clear refusal evidence.

Promotion renders an unsandboxed legacy `postflight do` with
`system_command ... must_succeed: false`, plus one explicit repair message. It
accepts either flight-block syntax as input, so promotion retries are idempotent.
A formula rejecting the option or setup failing to start VoiceBar must not make
Homebrew roll back and delete the newly installed bundle. The repair message
names both recipes and `voicelayer setup --cask-postflight` outside brew.

### G1: old updater, new formula scripts

2.2.58 upgrades the formula first, then runs the NEW Cellar dedupe script with
`--apply --no-relaunch`, followed by the NEW autostart script with `--reload`.
It supplies neither a target SHA nor a lease. Those exact modes, from a physical
`/opt/homebrew/Cellar/voicelayer/<version>/libexec/lib/node_modules/voicelayer-mcp`
(or `/usr/local/Cellar/...`) root, use setup's availability path instead.
Destructive dedupe and reload are deferred with a visible message. Existing
canonical startup is idempotent: no stop, bundle moves or loaded-job reload.

This chooses availability-only compatibility rather than deriving a target SHA:
a bundle GitCommit is not target verification, and an old updater cannot finalize
a newly committed lease before its later autostart call. No lease is acquired or
committed, and no gate evidence is cleared or reopened. Setup retains its absent
bootstrap and live-controller fences. A supplied operation (including invalid
ones), Homebrew operation or target disables the exception. A lease-holding
updater still validates its exact operation before destructive repair; cask
postflight remains plist-only until the owning finalizer restores availability.
Checkout/global-package repair and other modes retain the normal gate.
This compatibility does not make the old updater's preceding brew mutation
idle-gated; it only restores the canonical bundle that brew already installed.

## M1 restore recipe after G0 is released

For the reported state (no app, OPEN generation 0, formula 2.2.59 from outside
the tap, tap cask 2.2.58), update the formula FIRST and install the cask SECOND.
A read-only inventory during G0 instead found a linked 2.2.58 formula; the same
recipe handles both. Run this in the M1 user's terminal after the captain has
promoted matching 2.2.61 npm/formula/cask artifacts through the release script:

```bash
set -euo pipefail
BREW=/opt/homebrew/bin/brew
"$BREW" update

# Refuse the old tap. Do not attempt cask installation until both recipes match.
"$BREW" info --formula --json=v2 etanhey/layers/voicelayer > /tmp/g0-formula-info.json
"$BREW" info --cask --json=v2 etanhey/layers/voicebar > /tmp/g0-cask-info.json
/opt/homebrew/bin/bun -e '
const f = await Bun.file("/tmp/g0-formula-info.json").json();
const c = await Bun.file("/tmp/g0-cask-info.json").json();
if (f.formulae[0]?.versions.stable !== "2.2.61" || c.casks[0]?.version !== "2.2.61")
  throw Error("STOP: both tap recipes must be 2.2.61 before restoring VoiceBar");
'

# Fully qualified reinstall replaces the old formula bytes without hand-editing
# the tap or relying on the outside-tap formula originally used for 2.2.59.
"$BREW" reinstall --formula etanhey/layers/voicelayer
/opt/homebrew/bin/voicelayer --version
# A failed previous install normally left no cask registration. Cover either ledger state.
if "$BREW" list --cask --versions voicebar 2>/dev/null | /usr/bin/grep -q '^voicebar '; then
  "$BREW" reinstall --cask etanhey/layers/voicebar
else
  "$BREW" install --cask etanhey/layers/voicebar
fi
/opt/homebrew/bin/voicelayer setup --cask-postflight
"$BREW" list --versions voicelayer
"$BREW" list --cask --versions voicebar
/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' /Applications/VoiceBar.app/Contents/Info.plist
```

Keep the existing OPEN gate and admissions directory unchanged. Do not export a
fake target SHA, remove gate evidence, copy a bundle by hand, or use an old cask
before updating the formula. Formula reinstall and cask install are separate
commands so an old postflight cannot run against old formula bytes. If brew
refuses to resolve the formula's origin or linking, stop with that exact error;
do not uninstall data or force-link over another package. The captain must still
verify installed bundle provenance, daemon/bridge recovery and real Option+F5 on
the M1; this recipe and isolated tests do not supply installed acceptance.

## Homebrew execution evidence and follow-up ledger

Read the installed Homebrew 7.0.12 source on the M4 (no brew execution):
`cask/artifact/install_steps.rb:40` calls `cask_sandbox` for declarative steps;
`cask/artifact/abstract_flight_block.rb:39` calls `abstract_phase` directly,
which evaluates the legacy DSL without that sandbox. `cask/dsl/base.rb:28`
forwards `system_command` options to `SystemCommand.run!`.
`system_command.rb:175` forwards the explicit `must_succeed: false` to `run`,
and `:289` calls `assert_success!` only when that flag is true. Thus a nonzero
setup command status returns a result rather than raising into cask rollback.
The rendered repair echo is also non-raising. The isolated Ruby guard exercises
bundle retention and proves its raising mutant deletes the fixture bundle.

The real R2 failure showed the steps sandbox denying quarantine removal,
launchd bootstrap and LaunchServices open. Writable paths cannot grant those
capabilities. Legacy postflight accepts a deprecation warning to restore startup.

Ledger G1-HOMEBREW: revisit before Homebrew removes legacy `postflight`; qualify
an unsandboxed supported startup mechanism before migrating to `postflight_steps`.
Never substitute a sandboxed setup attempt for installed startup proof.

Installed qualification remains the captain's R2 rows (b), (b2), (c) and (a),
after rebuilding this lane's integrated head. These isolated guards and TLC
checks do not prove the installed bundle, sockets, launchd or real-agent health.
