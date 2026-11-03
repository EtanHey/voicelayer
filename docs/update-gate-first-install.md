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

Promotion rewrites the old cask block to supported `postflight_steps`, with a
literal `run` passing `--cask-postflight` and `must_succeed: false`, and an
explicit visible repair message. It accepts either the old or new block as its
input, so promotion retries remain idempotent. This lets a new cask paired with a
2.2.59 formula report its unsupported option without Homebrew deleting the app.
The output names both recipes and the repair command. Updating both recipes first
avoids depending on that fallback. No new cask is published by this lane.

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

## Homebrew DSL migration evidence

Checked the current [Cask Cookbook](https://docs.brew.sh/Cask-Cookbook#stanza-flight_steps)
and installed Homebrew `install_steps.rb` DSL. Supported steps contain literal
`run` calls, not arbitrary Ruby result handling; install-time paths use
`{{HOMEBREW_PREFIX}}`. `must_succeed: false` retains the bundle on command
failure. Setup's writable state/plist/log roots are explicitly declared.

The [artifact sandbox contract](https://docs.brew.sh/Cask-Cookbook#cask-artifact-trust-and-sandboxing)
prohibits LaunchServices and outbound Unix sockets. Declaring writable paths
does not grant those capabilities. The cask therefore prints the terminal repair
command after its attempt; the restore recipe above runs it outside brew. A
sandboxed hook cannot establish real startup availability by itself. Automatic
startup from this new Homebrew sandbox is not claimed as qualified.
