# M1 Pro Homebrew VoiceBar Runbook

Use this when bringing the M1 Pro onto the same VoiceLayer/VoiceBar line and
personal voice settings as this Mac.

This runbook is for the Homebrew path. Do not use the older bundle-transfer
runbook unless the goal is explicitly to copy a prepared transfer bundle.

## Current Release Targets

- Homebrew tap: `etanhey/layers`
- VoiceBar cask: `2.2.7`
- VoiceLayer formula: `2.2.7`
- VoiceLayer npm package: `voicelayer-mcp@2.2.7`
- npm tarball SHA256: take it from the **published** tarball, never a local `npm pack` —
  `npm publish` re-packs and gzip embeds a timestamp, so local bytes differ:
  `curl -sL https://registry.npmjs.org/voicelayer-mcp/-/voicelayer-mcp-<v>.tgz | shasum -a 256`

## Safety Rules

- Do not print `~/.voicelayer/daemon.secret`.
- Do not run `tccutil reset` as a first step.
- Keep standalone `voicelayer serve` brew services disabled; VoiceBar owns the
  microphone-permissioned daemon child.
- Do not treat a green brew install as runtime green. Runtime green requires a
  real F5 -> speak -> paste check on the M1.
- **`brew` is NOT on the M1's non-interactive ssh PATH.** `ssh m1 'brew ...'` returns nothing and
  reads as "not installed". Always use the absolute path `/opt/homebrew/bin/brew` over ssh. This
  trap produced two false "M1 is not brew-managed" reports on 2026-08-19.
- **Never hand-place a bundle** (rsync/unzip) into `/Applications` on a brew-managed box. That makes
  brew's registration and the filesystem disagree, which is what turned a routine cask upgrade
  destructive on 2026-08-19 and left the M1 with no VoiceBar at all.

## 1. Wake And Identify The M1

Run this on the M1 locally if SSH is not reachable yet:

```bash
hostname
whoami
sw_vers
uname -m
tailscale status
tailscale ip -4
```

Expected:

- user is the intended M1 account (currently `happycampr`; verify with `whoami`)
- `uname -m` is `arm64`
- Tailscale is connected

If inbound SSH should be available, enable Remote Login in:

```text
System Settings -> General -> Sharing -> Remote Login
```

## 2. Read-Only Remote Inventory

From this Mac, once the M1 is reachable:

```bash
ssh -o BatchMode=yes -o ConnectTimeout=8 <m1-user>@<m1-tailscale-name-or-ip> '
set -u
printf "== identity ==\n"
hostname
whoami
sw_vers
uname -m
printf "uid=%s home=%s\n" "$(id -u)" "$HOME"

printf "== brew ==\n"
BREW=/opt/homebrew/bin/brew
$BREW tap
HOMEBREW_NO_AUTO_UPDATE=1 $BREW list --versions voicelayer cmuxlayer brainlayer 2>/dev/null || true
HOMEBREW_NO_AUTO_UPDATE=1 $BREW list --cask --versions voicebar brainbar 2>/dev/null || true
HOMEBREW_NO_AUTO_UPDATE=1 $BREW info etanhey/layers/voicelayer || true
HOMEBREW_NO_AUTO_UPDATE=1 $BREW info --cask etanhey/layers/voicebar || true
printf "== drift ==\n"
/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" /Applications/VoiceBar.app/Contents/Info.plist 2>/dev/null || echo "no resident app"

printf "== launchd ==\n"
launchctl print "gui/$(id -u)/com.voicelayer.voicebar" 2>&1 || true
launchctl print "gui/$(id -u)/com.voicelayer.f5-to-f18-hidutil" 2>&1 || true

printf "== sockets/processes ==\n"
test -S /tmp/voicelayer-mcp.sock && echo "OK /tmp/voicelayer-mcp.sock" || echo "MISSING /tmp/voicelayer-mcp.sock"
test -S /tmp/voicelayer.sock && echo "OK /tmp/voicelayer.sock" || echo "MISSING /tmp/voicelayer.sock"
pgrep -fl "VoiceBar|voicelayer|tts_daemon|mcp-server-daemon|whisper" || true

printf "== personal data shape ==\n"
ls -la "$HOME/.voicelayer" "$HOME/.voicelayer/voices" "$HOME/.local/state/voicelayer" 2>&1 || true
test -x "$HOME/.voicelayer/venv/bin/python" && "$HOME/.voicelayer/venv/bin/python" - <<PY || true
try:
    import mlx_audio
    print("OK mlx_audio import from ~/.voicelayer/venv")
except Exception as exc:
    print(f"MISSING mlx_audio: {exc}")
PY

printf "== MCP configs ==\n"
for cfg in "$HOME/.claude/.mcp.json" "$HOME/.cursor/mcp.json" "$HOME/.codex/config.toml"; do
  if [ -f "$cfg" ]; then
    echo "--- $cfg"
    grep -E "voicelayer|socat|voicelayer-mcp.sock|UNIX-CONNECT" "$cfg" || true
  else
    echo "MISSING $cfg"
  fi
done
'
```

## 3. Install Or Upgrade With Homebrew

**One command, from any starting state:**

```bash
voicelayer update
```

That is the whole procedure. It is idempotent — running it twice is a no-op — and it is correct
whether the Mac has a clean registration, a stale one, an unmanaged hand-placed bundle, or nothing
at all. It refreshes the tap explicitly, detects drift, repairs it without sudo, and ends by
printing a green summary (or failing loudly).

If `voicelayer` is not installed yet, bootstrap it once:

```bash
# Over ssh use the absolute path; bare `brew` is not on the non-interactive PATH.
BREW=/opt/homebrew/bin/brew
$BREW tap etanhey/layers
$BREW install --cask etanhey/layers/voicebar
voicelayer update
```

### What `voicelayer update` does about drift

Drift means **brew's ledger and the disk disagree** about which VoiceBar is installed. It happens
whenever something writes `/Applications/VoiceBar.app` without telling brew — a local
`build-app.sh`, an rsync'd bundle, an unzipped release.

`scripts/lib/brew-cask-sync.sh` handles it:

1. Refresh the tap explicitly — `git -C <tap> pull --ff-only origin main`. `brew update` did **not**
   refresh `etanhey/layers` on 2026-08-19; it sat 3 commits behind, still serving the destructive
   definition.
2. Compare the tapped `version`, `brew list --versions --cask voicebar`, and the real
   `CFBundleShortVersionString` in `/Applications/VoiceBar.app`.
3. On drift, **do not upgrade.** Move the stale (user-owned) `Caskroom/voicebar` aside into
   `~/Library/Application Support/VoiceBar/Backups/`, then `brew install --cask --force` to adopt
   the app in place. Nothing is deleted and no uninstall recipe runs.
4. Never shell out to root. If clearing the registration would need sudo, it stops and says so
   **before** changing anything.

Recover by hand only if the script itself is unavailable — this is the same sequence, and it is what
actually worked on 2026-08-19:

```bash
mv /opt/homebrew/Caskroom/voicebar ~/voicebar-caskroom-backup
/opt/homebrew/bin/brew install --cask --force etanhey/layers/voicebar
```

`--force` is what lets brew adopt an app that is already on disk; without it you get
`It seems there is already an App at '/Applications/VoiceBar.app'`.

### Do not create drift in the first place

`flow-bar/build-app.sh` now **refuses** to write `/Applications/VoiceBar.app` on a Mac where the
`voicebar` cask is registered. Build somewhere else instead:

```bash
bash flow-bar/build-app.sh --install-path "$HOME/Applications/VoiceBar-dev.app"
```

Deliberately swapping the resident app to test a branch build (the lifecycle in `AGENTS.md`) is
still possible with `VOICEBAR_ALLOW_BREW_MANAGED_INSTALL=1`; it warns that brew's ledger is now
stale and tells you to run `voicelayer update` to put the Mac back.

Verify the tap line before proceeding:

```bash
/opt/homebrew/bin/brew info etanhey/layers/voicelayer | sed -n '1,20p'
/opt/homebrew/bin/brew info --cask etanhey/layers/voicebar | sed -n '1,30p'
```

Expected:

- `voicelayer` reports `2.2.7`
- `voicebar` reports `2.2.7`
- the formula has `bun`, `node`, `socat`, and `sox`
- there is no `service do` block for VoiceLayer

## 4. Sync This Mac's VoiceLayer Settings

Preferred one-command path from the M1, pulling from this Mac:

```bash
voicelayer update --data-mode direct --data-source etanheyman@<this-mac-tailscale-name-or-ip>:/Users/etanheyman
```

That syncs:

- `~/.voicelayer/voices/`
- `~/.voicelayer/voices.json`
- `~/.voicelayer/pronunciation.yaml`
- `~/.voicelayer/daemon.secret`
- `~/.local/state/voicelayer/stt-vocabulary.json`

It also creates or updates `~/.voicelayer/venv`, installs the pinned
`mlx-audio>=0.4,<0.5` line, downloads the Qwen3 model if missing, rebuilds the
VoiceBar app from the installed package, and restarts the VoiceBar stack.

If direct mode cannot reach this Mac, use explicit `rsync` from the M1:

```bash
SRC='etanheyman@<this-mac-tailscale-name-or-ip>:/Users/etanheyman'
mkdir -p "$HOME/.voicelayer" "$HOME/.local/state/voicelayer"
rsync -a --delete "$SRC/.voicelayer/voices/" "$HOME/.voicelayer/voices/"
rsync -a "$SRC/.voicelayer/voices.json" "$HOME/.voicelayer/voices.json"
rsync -a "$SRC/.voicelayer/pronunciation.yaml" "$HOME/.voicelayer/pronunciation.yaml"
rsync -a "$SRC/.voicelayer/daemon.secret" "$HOME/.voicelayer/daemon.secret"
rsync -a "$SRC/.local/state/voicelayer/stt-vocabulary.json" "$HOME/.local/state/voicelayer/stt-vocabulary.json"
chmod 700 "$HOME/.voicelayer"
chmod 600 "$HOME/.voicelayer/daemon.secret"
voicelayer update
```

Do not sync `stop-*`, `cancel-*`, pid files, logs, sessions, or old recovery
backups as part of the runtime settings transfer.

## 5. Human-Only macOS Permission Gates

On the M1 GUI, grant:

```text
System Settings -> Privacy & Security -> Microphone -> VoiceBar ON
System Settings -> Privacy & Security -> Accessibility -> VoiceBar ON
System Settings -> Privacy & Security -> Input Monitoring -> VoiceBar ON
```

If macOS prompts on first launch, allow VoiceBar.

## 6. Runtime Verification

Run on the M1 after install/update:

```bash
voicelayer autostart status
voicelayer hotkey status
test -S /tmp/voicelayer-mcp.sock && echo "OK MCP socket"
pgrep -fl "VoiceBar|mcp-server-daemon|tts_daemon|whisper" || true
"$HOME/.voicelayer/venv/bin/python" - <<'PY'
import mlx_audio
print("OK mlx_audio")
PY
```

Then verify the real user path:

1. `voice_speak("M1 VoiceLayer verify")` produces audible speech on the M1.
2. F5 -> speak -> paste works into a focused text field.
3. A cloned voice such as `theo-n4a` renders from the synced voice profiles.
4. Agent MCP config connects through `socat STDIO UNIX-CONNECT:/tmp/voicelayer-mcp.sock`
   with exactly two socat addresses and no trailing `-`.

The M1 is green only after all four runtime checks pass.


## Known Failure Mode — `sudo rm` during a cask upgrade

Before tap PR #30, the cask's `uninstall delete:` shelled out to `sudo rm` unconditionally
(`uninstall_delete` passes `sudo: true`, Homebrew `cask/artifact/abstract_uninstall.rb:509`). Over
ssh there is no TTY, so sudo could not prompt, the uninstall aborted — and because the upgrade path
runs uninstall *first*, `brew upgrade --cask` and `brew install --cask` both died with it, after the
destructive half had already run. That deleted `/Applications/VoiceBar.app` on the M1, and on
2026-08-19 destroyed the main Mac's LaunchAgents too.

Tap PR #30 (`67f567a`, merged 2026-08-19T14:45Z) switched that stanza to `trash:`, which needs no
root — nothing in `~/Library/LaunchAgents` is root-owned.

**That fix does NOT rescue a machine that is already registered at a pre-fix version.** Homebrew
reads the uninstall stanza from the **old** version's saved cask in
`Caskroom/voicebar/.metadata/<version>/*/Casks/voicebar.rb`, never from the newly tapped one. A Mac
whose ledger still says `2.1.10` will run `2.1.10`'s `sudo rm` no matter how current the tap is.

This is why the drift path never upgrades. `voicelayer update` greps the saved cask for `delete:`
and `sudo: true`; if the recipe it would run needs root, it re-registers instead — clearing the
stale entry and adopting with `--force`, so that recipe is never executed.

If you ever see `sudo: a terminal is required to read the password`, do not reach for sudo. Run
`voicelayer update`.
