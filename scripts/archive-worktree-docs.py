#!/usr/bin/env python3
"""Copy only small receipts; never follow symlinks or archive build output."""
import importlib.util
from pathlib import Path
import shutil
import sys

spec = importlib.util.spec_from_file_location('hygiene', Path(__file__).with_name('check-docslocal-hygiene.py'))
hygiene = importlib.util.module_from_spec(spec)
spec.loader.exec_module(hygiene)


def archive(source, destination):
    if source.is_symlink() or destination.is_symlink():
        raise ValueError("archive roots must not be symlinks")
    source, destination = source.resolve(), destination.resolve()
    if destination == source or source in destination.parents:
        raise ValueError('archive destination must be outside the source')
    if not source.is_dir():
        raise ValueError('receipt source does not exist')
    # Refuse an existing destination: no stale binary can survive an earlier copy.
    def ignore(directory, names):
        return [name for name in names if hygiene.excluded(Path(directory) / name)]
    shutil.copytree(source, destination, ignore=ignore, symlinks=False)


if __name__ == '__main__':
    archive(Path(sys.argv[1]), Path(sys.argv[2]))
