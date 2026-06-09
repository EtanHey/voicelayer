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
```bash
voicelayer update            # git pull + bun install + rebuild + daemon refresh + model/data sync (see scripts/voicelayer-update.sh)
voicelayer update --dry-run  # print the plan without executing
```
