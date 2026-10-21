# Writers reject unsafe overrides; readers may still inspect older artifacts.
# Resolve symlinks and '..' so a lexical .noindex component cannot hide an escape.
require_noindex_path() {
    python3 - "$1" <<'PYNOINDEX'
import pathlib, sys
path = pathlib.Path(sys.argv[1]).resolve()
if 'docs.local' in path.parts:
    sys.exit('ERROR: docs.local holds only small receipts, never build output: ' + str(path))
if not (path.parts[:2] == ('/', 'Applications') or
        any(part.endswith('.noindex') for part in path.parts[1:])):
    sys.exit('ERROR: output must be under /Applications/ or a *.noindex directory: ' + str(path))
PYNOINDEX
}
