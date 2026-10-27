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
BRIDGE="$(command -v voicelayer-mcp-bridge || true)"
python3 - "$ROOT" "$BRIDGE" "$DRY_RUN" <<'PY'
import json
import pathlib
import shutil
import sys

root, bridge, dry = sys.argv[1:]
command = bridge or 'socat'
print(f'Transport: {command}' + (' (fallback: bridge binary missing)' if not bridge else ''))
errors = 0
for file in sorted(pathlib.Path(root).glob('*/.mcp.json')):
    try:
        data = json.loads(file.read_text())
        changed = False
        for name, server in data.get('mcpServers', {}).items():
            old_command = pathlib.Path(server.get('command', '')).name
            voice_socat = old_command == 'socat' and 'UNIX-CONNECT:/tmp/voicelayer-mcp.sock' in server.get('args', [])
            if old_command not in ('voicelayer-mcp', 'voicelayer-mcp-bridge') and not voice_socat:
                continue
            updated = dict(server, command=command)
            updated.pop('args', None)
            if not bridge:
                updated['args'] = ['STDIO', 'UNIX-CONNECT:/tmp/voicelayer-mcp.sock']
            if updated != server:
                data['mcpServers'][name] = updated
                changed = True
        if changed:
            print(f'{"Would migrate" if dry == "true" else "Migrated"}: {file}')
            if dry != 'true':
                backup = file.with_name(file.name + '.bak')
                if not backup.exists():
                    shutil.copy2(file, backup)
                file.write_text(json.dumps(data, indent=2) + '\n')
    except (OSError, ValueError, TypeError, AttributeError) as exc:
        print(f'FAILED: {file}: {exc}', file=sys.stderr)
        errors += 1
sys.exit(1 if errors else 0)
PY
