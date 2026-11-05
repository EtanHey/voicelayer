# Clone engine inventory (V10, integration/2.3 b53ba2f2)

## Before V10

- `src/tts/qwen3.ts:isDaemonHealthy` authenticates `GET http://127.0.0.1:8880/health` with a 2-second deadline. It checks `status == ok`; it does not launch anything. Synthesis falls back to Edge when unavailable.
- `src/tts-settings.ts` persists short/long engine and voice selections. It has no engine lifecycle preference or owner.
- `src/daemon-health.ts` publishes clone availability inside Speech controls. `SpeechControlsState` decodes `clone_daemon: up|down`. `SpeechSettingsView` offers a copy button for `voicelayer daemon`, with no start control.
- `src/cli/voicelayer.sh daemon` execs the dedicated Python venv (or configured Python, then python3) with `src/tts_daemon.py`. Python's main runs uvicorn on loopback port 8880. Its authenticated health response includes PID and model-loaded status. Health does not load weights.
- M1 read-only inspection of `~/Library/LaunchAgents/com.golems.tts-daemon.plist`: uvicorn factory from the installed bundle; dedicated venv; loopback:8880; RunAtLoad=false; KeepAlive=false. This is local legacy configuration, not an agent installed by this repository. No launchctl mutation or live HTTP probe was performed.
- `VoiceBarDaemonController` owns the separate MCP child, launches the installed bundle's matching sources, sanitizes environment and backs off after exits. It does not supervise Qwen. `VoiceBarApp` activates it after the socket server and stops it on quit.

## Decision

VoiceBar owns only its own clone child. Reuse the app's bundled source location, with the dedicated Python venv and a small environment allowlist. No LaunchAgent installation, bootout, kickstart or migration. A healthy existing engine is adopted for observation only; stop/restart reject foreign ownership. An occupied but unverified endpoint fails closed. Every spawn checks again; Python reserves the listener before constructing the app. Concurrent starts can produce only one bound engine, including against the legacy LaunchAgent. A lost race exits without loading weights. No port-based kill or PID-discovered signal is permitted.

This works with brew-managed bundles without editing Homebrew or launchd state. The engine child and the MCP child have separate lifecycles. Public health means authenticated HTTP service readiness, not model-warm or acoustic proof. Native installation/adoption remains a release gate, outside this isolated worker mission.
