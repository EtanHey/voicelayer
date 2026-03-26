#!/bin/bash
# Migrate all .mcp.json files from voicelayer-mcp spawn to socat daemon.
#
# Before: "voicelayer": { "command": "voicelayer-mcp" }
# After:  "voicelayer": { "command": "socat", "args": ["STDIO", "UNIX-CONNECT:/tmp/voicelayer-mcp.sock"] }
#
# Prerequisites:
#   - Daemon running: launchctl list | grep voicelayer
#   - socat installed: which socat
#   - Socket exists: ls /tmp/voicelayer-mcp.sock
#
# Usage: bash scripts/migrate-to-daemon.sh [--dry-run]

set -euo pipefail

DRY_RUN=false
if [[ "${1:-}" == "--dry-run" ]]; then
  DRY_RUN=true
  echo "=== DRY RUN — no files will be modified ==="
fi

# Verify prerequisites
if ! command -v socat &>/dev/null; then
  echo "ERROR: socat not installed. Run: brew install socat"
  exit 1
fi

if [[ ! -S /tmp/voicelayer-mcp.sock ]]; then
  echo "ERROR: Daemon socket not found at /tmp/voicelayer-mcp.sock"
  echo "Start daemon: launchctl load ~/Library/LaunchAgents/com.voicelayer.mcp-daemon.plist"
  exit 1
fi

MIGRATED=0
SKIPPED=0
ERRORS=0

# Find all .mcp.json files under ~/Gits that reference voicelayer-mcp
while IFS= read -r file; do
  if grep -q '"voicelayer-mcp"' "$file" 2>/dev/null; then
    repo_name=$(basename "$(dirname "$file")")

    if $DRY_RUN; then
      echo "  [dry-run] Would migrate: $file ($repo_name)"
      ((MIGRATED++))
      continue
    fi

    # Create backup
    cp "$file" "${file}.bak"

    # Use python3 for reliable JSON manipulation
    if python3 -c "
import json, sys
with open('$file') as f:
    data = json.load(f)
servers = data.get('mcpServers', {})
if 'voicelayer' in servers:
    servers['voicelayer'] = {
        'command': 'socat',
        'args': ['STDIO', 'UNIX-CONNECT:/tmp/voicelayer-mcp.sock']
    }
with open('$file', 'w') as f:
    json.dump(data, f, indent=2)
    f.write('\n')
" 2>/dev/null; then
      echo "  ✓ Migrated: $file ($repo_name)"
      ((MIGRATED++))
    else
      echo "  ✗ FAILED: $file ($repo_name)"
      # Restore backup
      mv "${file}.bak" "$file"
      ((ERRORS++))
    fi
  else
    ((SKIPPED++))
  fi
done < <(find ~/Gits -maxdepth 2 -name ".mcp.json" -type f 2>/dev/null)

echo ""
echo "=== Migration complete ==="
echo "  Migrated: $MIGRATED"
echo "  Skipped:  $SKIPPED (already using socat or no voicelayer entry)"
echo "  Errors:   $ERRORS"

if [[ $ERRORS -gt 0 ]]; then
  echo ""
  echo "Some migrations failed. Check the files above and migrate manually."
  exit 1
fi

if ! $DRY_RUN && [[ $MIGRATED -gt 0 ]]; then
  echo ""
  echo "Backups saved as .mcp.json.bak — delete after verifying."
  echo ""
  echo "To verify: restart Claude Code in any migrated repo and run:"
  echo '  voice_speak("Migration test")'
fi
