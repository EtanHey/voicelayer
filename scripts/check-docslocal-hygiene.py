#!/usr/bin/env python3
"""Reject bulky/private build artifacts; also supplies the archive filter."""
import os
from pathlib import Path
import sys

MAX_BYTES = 5 * 1024 * 1024
MACHO = {bytes.fromhex(x) for x in ('feedface', 'cefaedfe', 'feedfacf', 'cffaedfe', 'cafebabe', 'bebafeca', 'cafebabf', 'bfbafeca')}


def excluded(path):
    if path.is_symlink():
        return True
    if path.name.endswith(('.app', '.zip', '.dmg', '.tgz')) or path.name == 'DerivedData' or path.name.startswith('.build'):
        return True
    if path.is_file():
        if path.stat().st_size > MAX_BYTES:
            return True
        with path.open('rb') as stream:
            return stream.read(4) in MACHO
    return False


def violations(root):
    for directory, dirs, files in os.walk(root, followlinks=False):
        for name in dirs[:] + files:
            path = Path(directory) / name
            if excluded(path):
                yield path
                if name in dirs:
                    dirs.remove(name)


if __name__ == '__main__':
    root = Path(sys.argv[1])
    if not root.is_dir() or root.is_symlink():
        sys.exit('ERROR: expected an existing receipt directory')
    bad = list(violations(root))
    for path in bad:
        print('ERROR: forbidden receipt artifact: ' + str(path), file=sys.stderr)
    sys.exit(bool(bad))
