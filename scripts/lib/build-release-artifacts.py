"""Run packaging in a private cwd and publish through pinned directory handles."""
import ctypes
import os
from pathlib import Path
import runpy
import shutil
import subprocess
import sys
import tempfile

helper = runpy.run_path(str(Path(__file__).with_name('cleanup-release-artifacts.py')))


def rename_exclusive(source, name, source_fd, target_fd):
    # macOS renameatx_np refuses even an empty existing destination directory.
    libc = ctypes.CDLL(None, use_errno=True)
    if sys.platform == 'darwin':
        rename = libc.renameatx_np
        flag = 4  # RENAME_EXCL
    else:
        rename = libc.renameat2
        flag = 1  # RENAME_NOREPLACE
    rename.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
    rename.restype = ctypes.c_int
    if rename(source_fd, os.fsencode(source), target_fd, os.fsencode(name), flag):
        error = ctypes.get_errno()
        raise OSError(error, os.strerror(error), name)


def build(app, zip_path, script):
    paths = [Path(app)]
    if zip_path:
        paths.append(Path(zip_path))
    version = paths[0].parent
    for path in paths:
        if path.resolve() != path or path.parent != version:
            raise ValueError('release destination must be resolved and directly inside version directory')
    with helper['artifact_handles'](str(version), list(map(str, paths))) as (fd, _, _):
        for path in paths:
            if os.path.lexists(path):
                raise ValueError('release destination already exists: ' + str(path))
        # fchdir pins cwd across ancestor renames. All child bundle/zip writes
        # remain relative to this private directory, never to a replaceable path.
        os.fchdir(fd)
        staging = tempfile.mkdtemp(prefix='.voicebar-build-', dir='.')
        staging_fd = os.open(staging, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        try:
            os.fchdir(staging_fd)
            env = dict(os.environ, VOICEBAR_RELEASE_STAGED='1',
                       VOICEBAR_RELEASE_ZIP='./VoiceBar.zip' if zip_path else '')
            subprocess.run(['/bin/bash', script, '--install-path', './VoiceBar.app',
                            '--no-stop', '--no-relaunch'], env=env, check=True)
            # Reject swaps during compilation, then publish only through the
            # original descriptor. A later ancestor swap cannot redirect writes.
            with helper['artifact_handles'](str(version), list(map(str, paths))) as (current, _, _):
                if helper['identity'](os.fstat(current)) != helper['identity'](os.fstat(fd)):
                    raise ValueError('release directory changed during build')
                for source, target in zip(['VoiceBar.app', 'VoiceBar.zip'], paths):
                    rename_exclusive(source, target.name, staging_fd, fd)
        finally:
            os.fchdir(fd)
            os.close(staging_fd)
            shutil.rmtree(staging, dir_fd=fd)


if __name__ == '__main__':
    try:
        build(*sys.argv[1:])
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        sys.exit('ERROR: release build failed: ' + str(error))
