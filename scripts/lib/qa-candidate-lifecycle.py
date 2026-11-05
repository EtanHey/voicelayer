#!/usr/bin/env python3
"""Explicit QA owner handover; no installs, unlinking or force kills."""
import json
import os
from pathlib import Path
import plistlib
import pwd
import re
import runpy
import signal
import socket
import subprocess
import sys
import time

B = runpy.run_path(str(Path(__file__).with_name('qa-candidate-2.3.py')))
APP, RESIDENT, BASE = B['APP'], B['RESIDENT'], B['BASE']
HOME = Path(pwd.getpwuid(os.getuid()).pw_dir)
LABEL = f'gui/{os.getuid()}/com.voicelayer.voicebar'
LIVE = {'VOICELAYER_SOCKET_PATH': '/tmp/voicelayer.sock', 'VOICELAYER_MCP_SOCKET_PATH': '/tmp/voicelayer-mcp.sock'}
DOWN_SECONDS = 5

def processes():
    return B['processes']()

def pids(app):
    return [pid for pid, _, name in processes() if name == str(app / 'Contents/MacOS/VoiceBar')]

def descendants(rows, owners):
    owned = set(owners)
    for _ in rows:
        owned.update(pid for pid, parent, _ in rows if parent in owned)
    return owned

def command_line(pid):
    return subprocess.check_output(['/bin/ps', '-p', str(pid), '-o', 'args='], text=True).strip()

def qwen_connections(owned):
    result = subprocess.run(['/usr/sbin/lsof', '-nP', '-a', '-p', ','.join(map(str, sorted(owned))),
                             '-iTCP:8880', '-sTCP:ESTABLISHED'], text=True, capture_output=True, timeout=2)
    if result.returncode not in [0, 1] or result.stderr or (result.returncode == 1 and result.stdout):
        raise RuntimeError('REFUSED: Qwen connection activity is unknown')
    return bool(result.stdout)

def refuse_activity(rows, owners, args, tcp):
    owned = descendants(rows, owners)
    for pid, _, executable in rows:
        if pid not in owned or pid in owners:
            continue
        name, command = Path(executable).name, args(pid)
        # Only known idle daemons are safe. Every player, recorder, generator,
        # helper and unknown child refuses, including afplay/say/edge-tts/rec/sox.
        safe = (name == 'bun' and 'mcp-server-daemon.ts' in command) or name == 'whisper-server'
        safe |= name.lower().startswith('python') and any(script in command for script in ['/src/parakeet-worker.py', '/src/tts_daemon.py'])
        if not command or not safe:
            raise RuntimeError('REFUSED: playback/capture or unknown child: ' + name)
    if tcp(owned):
        raise RuntimeError('REFUSED: Qwen request/connection is active')
    return owned

def idle(tmp, state, health=None):
    for directory in [tmp, state]:
        if any(directory.glob('voicelayer-session-*.lock')):
            raise RuntimeError('REFUSED: voice session/ask lock exists')
    data = health() if health else json.loads((state / 'recording-state.json').read_text())
    if (data.get('recording_state') if health else data.get('state')) != 'idle' or (health and (data.get('queue_depth') != 0 or data.get('processing_count') != 0 or data.get('recording_jobs') != [] or data.get('capture_error'))):
        raise RuntimeError('REFUSED: recording/ask/speech/processing in progress')
    if not health:
        pid = data.get('pid')
        if type(pid) is not int or pid <= 0:
            raise RuntimeError('REFUSED: unknown recording owner')
        os.kill(pid, 0)

def qa_health(env):
    token = (Path(env['VOICELAYER_STATE_DIR']) / 'daemon.secret').read_text().strip()
    request = {'jsonrpc': '2.0', 'id': 1, 'method': 'voicelayer/speech', 'params': {'cmd': 'health', 'token': token}}
    with socket.socket(socket.AF_UNIX) as client:
        client.settimeout(2); client.connect(env['VOICELAYER_MCP_SOCKET_PATH'])
        client.sendall((json.dumps(request) + '\n').encode())
        with client.makefile('rb') as stream:
            response = json.loads(stream.readline(65536))
    if response.get('id') != 1 or response.get('result', {}).get('type') != 'health':
        raise RuntimeError('REFUSED: QA health unavailable; explicit restore --force-resident is available')
    return response['result']

def quit_app(app, env=None, force=False):
    owners = pids(app)
    if not owners:
        return
    if len(owners) != 1:
        raise RuntimeError('REFUSED: ambiguous app owners')
    tmp, state = (Path(env['VOICELAYER_TMP_ROOT']), Path(env['VOICELAYER_STATE_DIR'])) if env else (Path('/tmp'), HOME / '.local/state/voicelayer')
    check = lambda: idle(tmp, state, (lambda: qa_health(env)) if env else None)
    if not force:
        check()
    rows = processes(); owned = descendants(rows, owners)
    if not force:
        refuse_activity(rows, owners, command_line, qwen_connections)
        check()
        owned = refuse_activity(processes(), owners, command_line, qwen_connections)
    for pid in owners:
        if pid in pids(app):
            os.kill(pid, signal.SIGTERM)  # Native handler routes to graceful menu Quit.
    for _ in range(100):
        if not owned.intersection(pid for pid, _, _ in processes()):
            return
        time.sleep(.1)
    raise RuntimeError('REFUSED: QA/app descendants did not exit; never escalating past SIGTERM')

def job_info(stopped=False):
    path = HOME / 'Library/LaunchAgents/com.voicelayer.voicebar.plist'
    config = plistlib.loads(path.read_bytes())
    expected = {'Label': 'com.voicelayer.voicebar', 'ProgramArguments': [str(RESIDENT / 'Contents/MacOS/VoiceBar')],
                'KeepAlive': {'SuccessfulExit': False}, 'RunAtLoad': True,
                'StandardOutPath': str(HOME / 'Library/Logs/voicelayer/voicebar.log'),
                'StandardErrorPath': str(HOME / 'Library/Logs/voicelayer/voicebar-err.log')}
    if any(config.get(key) != value for key, value in expected.items()):
        raise RuntimeError('REFUSED: resident supervision/KeepAlive/log configuration is unknown')
    result = subprocess.run(['/bin/launchctl', 'print', LABEL], text=True, capture_output=True, timeout=2)
    loaded = {'path': str(path), 'program': expected['ProgramArguments'][0], 'stdout path': expected['StandardOutPath'], 'stderr path': expected['StandardErrorPath']}
    if result.returncode or any(not re.search(r'^\s*' + re.escape(key) + ' = ' + re.escape(value) + r'\s*$', result.stdout, re.M) for key, value in loaded.items()):
        raise RuntimeError('REFUSED: canonical resident LaunchAgent is not loaded as expected')
    match = re.search(r'^\s*pid = (\d+)\s*$', result.stdout, re.M)
    if stopped and (match or not re.search(r'^\s*last exit code = 0\s*$', result.stdout, re.M)):
        raise RuntimeError('REFUSED: resident LaunchAgent has not observed a clean stopped exit')
    return int(match[1]) if match else None

def connected(path, ping=False):
    with socket.socket(socket.AF_UNIX) as client:
        client.settimeout(1); client.connect(str(path))
        if ping:
            client.sendall(b'{"type":"ping"}\n')
            return json.loads(client.recv(4096).split(b'\n')[0]).get('type') == 'pong'
        return True

def wait_ready(app, env, exclusive=False):
    deadline = time.monotonic() + 10
    for _ in range(100):
        if time.monotonic() >= deadline:
            break
        if exclusive and pids(RESIDENT):
            raise RuntimeError('REFUSED: resident respawned during QA startup')
        try:
            if len(pids(app)) == 1 and connected(env['VOICELAYER_SOCKET_PATH']) and connected(env['VOICELAYER_MCP_SOCKET_PATH'], True):
                return
        except (OSError, ValueError):
            pass
        time.sleep(.1)
    raise RuntimeError('App/daemon not ready; restore explicitly (use --force-resident only if required)')

def restore_resident(force=False):
    job_info()  # Prove supervision is available before retiring QA.
    env = plistlib.loads((APP / 'Contents/Info.plist').read_bytes())['LSEnvironment'] if APP.exists() else B['environment']()
    quit_app(APP, env, force=force)
    subprocess.run(['/bin/launchctl', 'kickstart', LABEL], check=True)  # No -k: never restart a running resident.
    wait_ready(RESIDENT, LIVE)
    if pids(RESIDENT) != [job_info()]:
        raise RuntimeError('REFUSED: restored resident PID does not match its LaunchAgent')
    print('Resident restored under its real LaunchAgent; PID, both sockets and daemon pong verified.')

def stay_down():
    deadline = time.monotonic() + DOWN_SECONDS
    while True:
        if pids(RESIDENT):
            raise RuntimeError('REFUSED: resident respawned; aborting QA switch')
        if time.monotonic() >= deadline:
            return
        time.sleep(.1)

def switch(fixture=None):
    job_info()
    if pids(RESIDENT):
        idle(Path('/tmp'), HOME / '.local/state/voicelayer')
        refuse_activity(processes(), pids(RESIDENT), command_line, qwen_connections)
    info = plistlib.loads((APP / 'Contents/Info.plist').read_bytes())
    if info['CFBundleIdentifier'] != B['IDENTITY'] or info['CFBundleShortVersionString'] != '2.3.0' or pids(APP):
        raise RuntimeError('REFUSED: wrong candidate identity/version or QA already running')
    env = info['LSEnvironment']; B['prepare'](env)
    if fixture:
        env = {**env, **B['fixture_recorder'](fixture)}
    quit_app(RESIDENT)
    try:
        stay_down()  # Observe five seconds before allowing another hotkey owner.
        job_info(stopped=True)  # Crash-only KeepAlive cannot restart a proven clean exit.
        print('VoiceBar 2.3 QA uses a NEW bundle id; ' + ('fixture mode skips device input, permission requests and hotkeys.' if fixture else 'first dictation asks for microphone/accessibility permissions.'), flush=True)
        args = [item for key, value in env.items() for item in ['--env', f'{key}={value}']]
        subprocess.run(['/usr/bin/open', '-n', *args, str(APP)], check=True)
        wait_ready(APP, env, exclusive=True)
        stay_down()  # Observe another five seconds after QA is ready.
    except Exception as error:
        try:
            restore_resident()  # Never invoke the explicit force escape automatically.
        except Exception as recovery:
            raise RuntimeError(f'RECOVERY_REQUIRED: {error}; {recovery}; run restore --force-resident explicitly') from error
        raise RuntimeError(f'Switch aborted; resident supervision restored: {error}') from error
    print('QA ready, resident stayed down for two five-second windows. Use restore when finished.')

def main():
    args = sys.argv[1:] or ['status']
    if args == ['status']:
        print(json.dumps({'resident': pids(RESIDENT), 'qa': pids(APP), 'bundle': str(APP)}, indent=2))
    elif args in [['restore'], ['restore', '--force-resident']]:
        restore_resident(force=len(args) == 2)
    elif args == ['switch']:
        switch()
    elif len(args) == 3 and args[:2] == ['switch', '--fixture-recorder']:
        switch(Path(args[2]).resolve())
    else:
        raise RuntimeError('Usage: build|status|switch [--fixture-recorder WAV]|restore [--force-resident]')

if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, KeyError, RuntimeError, subprocess.SubprocessError) as error:
        sys.exit(str(error))
