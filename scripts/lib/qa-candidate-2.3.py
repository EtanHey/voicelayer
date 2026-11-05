#!/usr/bin/env python3
"""QA-only build and explicit, idle-checked owner handover. No install writes."""
import hashlib
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import wave

ROOT = Path(__file__).resolve().parents[2]
BASE = ROOT / '.build.noindex/qa-2.3'
APP = BASE / 'VoiceBar-2.3-QA.app'
RESIDENT = Path('/Applications/VoiceBar.app')
IDENTITY = 'com.voicelayer.voicebar.qa23'

def read_plist(path):
    return plistlib.loads(subprocess.run(['/usr/bin/plutil', '-convert', 'xml1', '-o', '-', str(path)], check=True, capture_output=True, timeout=2).stdout)

def environment(base=BASE, home=Path.home()):
    # Short, private IPC names: Darwin sun_path is limited to 104 bytes.
    ipc = Path('/tmp') / ('vl-qa23-' + hashlib.sha256(str(base).encode()).hexdigest()[:12])
    state = base / 'home/.local/state/voicelayer'
    env = dict(HOME=str(base / 'home'), CFFIXED_USER_HOME=str(base / 'home'),
               TMPDIR=str(base / 'tmp') + '/', VOICELAYER_TMP_ROOT=str(base / 'tmp'),
               VOICELAYER_STATE_DIR=str(state), XDG_CACHE_HOME=str(base / 'cache'),
               VOICELAYER_SOCKET_PATH=str(ipc / 'v.sock'), VOICELAYER_MCP_SOCKET_PATH=str(ipc / 'm.sock'),
               VOICEBAR_USER_DEFAULTS_SUITE=IDENTITY, VOICEBAR_QA_PRESERVE_OVERRIDES='1',
               VOICEBAR_QA_SKIP_LS_REGISTER='1', VOICELAYER_QA_HEALTH='1', PYTHONDONTWRITEBYTECODE='1', VOICELAYER_DISABLE_CONTROL_LAYER_JOURNAL='1',
               QA_VOICE_THINK_FILE=str(base / 'tmp/thinking.md'),
               VOICELAYER_PROCESSING_SETTINGS_PATH=str(state / 'processing-settings.json'),
               VOICELAYER_TTS_SETTINGS_PATH=str(state / 'tts-settings.json'),
               VOICELAYER_WHISPER_OWNERSHIP_DIR=str(state), QA_VOICE_WHISPER_SERVER_PORT='19183',
               QA_VOICE_STT_VOCABULARY_PATH=str(state / 'stt-vocabulary.json'),
               QA_VOICE_WHISPER_PERFORMANCE_PATH=str(state / 'whisper-performance.json'),
               QA_VOICE_RECORDINGS_DIR=str(base / 'home/.local/share/voicelayer/recordings'),
               QA_VOICE_STT_POLISH_SOCKET=str(ipc / 'polish.sock'))
    for key, name in [('QA_VOICE_MCP_PID_PATH', 'm.pid'), ('QA_VOICE_MCP_HEARTBEAT_PATH', 'm.heartbeat'),
                      ('QA_VOICE_DISABLE_FLAG_PATH', 'disabled'), ('QA_VOICE_RECORDING_STATE_PATH', 'recording-state.json'),
                      ('QA_VOICE_RECORDING_HOLD_PATH', 'hold'), ('QA_VOICE_RETAINED_RECORDING_PATH', 'last.wav')]:
        env[key] = str(ipc / name)
    models = home / '.cache/whisper'
    model = next(iter(sorted(models.glob('ggml-large-v3-turbo*.bin'))), None)
    if model:
        env['QA_VOICE_WHISPER_MODEL'] = str(base / 'cache/whisper' / model.name)
    if (models / 'ggml-small.bin').is_file():
        env['VOICELAYER_LID_MODEL'] = str(base / 'cache/whisper/ggml-small.bin')
    parakeet = home / '.cache/voicelayer/models/parakeet-tdt-0.6b-v3'
    if parakeet.is_dir():
        env['VOICELAYER_PARAKEET_MODEL'] = str(base / 'cache/parakeet')
    runtime = home / '.local/state/voicelayer/parakeet-runtime.json'
    if runtime.is_file():
        python = json.loads(runtime.read_text()).get('python')
        if python and Path(python).is_file():
            env['VOICELAYER_PARAKEET_PYTHON'] = python
    return env

def prepare(env):
    for key in ['HOME', 'VOICELAYER_TMP_ROOT', 'VOICELAYER_STATE_DIR', 'XDG_CACHE_HOME', 'QA_VOICE_RECORDINGS_DIR']:
        path = Path(env[key])
        if not path.resolve().is_relative_to(BASE.absolute()):
            raise RuntimeError('REFUSED: QA state path escapes candidate directory')
        path.mkdir(parents=True, exist_ok=True, mode=0o700)
    subprocess.run(['git', '-C', str(ROOT), 'check-ignore', '-q', '--', str(Path(env['VOICELAYER_STATE_DIR']) / 'daemon.secret')], check=True)
    ipc = Path(env['VOICELAYER_SOCKET_PATH']).parent
    ipc.mkdir(mode=0o700, exist_ok=True)
    if ipc.is_symlink() or ipc.stat().st_uid != os.getuid() or ipc.stat().st_mode & 0o077:
        raise RuntimeError('REFUSED: IPC directory must be private, owned and not a symlink')

def stamp(app):
    if app.resolve() != APP.resolve() or app.is_symlink():
        raise RuntimeError('REFUSED: unexpected candidate destination')
    env = environment()
    prepare(env)
    # APFS clones read model caches without sharing a deletable writable path.
    for key, source in [('QA_VOICE_WHISPER_MODEL', Path.home() / '.cache/whisper'),
                        ('VOICELAYER_LID_MODEL', Path.home() / '.cache/whisper'),
                        ('VOICELAYER_PARAKEET_MODEL', Path.home() / '.cache/voicelayer/models/parakeet-tdt-0.6b-v3')]:
        if key in env and not Path(env[key]).exists():
            target = Path(env[key]); target.parent.mkdir(parents=True, exist_ok=True)
            origin = source / target.name if key in ['QA_VOICE_WHISPER_MODEL', 'VOICELAYER_LID_MODEL'] else source
            subprocess.run(['/bin/cp', '-cR', str(origin), str(target)], check=True)
    path = app / 'Contents/Info.plist'
    info = read_plist(path)
    info.update(CFBundleIdentifier=IDENTITY, CFBundleName='VoiceBar 2.3 QA',
                CFBundleDisplayName='VoiceBar 2.3 QA', LSEnvironment=env)
    info.pop('CFBundleURLTypes', None)
    path.write_bytes(plistlib.dumps(info))
    print(json.dumps(env, indent=2, sort_keys=True))

def processes():
    rows = subprocess.check_output(['/bin/ps', '-axo', 'pid=,ppid=,comm='], text=True)
    return [(int(p), int(parent), name) for p, parent, name in
            (row.strip().split(None, 2) for row in rows.splitlines() if row.strip())]

def pids(app):
    executable = str(app / 'Contents/MacOS/VoiceBar')
    return [pid for pid, _, name in processes() if name == executable]

def fixture_recorder(wav, base=BASE):
    with wave.open(str(wav)) as audio:
        if audio.getcomptype() != 'NONE' or audio.getsampwidth() != 2 or audio.getnchannels() != 1 or audio.getframerate() != 16000:
            raise RuntimeError('Fixture must be uncompressed 16kHz mono signed 16-bit PCM WAV')
    target = base / 'fixture.wav'
    target.write_bytes(wav.read_bytes())
    script = base / 'fixture-recorder.py'
    script.write_text('''#!/usr/bin/env python3
import sys,time,wave
from pathlib import Path
if 'trim' in sys.argv:
    print("Channels       : 1\\nSample Rate    : 16000",file=sys.stderr)
else:
    with wave.open(str(Path(__file__).with_name('fixture.wav'))) as wav:
        while chunk := wav.readframes(800):
            sys.stdout.buffer.write(chunk); sys.stdout.buffer.flush(); time.sleep(.05)
    while True:
        sys.stdout.buffer.write(bytes(1600)); sys.stdout.buffer.flush(); time.sleep(.05)
''')
    script.chmod(0o700)
    return {'VOICELAYER_TEST_FAKE_REC': '1', 'VOICELAYER_TEST_FAKE_REC_BIN': str(script), 'VOICELAYER_TEST_REAL_MIC': '0', 'VOICEBAR_QA_FIXTURE_RECORDER': '1',
            'VOICEBAR_QA_SKIP_PERMISSION_PROMPTS': '1', 'VOICEBAR_QA_SKIP_HOTKEY': '1'}

def main():
    command = sys.argv[1] if len(sys.argv) > 1 else 'help'
    if command == 'stamp':
        stamp(Path(sys.argv[2])); return
    if command != 'build':
        raise RuntimeError('Usage: qa-candidate-2.3.sh build (handover commands are a separate PR)')
    if pids(APP):
        raise RuntimeError('REFUSED: cannot rebuild a running QA bundle')
    if json.loads((ROOT / 'package.json').read_text())['version'] != '2.3.0':
        raise RuntimeError('Merge the R1 version PR first (package must report 2.3.0)')
    subprocess.run(['bash', str(ROOT / 'flow-bar/build-app.sh'), '--install-path', str(APP), '--no-stop', '--no-relaunch'],
                   check=True, env={**os.environ, 'VOICEBAR_QA23_BUILD': '1', 'VOICEBAR_CODESIGN_IDENTITY': '-',
                                    'VOICEBAR_QA_BUILD': '1', 'VOICEBAR_UIE2E_ADHOC': '0'})

if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, KeyError, RuntimeError, subprocess.SubprocessError) as error:
        sys.exit(str(error))
