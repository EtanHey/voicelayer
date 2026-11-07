# VoiceBar 2.3 QA build

This builds a real daemon/hotkey app, not the old UIE2E-only preview. Merge the
version PR first. The stacked handover PR owns switch/restore/status and M1 acceptance.

On the occupied M4, build only through the captain gate:

```bash
~/.local/state/captain-2.2.61/heavy.sh r1 bash scripts/qa-candidate-2.3.sh build
```

Output: `.build.noindex/qa-2.3/VoiceBar-2.3-QA.app`, ad-hoc arm64,
`com.voicelayer.voicebar.qa23`, display name `VoiceBar 2.3 QA`, version `2.3.0`.
Rebuild on M1: the signed LSEnvironment contains absolute checkout paths.
The signed `VOICEBAR_QA23_BUNDLED_DAEMON=1` selects Resources/src even inside
a checkout, and refuses source/Homebrew fallback. Other dev and installed flows
keep their existing daemon resolution.

Signed overrides isolate HOME/CFFIXED_USER_HOME, preferences, state, archive,
processing/tts/vocabulary/effort, think log, replay/tmp, both sockets, PID, heartbeat,
disable flag and retained WAV. Model weights are private APFS clones, so Settings
cannot delete resident weights. The existing Parakeet Python interpreter is shared
without bytecode writes. The daemon-secret destination must be gitignored.

Never use Settings > Relay setup in this QA app: its installer now refuses the
QA marker or a HOME/CFFIXED_USER_HOME differing from the passwd home. The real
F5 relay belongs to the installed app. No relay installation is part of QA testing.

The explicit fixture recorder reuses the existing fake-rec override and emits
16kHz mono 16-bit WAV PCM then silence until Stop. This replaces daemon capture;
For qa23 fixture launches, a QA-only device-free meter replaces AVAudioEngine;
automatic permission requests and hotkeys are skipped. Normal launches are unchanged.
No speaker playback or M1 permission grants are part of the fixture test.

## M1 acceptance (after the stacked handover PR lands)

1. Use a GUI session and the merged checkout. Verify the resident's canonical
   LaunchAgent is loaded with crash-only KeepAlive and normal stdout/err logs.
   Build through heavy.sh as above. Never replace /Applications/VoiceBar.app.
2. Keep output muted; prepare an approved synthetic 16kHz mono 16-bit PCM fixture
   without playing it. Record app/prefs/archive hashes before switching (below).
   Keep other agents from admitting new voice work during the handover.
3. `bash scripts/qa-candidate-2.3.sh switch --fixture-recorder /absolute/fixture.wav`.
   It must refuse active capture/session locks, afplay/say/edge-tts/rec/sox or
   unknown descendants, and established Qwen connections (including uncertain
   keep-alive connections). Resolve refusals through the captain, never bypass.
4. Require a proven clean exit (LaunchAgent last exit code 0), then observe no
   resident for five seconds before launch and another five seconds after QA is ready. A respawn aborts the switch and attempts normal supervised
   restoration. Confirm status shows one QA, zero resident. Fixture mode must show no microphone,
   Accessibility or Input Monitoring prompts; stop/report any prompt, never grant it.
   Switch verifies the live QA daemon's parent and bundled argv after readiness
   and after the final down window. A mismatch aborts through normal safe rollback;
   an unknown/outside-bundle lifetime lock may block rollback with
   `RECOVERY_REQUIRED`. Only explicit `restore --force-resident` skips that evidence.
5. Never use QA Settings > Relay setup or permission buttons. Use isolated socket
   control start-recording/stop-recording (F5 is skipped), allowing fixture duration
   plus one second before Stop. Match transcript to fixture; paste into a scratch
   editor. Only QA archive/state/replay/think-log paths may change. Verify the
   bundled daemon child and isolated sockets/PID/heartbeat, with no speaker output.
6. Attempt ordinary restore during an active fixture: it must refuse. Stop capture,
   then `bash scripts/qa-candidate-2.3.sh restore` twice. Verify canonical launchd
   PID equals resident PID, both live socket connections and daemon pong work,
   and no QA descendants remain. Compare byte hashes; report differences intact.
7. If the QA daemon is unhealthy and ordinary restore refuses, manually run
   `bash scripts/qa-candidate-2.3.sh restore --force-resident`. This explicit escape
   skips QA activity evidence and may interrupt QA capture; it sends exact-PID
   SIGTERM only and waits for the QA app/children to exit before kickstarting the
   resident. It is NEVER automatic. If SIGTERM cannot finish, stop and report;
   do not escalate to SIGKILL. No open/unsupervised resident fallback is used.
8. Test a delayed resident respawn and unhealthy-QA recovery on the M1 rig; keep
   failure receipts. M4 unit tests simulate these states and are not live proof.

For a resident-preserving binary regression probe, build as above, then run
`heavy.sh release-r1fu python3 scripts/test-qa-candidate-runtime.py`. It launches
only the isolated QA bundle, sends socket start with SKIP_HOTKEY, checks authenticated
recording and busy refusal, cancels its silence fixture without transcription,
and retires QA through the same safe path ordinary restore uses. Idle restore
accepts only the proven bundled QA daemon's lifetime booking; it still requires
authenticated idle, queue 0 and no processing jobs. This probe does not run the
resident LaunchAgent switch/restore acceptance procedure above.

Before switch and after restore, run this with `before`/`after` output filenames:

```bash
mkdir -p docs.local/r1-m1
python3 - > docs.local/r1-m1/before.json <<'PYHASH'
import hashlib,json
from pathlib import Path
h=Path.home(); result={}
for root in [Path('/Applications/VoiceBar.app'),h/'Library/Preferences/com.voicelayer.voicebar.plist',h/'.local/share/voicelayer']:
 for p in sorted(root.rglob('*')) if root.is_dir() else [root]:
  result[str(p)]=hashlib.sha256(p.read_bytes()).hexdigest() if p.is_file() else ('directory' if p.exists() else 'absent')
print(json.dumps(result,sort_keys=True,indent=2))
PYHASH
cmp docs.local/r1-m1/before.json docs.local/r1-m1/after.json
```

A mismatch is not a preservation PASS. Keep raw bytes/hashes; a cfprefsd rewrite
is unverified and must be diagnosed rather than normalized away. Unix sockets
have no file bytes to hash and are recreated by owner lifecycle: verify canonical
paths, current owner PID, connections and protocol instead of identical inodes.
