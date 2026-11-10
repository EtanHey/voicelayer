#!/usr/bin/env python3
"""Real qa23 binary regression probe; no resident handover, devices or audio output."""
import json
import os
from pathlib import Path
import plistlib
import runpy
import socket
import subprocess
import time
import wave

ROOT = Path(__file__).resolve().parents[1]
G = runpy.run_path(str(ROOT / 'scripts/lib/qa-candidate-lifecycle.py'))['main'].__globals__
APP, BASE = G['APP'], G['BASE']
info = plistlib.loads((APP / 'Contents/Info.plist').read_bytes())
assert info['CFBundleIdentifier'] == 'com.voicelayer.voicebar.qa23'
assert not G['pids'](APP), 'QA already running'
env = info['LSEnvironment']
assert Path(env['HOME']).is_relative_to(BASE)
assert all(env[key].startswith('/tmp/vl-qa23-') for key in ['VOICELAYER_SOCKET_PATH', 'VOICELAYER_MCP_SOCKET_PATH'])
G['B']['prepare'](env)  # Includes the fail-closed gitignore check before daemon.secret writes.
wav = BASE / 'silence.wav'
with wave.open(str(wav), 'wb') as stream:
    stream.setnchannels(1); stream.setsampwidth(2); stream.setframerate(16000)
    stream.writeframes(bytes(32000))
env = {**env, **G['B']['fixture_recorder'](wav)}
results = {}


def health():
    return G['qa_health'](env)


def control(command):
    with socket.socket(socket.AF_UNIX) as client:
        client.connect(env['VOICELAYER_SOCKET_PATH'])
        client.sendall((json.dumps({'type': 'control', 'command': command}) + '\n').encode())


def wait_for(predicate, seconds=10):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        try:
            if predicate(): return True
        except (OSError, ValueError, RuntimeError): pass
        time.sleep(.1)
    return False


with (BASE / 'runtime-probe.log').open('w') as log:
    # Sanitize inherited test/voice overrides; the signed candidate supplies every writable path.
    inherited = {key: value for key, value in os.environ.items()
                 if not key.startswith(('QA_VOICE', 'VOICELAYER_', 'VOICEBAR_'))}
    proc = subprocess.Popen([str(APP / 'Contents/MacOS/VoiceBar')], env={**inherited, **env},
                            stdout=log, stderr=log)
    processes = G['processes']
    def reaped_processes():
        proc.poll()  # Reap our own exited child so quit_app does not mistake its zombie for a survivor.
        return processes()
    G['processes'] = reaped_processes
    booking = Path(env['VOICELAYER_STATE_DIR']) / 'voicelayer-session-runtime-probe.lock'
    try:
        assert wait_for(lambda: health()['recording_state'] == 'idle'), 'QA health unavailable'
        rows = G['processes']()
        children = [pid for pid, parent, name in rows if parent == proc.pid and Path(name).name == 'bun']
        assert len(children) == 1, children
        argv = G['command_line'](children[0])
        results['daemon_argv'] = argv
        results['bundled_daemon'] = argv.split()[-1] == str(APP / 'Contents/Resources/src/mcp-server-daemon.ts')
        # Reproduce an idle post-ask booking without producing speaker audio.
        with booking.open('x') as stream:
            json.dump({'pid': children[0], 'sessionId': f'mcp-{children[0]}'}, stream)
        try:
            G['idle'](Path(env['VOICELAYER_TMP_ROOT']), Path(env['VOICELAYER_STATE_DIR']), health)
            results['idle_qa_lifetime_booking'] = True
        except RuntimeError as error:
            results['idle_qa_lifetime_booking'] = False
            results['idle_refusal'] = str(error)
        time.sleep(5.1)  # Explicit launch-command grace, not the capture assertion.
        control('start-recording')
        results['skip_hotkey_socket_recording'] = wait_for(lambda: health()['recording_state'] == 'recording')
        results['health_after_start'] = {key: health()[key] for key in
                                         ['recording_state', 'queue_depth', 'processing_count', 'recording_jobs', 'mic_take_id']}
        if results['skip_hotkey_socket_recording']:
            try:
                G['quit_app'](APP, env)
                results['active_capture_refused'] = False
            except RuntimeError as error:
                results['active_capture_refused'] = 'in progress' in str(error)
        print(json.dumps(results, indent=2), flush=True)
    finally:
        # Cancel ONLY this probe's fixture, before any STT or paste delivery.
        current = health()
        if current['recording_state'] == 'recording':
            locks = list(Path(env['VOICELAYER_TMP_ROOT']).glob('voicelayer-session-*.lock'))
            for lock in locks:
                if json.loads(lock.read_text()).get('pid') == children[0]:
                    token = lock.stem.removeprefix('voicelayer-session-')
                    (Path(env['VOICELAYER_STATE_DIR']) / ('cancel-' + token)).touch()
                    (Path(env['VOICELAYER_STATE_DIR']) / ('stop-' + token)).write_text(
                        json.dumps({'take_id': current['mic_take_id'], 'cancelled': True}))
        assert wait_for(lambda: health()['recording_state'] == 'idle' and health()['recording_jobs'] == []), 'fixture did not drain'
        if results.get('idle_qa_lifetime_booking'):
            G['quit_app'](APP, env)  # Same safe candidate retirement used by ordinary restore.
        else:
            # The old binary's known checkout child cannot pass lifetime_booking; retire our own
            # isolated Popen only after authenticated idle and the existing child-activity guard.
            G['refuse_activity'](G['processes'](), [proc.pid], G['command_line'], G['qwen_connections'])
            proc.terminate()
        proc.wait(timeout=10)
        assert wait_for(lambda: not any(pid == children[0] for pid, _, _ in G['processes']())), 'QA child survived'
        booking.unlink()
        print('QA app and daemon exited; resident untouched.', flush=True)

assert all(results.get(key) for key in ['bundled_daemon', 'idle_qa_lifetime_booking',
                                      'skip_hotkey_socket_recording', 'active_capture_refused']), results
