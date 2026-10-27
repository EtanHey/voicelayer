#!/bin/bash
set -euo pipefail

ROOT="$HOME/Gits"
DRY_RUN=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=true; shift ;;
    --root) ROOT="${2:?--root needs a directory}"; shift 2 ;;
    *) echo "Usage: $0 [--dry-run] [--root DIRECTORY]" >&2; exit 1 ;;
  esac
done
python3 - "$ROOT" "$DRY_RUN" <<'PYTHON'
import json
import os
import pathlib
import shutil
import sys
import tempfile

root, dry = sys.argv[1:]
def resolve_command(name):
    stable = [f'/opt/homebrew/bin/{name}', str(pathlib.Path.home() / '.bun/bin' / name)]
    candidates = stable + [shutil.which(name)] if name == 'bun' else [shutil.which(name)] + stable
    return next((os.path.abspath(p) for p in candidates if p and '/Cellar/' not in os.path.abspath(p) and os.path.isfile(p) and os.access(p, os.X_OK)), None)

bridge = resolve_command('voicelayer-mcp-bridge')
bun = resolve_command('bun')
socat = resolve_command('socat')
if bridge and bun:
    command, args = bun, [bridge]
elif socat:
    command, args = socat, ['STDIO', 'UNIX-CONNECT:/tmp/voicelayer-mcp.sock']
else:
    print('ERROR: neither bridge with bun nor socat is available; no files changed.', file=sys.stderr)
    sys.exit(1)
print(f'Transport: {command} {json.dumps(args, ensure_ascii=False)}')
errors = 0
root = pathlib.Path(root)
files = sorted(set(root.glob('*/.mcp.json')) | ({root / '.mcp.json'} if (root / '.mcp.json').is_file() else set()))
for file in files:
    try:
        data = json.loads(file.read_text(encoding='utf-8'))
        changed = False
        for name, server in data.get('mcpServers', {}).items():
            old_command = pathlib.Path(server.get('command', '')).name
            old_args = server.get('args', [])
            on_bridge = old_command == 'voicelayer-mcp-bridge' or (old_command == 'bun' and any(pathlib.Path(arg).name in ('mcp-bridge.ts', 'voicelayer-mcp-bridge') for arg in old_args))
            voice_socat = old_command == 'socat' and 'UNIX-CONNECT:/tmp/voicelayer-mcp.sock' in old_args
            if not on_bridge and old_command != 'voicelayer-mcp' and not voice_socat:
                continue
            if on_bridge and not (bridge and bun):
                continue
            updated = dict(server, command=command, args=args)
            if updated != server:
                data['mcpServers'][name] = updated
                changed = True
        if changed:
            print(f'{"Would migrate" if dry == "true" else "Migrated"}: {file}')
            if dry != 'true':
                backup = file.with_name(file.name + '.bak')
                if not backup.exists():
                    shutil.copy2(file, backup)
                temporary = None
                try:
                    with tempfile.NamedTemporaryFile(mode='w', encoding='utf-8', dir=file.parent, prefix='.mcp-', delete=False) as output:
                        temporary = output.name
                        output.write(json.dumps(data, indent=2, ensure_ascii=False) + '\n')
                        output.flush()
                        os.fsync(output.fileno())
                    os.chmod(temporary, file.stat().st_mode)
                    os.replace(temporary, file)
                    temporary = None
                finally:
                    if temporary is not None:
                        os.unlink(temporary)
    except (OSError, ValueError, TypeError, AttributeError) as exc:
        print(f'FAILED: {file}: {exc}', file=sys.stderr)
        errors += 1
sys.exit(1 if errors else 0)
PYTHON
