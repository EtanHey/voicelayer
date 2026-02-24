# Phase 5: Production Readiness

> [Back to main plan](../README.md)

## Goal

Ship-quality polish: launch at login, center positioning, context-aware STT, CLAUDE.md/README updates.

## Tools

- **Code:** Claude (Swift + TypeScript + docs)

## Steps

1. Launch at login — Login Items integration
   - `voicelayer bar-install` CLI subcommand
   - Register via `SMAppService.register()` (macOS 13+)
   - Or generate launchd plist at `~/Library/LaunchAgents/com.voicelayer.bar.plist`
   - `voicelayer bar-uninstall` to remove
2. Move to center position (50%)
   - Change `Theme.horizontalOffset` from 0.8 → 0.5
   - Only after Wispr Flow is uninstalled
   - Make configurable via UserDefaults (ties into Phase 3 drag)
3. Context-aware STT post-processing
   - Developer vocabulary: common programming terms, framework names
   - Code context: if focused app is terminal/IDE, boost code-related words
   - API names from current project (scan package.json, imports)
   - Post-process whisper output with vocabulary hints
4. Update CLAUDE.md — document all new socket commands and events
   - CancelCommand, RecordCommand (Phase 2)
   - Partial transcription events (Phase 4)
   - Audio level events (Phase 3)
   - Voice Bar v2 architecture section
5. Update README.md — user-facing documentation
   - Installation instructions for Voice Bar
   - Launch at login setup
   - Click-to-record usage
   - Configuration options
6. npm publish — bump version, publish voicelayer-mcp with v2 features
   - Update package.json version
   - Update CHANGELOG
   - `npm publish`

## Depends On

- Phases 1–4 (this is the final polish phase)

## Status

- [ ] Launch at login
- [ ] Configurable position
- [ ] Context-aware STT
- [ ] CLAUDE.md updates
- [ ] README.md updates
- [ ] npm publish
