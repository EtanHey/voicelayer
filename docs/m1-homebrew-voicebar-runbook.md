# M1 Pro Homebrew VoiceBar Runbook

Use this when bringing the M1 Pro onto the same VoiceLayer/VoiceBar line and
personal voice settings as this Mac.

This runbook is for the Homebrew path. Do not use the older bundle-transfer
runbook unless the goal is explicitly to copy a prepared transfer bundle.

## Current Release Targets

- Homebrew tap: `etanhey/layers`
- VoiceBar cask: `2.2.6`
- VoiceLayer formula: `2.2.6`
- VoiceLayer npm package: `voicelayer-mcp@2.2.6`
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
brew tap
HOMEBREW_NO_AUTO_UPDATE=1 brew list --versions voicelayer cmuxlayer brainlayer 2>/dev/null || true
HOMEBREW_NO_AUTO_UPDATE=1 brew list --cask --versions voicebar brainbar 2>/dev/null || true
HOMEBREW_NO_AUTO_UPDATE=1 brew info etanhey/layers/voicelayer || true
HOMEBREW_NO_AUTO_UPDATE=1 brew info --cask etanhey/layers/voicebar || true

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

Run on the M1:

```bash
# Over ssh use the absolute path; bare `brew` is not on the non-interactive PATH.
BREW=/opt/homebrew/bin/brew

$BREW tap etanhey/layers
$BREW trust --formula etanhey/layers/voicelayer
$BREW trust --cask etanhey/layers/voicebar
$BREW update

# Check what brew thinks is installed BEFORE touching anything. A stale registration
# (e.g. a version brew still lists but /Applications no longer matches) sends `install`
# down the upgrade path, which runs `uninstall` first.
$BREW list --versions --cask voicebar || true
ls /opt/homebrew/Caskroom/voicebar 2>/dev/null || true

$BREW upgrade etanhey/layers/voicelayer || $BREW install etanhey/layers/voicelayer
$BREW upgrade --cask etanhey/layers/voicebar || $BREW install --cask etanhey/layers/voicebar
voicelayer setup
```

Verify the tap line before proceeding:

```bash
brew info etanhey/layers/voicelayer | sed -n '1,20p'
brew info --cask etanhey/layers/voicebar | sed -n '1,30p'
```

Expected:

- `voicelayer` reports `2.2.6`
- `voicebar` reports `2.2.6`
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


## Known Failure Mode — fixed in the tap 2026-08-19

Before tap PR #30, the cask's `uninstall delete:` shelled out to `sudo rm` unconditionally
(`uninstall_delete` passes `sudo: true`, Homebrew `cask/artifact/abstract_uninstall.rb:509`). Over
ssh there is no TTY, so sudo could not prompt, the uninstall aborted — and because the upgrade path
runs uninstall *first*, `brew upgrade --cask` and `brew install --cask` both died with it, after the
destructive half had already run. That deleted `/Applications/VoiceBar.app` on the M1.

Fixed in tap PR #30 (`67f567a`, merged 2026-08-19T14:45Z) by switching that stanza to `trash:`,
which needs no root — nothing in `~/Library/LaunchAgents` is root-owned.

**The fix is tied to the tap revision, not the app version.** Cask `2.2.6` exists both pre- and
post-fix: the 2.2.6 install that broke the M1 ran against the pre-fix definition. So always
`$BREW update` before a cask operation, and if you see `sudo: a terminal is required to read the
password`, your tap predates `67f567a` — update it and retry rather than reaching for sudo.
