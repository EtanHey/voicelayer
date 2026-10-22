# Writers reject unsafe overrides; readers may still inspect older artifacts.
# Resolve symlinks and '..' so a lexical .noindex component cannot hide an escape.
require_noindex_path() {
    python3 - "$1" <<'PYNOINDEX'
import pathlib, sys
path = pathlib.Path(sys.argv[1]).resolve()
if any(part.casefold() == 'docs.local' for part in path.parts):
    sys.exit('ERROR: docs.local holds only small receipts, never build output: ' + str(path))
if not (path.parts[:2] == ('/', 'Applications') or
        any(part.endswith('.noindex') for part in path.parts[1:])):
    sys.exit('ERROR: output must be under /Applications/ or a *.noindex directory: ' + str(path))
PYNOINDEX
}

# Release artifacts never use the /Applications install-path exception.
# An optional version directory also bounds resolved child destinations.
require_release_artifact_path() {
    require_noindex_path "$1" || return
    python3 - "$@" <<'PYRELEASE'
import pathlib, sys
path = pathlib.Path(sys.argv[1]).resolve()
def identity(p):
    try:
        info = p.stat()
        return info.st_dev, info.st_ino
    except FileNotFoundError:
        return None
applications = identity(pathlib.Path('/Applications'))
if (tuple(part.casefold() for part in path.parts[:2]) == ('/', 'applications')
        or tuple(part.casefold() for part in path.parts[:5]) == ('/', 'system', 'volumes', 'data', 'applications')
        or (applications is not None and any(identity(p) == applications for p in (path, *path.parents)))):
    sys.exit('ERROR: release artifacts must not be under /Applications: ' + str(path))
if len(sys.argv) > 2:
    parent = pathlib.Path(sys.argv[2]).resolve()
    if parent not in path.parents:
        sys.exit('ERROR: release artifact must stay inside version directory ' + str(parent) + ': ' + str(path))
PYRELEASE
}

# Rollback copies are persistent user data, not regenerable build output.
require_non_docslocal_path() {
    python3 - "$1" <<'PYBACKUP'
import pathlib, sys
path = pathlib.Path(sys.argv[1]).resolve()
if any(part.casefold() == 'docs.local' for part in path.parts):
    sys.exit('ERROR: docs.local holds only small receipts, never rollback backups: ' + str(path))
PYBACKUP
}


# Apple's system Python can be too old for descriptor-relative rmtree.
release_artifact_python() {
    local candidate
    for candidate in "$(command -v python3)" /opt/homebrew/bin/python3 /usr/local/bin/python3; do
        if [[ -x "$candidate" ]] && "$candidate" -c 'import sys; sys.exit(sys.version_info < (3, 11))'; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    echo 'ERROR: release artifacts require Python 3.11 or newer' >&2
    return 1
}
