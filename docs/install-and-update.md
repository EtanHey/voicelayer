# VoiceBar — install & update

## Install
```bash
bash flow-bar/build-app.sh          # builds + installs /Applications/VoiceBar.app, installs the MCP daemon LaunchAgent
```
Add to Login Items so it starts on login: System Settings → General → Login Items → +, or:
```bash
osascript -e 'tell application "System Events" to make login item at end with properties {path:"/Applications/VoiceBar.app", hidden:true}'
```

## Install safety (this PR)
`build-app.sh` never destroys a working resident app:
- **Refuses to replace** `/Applications/VoiceBar.app` while VoiceBar is **running** (quit first, or set `VOICEBAR_FORCE_APP_REPLACE=1` only after an explicit go).
- The old bundle is **moved to a backup** (`~/Library/Application Support/VoiceBar/Backups/VoiceBar.backup-<ts>.app`), not `rm`'d — and backups are **pruned to the single most recent** one (no `/Applications` clutter).
- Dev bundles (`--install-path <other>`, e.g. `VoiceBarDev.app`) are exempt from the guard.

Restore a backup if a build goes wrong:
```bash
ls -dt "$HOME/Library/Application Support/VoiceBar/Backups/"VoiceBar.backup-*.app | head -1
# quit VoiceBar, then mv that backup to /Applications/VoiceBar.app
```

## Update

`voicelayer update` is a cross-machine updater and auto-detects a git checkout vs a global
package install. It updates the package, rebuilds `/Applications/VoiceBar.app`, runs
`launchd/install.sh`, pulls the Qwen3-TTS model into `~/.voicelayer` if missing, and restarts
the VoiceBar stack.

```bash
voicelayer update --dry-run  # print the plan without executing
voicelayer update            # package + app + model + restart

# Optionally sync personal runtime data (voices, vocabulary, daemon secret):
voicelayer update --data-mode direct       --data-source other-mac.local:/Users/<you>
voicelayer update --data-mode brain-drive  --data-source /Volumes/BrainDrive/VoiceLayerBackup/<you>
```

Personal-data sync is opt-in (`--data-mode skip` is the default). When enabled it rsyncs
`~/.voicelayer/voices`, `voices.json`, `pronunciation.yaml`, `daemon.secret`, and the STT
vocabulary from the source host.

## Who owns the daemon

The daily-driver supervision chain is `launchd -> VoiceBar.app -> child MCP daemon`. The
standalone `com.voicelayer.mcp-daemon` LaunchAgent is retired, because a launchd-owned daemon
cannot reliably inherit VoiceBar's microphone permission. `launchd/install.sh` now *removes*
that old LaunchAgent; it does not install a daemon plist. VoiceBar launches the daemon child
from the installed bundle or checkout and restarts it on crashes, clean exits, and broken-mic
silence signals.

`voicelayer build-app` is the canonical builder (`--install-path` to override the destination;
it refuses to overwrite a running VoiceBar). `voicelayer bar` opens the installed app — it no
longer builds a bare dev binary.

## Disabling VoiceLayer

`DISABLE_VOICELAYER=1` and `/tmp/.voicelayer-daemon-disabled` are hard kill-switches for the
MCP daemon child.

```bash
touch /tmp/.voicelayer-daemon-disabled   # disable daemon child launch/restart
rm -f /tmp/.voicelayer-daemon-disabled   # re-enable
```

When the flag exists, VoiceBar treats exit 0 as an explicit terminal stop. All other child
exits reschedule a restart.

## Hotkey

```bash
voicelayer hotkey install   # Dictation-key -> F18 relay LaunchAgent
voicelayer hotkey status    # LaunchAgent state + current hidutil mapping
```

Requires Input Monitoring permission. Physical F5 is handled natively by VoiceBar; on keyboards
where the physical key is Apple's Dictation key, the `hidutil` relay maps it to VoiceBar's
internal F18. The installer preserves non-VoiceBar `hidutil` mappings and is safe to rerun.
`Shift+F5` re-pastes the latest transcript.

## M1 Pro Homebrew Transfer

For the Homebrew path that brings a second Mac onto the same VoiceLayer voices,
vocabulary, daemon secret, and VoiceBar runtime line, use
[`docs/m1-homebrew-voicebar-runbook.md`](m1-homebrew-voicebar-runbook.md).
