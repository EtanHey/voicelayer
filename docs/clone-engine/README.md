# Clone engine control (V10 → U3)

VoiceBar owns the lifecycle; the MCP child remains a consumer. Settings can use
`VoiceState.cloneEngine` and `VoiceState.sendCommand`. No view is added by V10.

## Event, on every change and every socket connection

```json
{"type":"clone_engine","state":"running","since":"2026-11-05T00:00:00Z","reason":null,"pid":123,"start_with_voicebar":true}
```

- `state`: `running | starting | restarting | stopped | failed`.
- `since`: ISO 8601 time of the current state/reason/PID transition; reconnects retain it.
- `reason`: nullable stable code. `adopted_existing`, `port_occupied`,
  `python_missing`, `script_missing`, `script_unresolved`, `launch_failed(<code>)`,
  `exited_early(<status>)`, `engine_exited(<status>)`, `startup_timeout(<status>)`,
  `health_unavailable`, `stop_timeout`, `user_stop`, `voicebar_quit`.
- `pid`: positive engine PID, or null when no identity is verified. During
  `starting`, it is the child VoiceBar just launched.
- `start_with_voicebar`: default true, persisted in VoiceBar's selected defaults
  domain under `cloneEngineStartWithVoiceBar`. Toggle writes affect the next
  app opening; they do not stop an active engine or start one immediately.

`running` means the authenticated health endpoint answers with `status: ok`
and a PID. It does not mean weights are resident or synthesis/acoustics passed.
An adopted engine remains foreign; its PID confers no permission to signal it.
Unknown/old clients can ignore this additive event. Peer-injected lifecycle
snapshots are discarded by VoiceBar.

## Commands and acknowledgement

```json
{"cmd":"clone_engine","action":"start","id":"optional-correlation-id"}
{"cmd":"clone_engine","action":"restart","id":"optional-correlation-id"}
{"cmd":"clone_engine","action":"stop","id":"optional-correlation-id"}
{"cmd":"clone_engine","action":"set_autostart","value":false,"id":"optional-correlation-id"}
{"type":"ack","command":"clone_engine","outcome":"accept","id":"optional-correlation-id"}
```

Only `set_autostart` accepts/requires `value`, and only a JSON boolean is valid.
The app consumes commands locally, including commands from socket peers, and
never forwards them to the MCP child. Acknowledgement means the command was
accepted, not that startup completed: render subsequent lifecycle events.
Replies go only to the requesting connection; `id` is echoed when supplied.
Acknowledgements use the existing `command`/`outcome` wire shape and reach
`VoiceState.onAckEvent` when an ID is supplied. Failures use `outcome: reject`, reason `foreign_engine | invalid_command | quitting |
isolated_app`. Stop/Restart reject a known foreign engine and leave it intact;
manual Start adopts it. Stop cancels queued/in-flight restarts until explicit
Start/Restart or the next app opening. Quit stops only the retained owned child.

## Runtime policy

- Dedicated Python venv + the installed app's matching source location. No shell
  interpolation, launchd changes, or Homebrew writes. Preflight names missing
  Python/source; a child exit includes its status. Four consecutive startup
  failures before health latch `failed` with that specific cause and cancel
  retries until Start/Restart or the next app opening. Any verified health resets
  the consecutive-startup-failure budget; no dependencies are auto-installed.
- Child environment allowlist: HOME, fixed PATH, LANG. No inherited API keys,
  Python injection, proxies, test overrides, audio commands, or microphone work.
- Read-only authenticated health polls; failed HTTP is followed by a bounded
  nonblocking TCP connect (200 ms), so TCP TIME_WAIT from a closed listener is
  not mistaken for a live occupied endpoint. Probes never reserve the port.
  An occupied/unverified endpoint reports
  `failed/port_occupied` and waits for explicit Start/Restart. Never kill/reap an
  unknown listener. The legacy `com.golems.tts-daemon` LaunchAgent (RunAtLoad=false)
  can still be started manually; VoiceBar adopts it and cannot stop it by design.
- Restart delay: 1, 2, 4, 8, 16, 30 seconds (30-second cap). Reset after 60
  seconds of owned process uptime on a healthy poll. Startup deadline: 120 seconds before the first
  healthy response. A later missed health poll reports `failed/health_unavailable`
  and keeps the owned process alive, preserving any in-flight reply. A process
  exit triggers crash recovery. Health polls
  every 1 second while starting and 3 seconds while observing a healthy engine.
- Stop/Restart and health-driven retirement return without waiting on main.
  A retained retiring child blocks replacements until exit is confirmed; stale
  completion callbacks cannot undo a later Stop. The worker bounds waits to
  3 seconds graceful + 1 second after SIGKILL. Only Quit uses those bounded waits
  synchronously. A failed stop retains ownership and reports `stop_timeout`.
- stdout/stderr and timestamped lifecycle causes append to
  `~/Library/Logs/voicelayer/clone-engine.log` (0600); rotation retains `.log.1`.
  Each file is capped at 1 MiB, continuously during output, for at most 2 MiB.
  Adopted external engines keep their existing owner's logging configuration.
  Pipe draining, file appends and rotation run off-main; no pipe backpressure
  waits or file writes run in UI Stop/Restart handlers.
- Python binds/listens before app construction, with no SO_REUSEPORT. The kernel
  rejects a second owner even between the probe and process launch.
- QA/candidate/isolated apps cannot create the production runtime. Tests inject
  fake HTTP servers on OS-assigned ephemeral ports, state, schedules and children.
- No live engine/app/socket/launchd mutation was part of worker verification.
