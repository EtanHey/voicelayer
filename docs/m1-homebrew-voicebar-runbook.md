# M1 Pro Homebrew VoiceBar Runbook

Use this when bringing the M1 Pro onto the same VoiceLayer/VoiceBar line and
personal voice settings as this Mac.

This runbook is for the Homebrew path. Do not use the older bundle-transfer
runbook unless the goal is explicitly to copy a prepared transfer bundle.

## Current Release Targets

- Homebrew tap: `etanhey/layers`
- VoiceBar cask: `2.1.9`
- VoiceLayer formula: `2.1.9`
- VoiceLayer npm package: `voicelayer-mcp@2.1.9`
- Expected npm tarball SHA256:
  `8ddf3c7661a740296aad0471e98efc195c60cac934f7685ac6d73be8189e811f`

## Safety Rules

- Do not print `~/.voicelayer/daemon.secret`.
- Do not run `tccutil reset` as a first step.
- Keep standalone `voicelayer serve` brew services disabled; VoiceBar owns the
  microphone-permissioned daemon child.
- Do not treat a green brew install as runtime green. Runtime green requires a
  real F5 -> speak -> paste check on the M1.

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

- user is the intended M1 account, for example `localaiengine`
- `uname -m` is `arm64`
- Tailscale is connected

If inbound SSH should be available, enable Remote Login in:

```text
System Settings -> General -> Sharing -> Remote Login
```

## 2. Read-Only Remote Inventory

From this Mac, once the M1 is reachable:

```bash
ssh -o BatchMode=yes -o ConnectTimeout=8 localaiengine@<m1-tailscale-name-or-ip> '
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
brew tap etanhey/layers
brew trust --formula etanhey/layers/voicelayer
brew trust --cask etanhey/layers/voicebar
brew update
brew upgrade etanhey/layers/voicelayer || brew install etanhey/layers/voicelayer
brew upgrade --cask etanhey/layers/voicebar || brew install --cask etanhey/layers/voicebar
voicelayer setup
```

Verify the tap line before proceeding:

```bash
brew info etanhey/layers/voicelayer | sed -n '1,20p'
brew info --cask etanhey/layers/voicebar | sed -n '1,30p'
```

Expected:

- `voicelayer` reports `2.1.9`
- `voicebar` reports `2.1.9`
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
