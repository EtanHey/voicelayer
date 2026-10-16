#!/usr/bin/env bash
# Private, append-only recording backup. Python 3 and rsync are required.
set -euo pipefail
exec python3 - "$0" "$@" <<'PY'
import ctypes
import fcntl
import os
from pathlib import Path
import plistlib
import socket
import stat
import subprocess
import sys
import tempfile
import time

os.umask(0o077)
script = Path(sys.argv[1]).resolve()
args = sys.argv[2:]
if args not in ([], ['--dry-run'], ['--install']):
    sys.exit('Usage: backup-recordings-icloud.sh [--dry-run|--install]')
home = Path(os.environ['HOME']).resolve()
source = home / '.local/share/voicelayer/recordings'
cloud = home / 'Library/Mobile Documents/com~apple~CloudDocs'
dest = cloud / 'VoiceLayer/recordings' / socket.gethostname().split('.')[0]
logs = home / 'Library/Logs/voicelayer'
dry = args == ['--dry-run']

def safe(path):
    # Refuse symlinks at every level, including dangling links. Never follow a
    # recordings link into other private data or a destination link out of iCloud.
    for part in (path, *path.parents):
        if part.is_symlink():
            raise RuntimeError('symlink refused: ' + str(part))

def signature(path):
    st = path.lstat()
    if not stat.S_ISREG(st.st_mode):
        raise RuntimeError('not a regular file: ' + str(path))
    return st.st_size, st.st_mtime_ns

def publish(staged, target):
    if sys.platform == 'darwin':
        # macOS SDK sys/stdio.h: RENAME_EXCL = 0x4. Atomic no-replace rename
        # avoids exposing hard links to the iCloud file provider.
        libc = ctypes.CDLL(None, use_errno=True)
        rename = libc.renamex_np
        rename.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint]
        rename.restype = ctypes.c_int
        if rename(os.fsencode(staged), os.fsencode(target), 0x4):
            code = ctypes.get_errno()
            raise OSError(code, os.strerror(code), str(target))
    else:
        os.link(staged, target)  # exclusive publication on non-macOS test hosts

logfile = None
def log(message):
    line = time.strftime('%Y-%m-%dT%H:%M:%S%z') + ' ' + message
    print(line, flush=True)
    if logfile:
        logfile.write(line + '\n')
        logfile.flush()

def main():
    global logfile
    if args == ['--install']:
        target = home / 'Library/LaunchAgents/com.voicelayer.recordings-backup.plist'
        safe(target)
        with open(script.parent.parent / 'launchd/com.voicelayer.recordings-backup.plist', 'rb') as f:
            config = plistlib.load(f)
        job_script = script
        for keg in script.parents:
            if keg.parent.name == 'voicelayer' and keg.parent.parent.name == 'Cellar':
                # Keep the suffix within the keg (e.g. libexec/scripts/...).
                # Do not resolve opt: Homebrew retargets it on each upgrade.
                job_script = keg.parent.parent.parent / 'opt/voicelayer' / script.relative_to(keg)
                break
        config['ProgramArguments'] = ['/bin/bash', str(job_script)]
        # Bash exits nonzero if the script disappears. Retain that stderr even
        # when the script cannot start and open its own application log.
        error_log = logs / 'recordings-backup.log'
        safe(error_log)
        logs.mkdir(parents=True, exist_ok=True)
        error_log.touch(exist_ok=True)
        config['StandardErrorPath'] = str(error_log)
        # Render only: loading/running remains a deliberate operator step.
        target.parent.mkdir(parents=True, exist_ok=True)
        with open(target, 'wb') as f:
            plistlib.dump(config, f)
        print('Installed (not loaded): ' + str(target))
        return
    for path in (source, dest, logs):
        safe(path)
    if not dry:
        logs.mkdir(parents=True, exist_ok=True)
        safe(logs / 'recordings-backup.log')
        logfile = open(logs / 'recordings-backup.log', 'a')
        try:
            fcntl.flock(logfile, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            print('Backup already running; skipped')
            return
    if not source.is_dir():
        log('No recordings tree; skipped')
        return
    if not cloud.is_dir():
        log('iCloud Drive unavailable; skipped')
        return
    pending = []
    sessions = {}
    # Sessions are dated directories containing audio.wav plus sidecars. The
    # ten-minute rule is conservative even for sessions already marked complete.
    for root, dirs, files in os.walk(source, followlinks=False):
        folder = Path(root)
        dirs[:] = [d for d in dirs if not (folder / d).is_symlink()]
        session = sessions.get(folder.parent)
        audio = folder / 'audio.wav'
        if 'audio.wav' in files and not audio.is_symlink():
            audio_sig = signature(audio)
            session = (audio, audio_sig)
            if time.time_ns() - audio_sig[1] < 600 * 1_000_000_000:
                log('Active session skipped: ' + str(folder.relative_to(source)))
                session = None
        sessions[folder] = session
        if session is None:
            continue
        audio, audio_sig = session
        for name in files:
            src = folder / name
            if src.is_symlink() or not src.is_file():
                continue
            sig = signature(src)
            target = dest / src.relative_to(source)
            safe(target)
            if target.exists():
                if signature(target) == sig:
                    continue
                target = target.with_name(target.name + '.changed-%s-%s' % sig)
                index = 0
                while target.exists():
                    safe(target)
                    if signature(target) == sig:
                        break
                    index += 1
                    target = target.with_name(target.name + '-' + str(index))
                else:
                    pending.append((src, target, sig, audio, audio_sig))
                continue
            pending.append((src, target, sig, audio, audio_sig))
    probe = dest
    while not probe.exists():
        probe = probe.parent
    output = subprocess.check_output(['df', '-Pk', str(probe)], text=True)
    available = int(output.splitlines()[-1].split()[3]) * 1024
    required = sum(item[2][0] + 4096 for item in pending)
    if available - required < 25_000_000_000:
        log('space guard: skipped; free=%d pending=%d reserve=25000000000' % (available, required))
        return
    log(('DRY RUN: ' if dry else '') + 'pending files=%d bytes=%d' % (len(pending), required))
    for src, target, sig, audio, audio_sig in pending:
        if dry:
            continue
        safe(src)
        safe(target)
        if signature(src) != sig or signature(audio) != audio_sig:
            log('Changed during run; skipped: ' + str(src.relative_to(source)))
            continue
        target.parent.mkdir(parents=True, exist_ok=True)
        # rsync only writes a private staging file. Publish by exclusive atomic
        # rename: interruption cannot leave a partial backup or overwrite a file.
        with tempfile.TemporaryDirectory(prefix='.backup-', dir=target.parent) as staging:
            staged = Path(staging) / 'payload'
            subprocess.run(['rsync', '--times', '--ignore-existing', '--', str(src), str(staged)], check=True)
            staged_sig = signature(staged)  # lstat rejects symlinks/non-files
            # macOS rsync preserves whole-second mtimes. Compare that transport
            # precision first; restore exact ns only after byte verification.
            if staged_sig[0] != sig[0] or staged_sig[1] // 1_000_000_000 != sig[1] // 1_000_000_000:
                raise RuntimeError('Staged verification failed (signature): ' + str(src.relative_to(source)))
            if subprocess.run(['cmp', '-s', str(staged), str(src)]).returncode != 0:
                raise RuntimeError('Staged verification failed (bytes): ' + str(src.relative_to(source)))
            if signature(src) != sig or signature(audio) != audio_sig:
                raise RuntimeError('Staged verification failed (source changed): ' + str(src.relative_to(source)))
            os.utime(staged, ns=(sig[1], sig[1]))
            if signature(staged) != sig:
                raise RuntimeError('Staged verification failed (final signature): ' + str(src.relative_to(source)))
            os.chmod(staged, 0o600)
            publish(staged, target)  # EEXIST fails closed, never replaces
        log(('Changed version: ' if '.changed-' in target.name else 'Copied: ') + str(target.relative_to(dest)))
    log('Finished; iCloud upload/remote durability NOT VERIFIED')

try:
    main()
except Exception as error:
    log('ERROR: ' + str(error))
    sys.exit(1)
PY
