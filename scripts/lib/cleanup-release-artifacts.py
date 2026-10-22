"""Remove release artifacts through verified, non-following directory handles."""
import os
from pathlib import Path
import shutil
import stat
import sys
from contextlib import ExitStack


def identity(info):
    return info.st_dev, info.st_ino


def cleanup(version, artifacts):
    if not (getattr(shutil, '_use_fd_functions', False)
            and getattr(shutil.rmtree, 'avoids_symlink_attacks', False)):
        raise ValueError('Python lacks symlink-safe descriptor-relative rmtree')
    # Inputs were resolved by the caller. Do not resolve again and bless a swap.
    paths = [Path(version), *(Path(item) for item in artifacts)]
    for path in paths:
        if (not path.is_absolute() or '..' in path.parts
                or any(p.casefold() == 'docs.local' for p in path.parts)
                or path.parts[1].casefold() == 'applications'
                or not any(p.endswith('.noindex') for p in path.parts[1:-1])):
            raise ValueError('unsafe release artifact path: ' + str(path))
    version_path = paths[0]
    for path in paths[1:]:
        if version_path not in path.parents:
            raise ValueError('artifact escapes version directory: ' + str(path))

    with ExitStack() as stack:
        flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW

        def open_directory(name, parent_fd=None):
            # Compare the validated entry to the actual opened inode, not a
            # second path resolution. Both operations refuse symlink entries.
            before = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
            if not stat.S_ISDIR(before.st_mode):
                raise ValueError('release directory is not a real directory: ' + str(name))
            fd = os.open(name, flags, dir_fd=parent_fd)
            stack.callback(os.close, fd)
            if identity(before) != identity(os.fstat(fd)):
                raise ValueError('release directory changed during validation: ' + str(name))
            return fd

        # Anchor every ancestor, including the resolved .noindex root. No
        # replaceable absolute ancestor is traversed by a deletion syscall.
        fd = open_directory('/')
        for part in version_path.parts[1:]:
            fd = open_directory(part, fd)
        version_fd = fd
        for path in paths[1:]:
            parts = path.relative_to(version_path).parts
            parent_fd = version_fd
            for part in parts[:-1]:
                parent_fd = open_directory(part, parent_fd)
            name = parts[-1]
            try:
                info = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
            except FileNotFoundError:
                continue
            if stat.S_ISDIR(info.st_mode):
                shutil.rmtree(name, dir_fd=parent_fd)
            else:
                os.unlink(name, dir_fd=parent_fd)


if __name__ == '__main__':
    try:
        if len(sys.argv) != 4:
            raise ValueError('expected version directory, app and zip')
        cleanup(sys.argv[1], sys.argv[2:])
    except (OSError, ValueError, NotImplementedError, TypeError) as error:
        sys.exit('ERROR: release cleanup refused: ' + str(error))
