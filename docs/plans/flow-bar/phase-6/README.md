# Phase 6: Integration + CLI

> [Back to main plan](../README.md)

## Goal

End-to-end integration testing, CLI command to launch the bar, and distribution as a local .app bundle.

## Key Technical Decisions

- **CLI:** `voicelayer bar` subcommand (added to `src/cli/voicelayer.sh`) — builds + launches the SwiftUI app
- **Build:** `swift build -c release` in the `flow-bar/` directory, copy binary to known location
- **Auto-launch:** Optional launchd plist for "launch at login" (similar to existing `com.golems.tts-daemon.plist`)
- **.app bundle:** Wrap the built binary in a minimal `.app` for proper icon/permissions attribution
- **Info.plist:** `LSUIElement = YES` for no dock icon, `NSMicrophoneUsageDescription` (future AVAudioEngine)

## Tools

- **Code:** Claude Code (Swift + Bash)
- **Tests:** Integration tests (Bun + Swift)

## Steps

1. Write end-to-end integration test: start MCP server → socket server starts → launch mock bar → verify state events arrive
2. Write command round-trip test: bar sends stop → VoiceLayer receives → stop file created
3. Add `bar` subcommand to `src/cli/voicelayer.sh` — `swift build -c release` + launch binary
4. Add `bar-stop` subcommand — find and kill the FlowBar process
5. Create minimal `.app` bundle structure:
   ```
   FlowBar.app/
   ├── Contents/
   │   ├── Info.plist       # LSUIElement, NSMicrophoneUsageDescription
   │   ├── MacOS/
   │   │   └── FlowBar      # Built binary (symlink or copy)
   │   └── Resources/
   │       └── AppIcon.icns  # Icon
   ```
6. Create launchd plist for auto-launch: `com.voicelayer.flow-bar.plist`
7. Add `bar-install` subcommand — copy .app to ~/Applications, install launchd plist
8. Test full workflow: `voicelayer bar` → pill appears → use voice_speak → bar shows speaking → stop button works
9. Test reconnection: kill VoiceLayer → bar shows disconnected → restart → bar reconnects
10. Update CLAUDE.md with Flow Bar section
11. Update main README.md with Flow Bar quick start

## Depends On

- Phase 1-5 (everything must be working)

## Status

- [ ] End-to-end integration test (state events)
- [ ] Command round-trip test
- [ ] `voicelayer bar` CLI command
- [ ] `voicelayer bar-stop` command
- [ ] .app bundle structure
- [ ] Launchd plist for auto-launch
- [ ] `voicelayer bar-install` command
- [ ] Full workflow test
- [ ] Reconnection test
- [ ] CLAUDE.md update
- [ ] README.md update
