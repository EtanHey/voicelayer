#!/usr/bin/env bash
# Collapse a machine down to exactly ONE canonical VoiceBar.app.
#
# Why this exists: over time a Mac can accumulate many VoiceBar copies — old
# dev builds in worktrees/tmp, an Apple-Development build, the Homebrew cask, and
# several running processes/LaunchAgents respawning them. Only ONE of them holds
# the macOS TCC grants (Microphone / Accessibility / Input Monitoring). This
# script finds every copy, identifies the Developer-ID canonical one, quits the
# strays, backs up (never hard-deletes) the stray bundles, removes stray
# LaunchAgents/login-items, and pins a single /Applications/VoiceBar.app + single
# com.voicelayer.voicebar LaunchAgent.
#
# TCC note: TCC grants for a Developer-ID app are keyed to the designated
# requirement (cert + Team ID PPN23G925Y), so once the canonical Developer-ID app
# is granted, future `brew upgrade` / `voicelayer update` rebuilds keep the grant.
# This is why "approve once, then permanent" works.
#
# SAFE BY DEFAULT: runs in inventory/dry-run mode and changes nothing unless you
# pass --apply. Even with --apply, stray bundles are MOVED to a timestamped
# backup dir, not deleted.
set -euo pipefail

CANONICAL_APP="/Applications/VoiceBar.app"
BUNDLE_ID="com.voicelayer.voicebar"
REQUIRED_TEAM_ID="${VOICEBAR_REQUIRED_TEAM_ID:-PPN23G925Y}"
REQUIRED_AUTHORITY_PREFIX="Developer ID Application"
LABEL="com.voicelayer.voicebar"
HOME_DIR="${HOME:?HOME is required}"
BACKUP_DIR="$HOME_DIR/.voicelayer/voicebar-dedupe-backup"

APPLY=0
for arg in "$@"; do
  case "$arg" in
    --apply) APPLY=1 ;;
    --dry-run) APPLY=0 ;;
    -h|--help)
      cat <<EOF
Usage: voicelayer-dedupe-voicebar.sh [--dry-run|--apply]

  --dry-run   (default) inventory only; print what WOULD change, change nothing.
  --apply     perform the cleanup. Stray bundles are moved to:
              $BACKUP_DIR/<timestamp>/  (not deleted).

Keeps exactly one canonical Developer-ID (Team $REQUIRED_TEAM_ID) VoiceBar at
$CANONICAL_APP, plus one $LABEL LaunchAgent.
EOF
      exit 0 ;;
    *) echo "Unknown arg: $arg" >&2; exit 2 ;;
  esac
done

log()  { printf '%s\n' "$*"; }
sect() { printf '\n==== %s ====\n' "$*"; }
run()  { # run a mutating command, or just print it in dry-run
  if [[ "$APPLY" -eq 1 ]]; then
    log "  + $*"; "$@"
  else
    log "  (dry-run) would run: $*"
  fi
}

# --- codesign helpers -------------------------------------------------------
app_authority() { codesign -dvvv "$1" 2>&1 | awk -F= '/^Authority=/{print $2; exit}'; }
app_teamid()    { codesign -dvvv "$1" 2>&1 | awk -F= '/^TeamIdentifier=/{print $2; exit}'; }
app_bundleid()  { defaults read "$1/Contents/Info" CFBundleIdentifier 2>/dev/null || echo "?"; }

is_canonical_signature() { # $1 = app path -> 0 if Developer-ID + required team
  local auth team
  auth="$(app_authority "$1")"; team="$(app_teamid "$1")"
  [[ "$auth" == "$REQUIRED_AUTHORITY_PREFIX"* && "$team" == "$REQUIRED_TEAM_ID" ]]
}

# --- 1. discover every VoiceBar.app bundle ---------------------------------
sect "1. VoiceBar.app bundles on this machine"
declare -a BUNDLES=()
{
  # Spotlight-indexed copies (by bundle id, robust to renames)
  mdfind "kMDItemCFBundleIdentifier == '$BUNDLE_ID'" 2>/dev/null || true
  # Common non-indexed locations (tmp/worktrees/build dirs often excluded from Spotlight)
  find /Applications "$HOME_DIR/Applications" "$HOME_DIR/Gits" "$HOME_DIR/Desktop" \
       "$HOME_DIR/Downloads" /tmp /private/tmp /var/folders \
       -maxdepth 6 -name 'VoiceBar.app' -type d -prune 2>/dev/null || true
} | sort -u > /tmp/.vb-bundles.$$
while IFS= read -r b; do [[ -d "$b" ]] && BUNDLES+=("$b"); done < /tmp/.vb-bundles.$$
rm -f /tmp/.vb-bundles.$$

if [[ "${#BUNDLES[@]}" -eq 0 ]]; then
  log "No VoiceBar.app bundles found."
else
  for b in "${BUNDLES[@]}"; do
    sig="STRAY (non-Developer-ID)"; is_canonical_signature "$b" && sig="developer-id OK (team $(app_teamid "$b"))"
    printf '  %-55s  bundle=%s  auth=%q  -> %s\n' "$b" "$(app_bundleid "$b")" "$(app_authority "$b")" "$sig"
  done
fi

# --- 2. discover running VoiceBar processes --------------------------------
sect "2. Running VoiceBar processes (exec instances)"
PROC_LINES="$(pgrep -afl 'VoiceBar' 2>/dev/null | grep -v 'dedupe-voicebar' || true)"
if [[ -z "$PROC_LINES" ]]; then log "  none"; else printf '%s\n' "$PROC_LINES" | sed 's/^/  /'; fi

# --- 3. discover LaunchAgents/Daemons referencing VoiceBar -----------------
sect "3. LaunchAgents / LaunchDaemons referencing VoiceBar"
declare -a AGENT_FILES=()
while IFS= read -r f; do [[ -n "$f" ]] && AGENT_FILES+=("$f"); done < <(
  grep -rlE 'VoiceBar|voicelayer\.voicebar' \
    "$HOME_DIR/Library/LaunchAgents" /Library/LaunchAgents /Library/LaunchDaemons 2>/dev/null | sort -u || true
)
if [[ "${#AGENT_FILES[@]}" -eq 0 ]]; then
  log "  none"
else
  for f in "${AGENT_FILES[@]}"; do
    tgt="$(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments:0' "$f" 2>/dev/null || echo '?')"
    printf '  %s\n      -> %s\n' "$f" "$tgt"
  done
fi

# --- 4. login items referencing VoiceBar -----------------------------------
sect "4. Login items referencing VoiceBar"
LOGIN_ITEMS="$(osascript -e 'tell application "System Events" to get the name of every login item' 2>/dev/null | tr ',' '\n' | grep -i 'voicebar' | sed 's/^ *//' || true)"
if [[ -z "$LOGIN_ITEMS" ]]; then log "  none"; else printf '%s\n' "$LOGIN_ITEMS" | sed 's/^/  /'; fi

# --- 5. choose the canonical bundle ----------------------------------------
sect "5. Decision"
CANON_SOURCE=""
if [[ -d "$CANONICAL_APP" ]] && is_canonical_signature "$CANONICAL_APP"; then
  CANON_SOURCE="$CANONICAL_APP"
  log "  Canonical already in place and Developer-ID: $CANONICAL_APP"
else
  for b in "${BUNDLES[@]:-}"; do
    [[ -n "$b" ]] || continue
    if is_canonical_signature "$b"; then CANON_SOURCE="$b"; break; fi
  done
  if [[ -n "$CANON_SOURCE" ]]; then
    log "  Developer-ID build found at: $CANON_SOURCE"
    log "  Will install it as: $CANONICAL_APP"
  else
    log "  !! No Developer-ID (Team $REQUIRED_TEAM_ID) VoiceBar found on this machine."
    log "  !! Cannot safely pick a canonical app. Install the cask first:"
    log "       brew install --cask etanhey/layers/voicebar"
    log "     then re-run with --apply."
    exit 1
  fi
fi

# --- 6. apply: quit, prune agents, pin canonical, back up strays -----------
sect "6. Plan / Apply  (mode: $([[ $APPLY -eq 1 ]] && echo APPLY || echo DRY-RUN))"
STAMP="$(date +%Y%m%d-%H%M%S)"
DEST_BACKUP="$BACKUP_DIR/$STAMP"

# 6a. Quit every running VoiceBar instance (graceful, then force)
log "-- quit running VoiceBar instances"
run osascript -e 'tell application "VoiceBar" to quit' || true
run pkill -x VoiceBar || true

# 6b. Bootout + back up stray LaunchAgents that don't point at the canonical app
log "-- prune stray LaunchAgents (keep only $LABEL -> $CANONICAL_APP)"
for f in "${AGENT_FILES[@]:-}"; do
  [[ -n "$f" ]] || continue
  base="$(basename "$f")"
  tgt="$(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments:0' "$f" 2>/dev/null || echo '')"
  if [[ "$base" == "$LABEL.plist" && "$tgt" == "$CANONICAL_APP/Contents/MacOS/VoiceBar" ]]; then
    log "  keep: $f"
    continue
  fi
  log "  prune: $f (target=$tgt)"
  run launchctl bootout "gui/$(id -u)/${base%.plist}" || true
  run mkdir -p "$DEST_BACKUP/LaunchAgents"
  run mv "$f" "$DEST_BACKUP/LaunchAgents/" || true
done

# 6c. Install / move the canonical app into place
if [[ "$CANON_SOURCE" != "$CANONICAL_APP" ]]; then
  log "-- install canonical app to $CANONICAL_APP"
  if [[ -d "$CANONICAL_APP" ]]; then
    run mkdir -p "$DEST_BACKUP/Applications"
    run mv "$CANONICAL_APP" "$DEST_BACKUP/Applications/VoiceBar.app.was-$STAMP"
  fi
  run cp -R "$CANON_SOURCE" "$CANONICAL_APP"
fi

# 6d. Back up every OTHER bundle (anything that isn't the canonical path)
log "-- back up stray bundles"
for b in "${BUNDLES[@]:-}"; do
  [[ -n "$b" ]] || continue
  [[ "$b" == "$CANONICAL_APP" ]] && continue
  [[ "$b" == "$CANON_SOURCE" ]] && { log "  (was source, now copied to canonical; backing up original) $b"; }
  run mkdir -p "$DEST_BACKUP/bundles"
  run mv "$b" "$DEST_BACKUP/bundles/$(echo "$b" | tr '/ ' '__')" || true
done

# 6e. Reinstall the single canonical LaunchAgent (idempotent installer)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$SCRIPT_DIR/../launchd/install.sh" ]]; then
  log "-- (re)install canonical LaunchAgent via launchd/install.sh"
  run bash "$SCRIPT_DIR/../launchd/install.sh" || true
else
  log "-- launchd/install.sh not found next to script; skipping agent reinstall"
fi

sect "7. Result"
if [[ "$APPLY" -eq 1 ]]; then
  log "Backups (if any) in: $DEST_BACKUP"
  log "Remaining bundles:"; mdfind "kMDItemCFBundleIdentifier == '$BUNDLE_ID'" 2>/dev/null | sed 's/^/  /' || true
  ls -d "$CANONICAL_APP" >/dev/null 2>&1 && log "Canonical present: $CANONICAL_APP"
  log "Running:"; pgrep -afl VoiceBar | grep -v dedupe-voicebar | sed 's/^/  /' || log "  (none yet — relaunch with: open $CANONICAL_APP)"
else
  log "DRY-RUN complete. Re-run with --apply to execute. Nothing was changed."
fi
