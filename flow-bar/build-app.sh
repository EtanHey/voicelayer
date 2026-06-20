#!/usr/bin/env bash
# Build VoiceBar as a proper macOS .app bundle.
#
# Usage: bash flow-bar/build-app.sh [--install-path /Applications/VoiceBar.app] [--no-stop] [--no-relaunch]
#
# Output: /Applications/VoiceBar.app by default

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PACKAGE_DIR="$SCRIPT_DIR"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BUNDLE_DIR="$SCRIPT_DIR/bundle"
APP_DIR="/Applications/VoiceBar.app"
SIGN_IDENTITY="${VOICEBAR_CODESIGN_IDENTITY:-Apple Development: Etan Heyman (DXHB5E7P2D)}"
VOICEBAR_BACKUP_DIR="${VOICEBAR_BACKUP_DIR:-$HOME/Library/Application Support/VoiceBar/Backups}"
VOICEBAR_BUNDLE_ID="com.voicelayer.voicebar"
PLIST_BUDDY="${VOICEBAR_PLIST_BUDDY:-/usr/libexec/PlistBuddy}"
STOP_RUNNING=1
RELAUNCH_APP=1

usage() {
    cat <<'EOF'
Usage: bash flow-bar/build-app.sh [--install-path /Applications/VoiceBar.app] [--no-stop] [--no-relaunch]

Options:
  --install-path PATH  Install the built app at PATH
  --no-stop           Do not stop running com.voicelayer.voicebar instances first
  --no-relaunch       Do not relaunch the installed app after signing
EOF
}

parse_build_app_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --install-path)
                if [[ $# -lt 2 ]]; then
                    echo "[build-app] ERROR: --install-path requires a target path" >&2
                    return 2
                fi
                APP_DIR="$2"
                shift 2
                ;;
            --no-stop)
                STOP_RUNNING=0
                shift
                ;;
            --no-relaunch)
                RELAUNCH_APP=0
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                echo "[build-app] ERROR: Unknown argument: $1" >&2
                usage >&2
                return 2
                ;;
        esac
    done
}

voicebar_ps_pid_ppid() {
    if [[ -n "${VOICEBAR_TEST_PS_PID_PPID:-}" ]]; then
        printf '%s\n' "$VOICEBAR_TEST_PS_PID_PPID"
        return 0
    fi
    ps -axo pid=,ppid=
}

voicebar_process_table() {
    if [[ -n "${VOICEBAR_TEST_PROCESS_TABLE:-}" ]]; then
        printf '%s\n' "$VOICEBAR_TEST_PROCESS_TABLE"
        return 0
    fi
    ps -axo pid=,ppid=,command=
}

voicebar_bundle_pids() {
    if [[ -n "${VOICEBAR_TEST_BUNDLE_PIDS:-}" ]]; then
        printf '%s\n' "$VOICEBAR_TEST_BUNDLE_PIDS" | awk '/^[0-9]+$/ { print }'
        return 0
    fi

    local line
    local pid
    local _ppid
    local command
    local executable
    local app_dir
    local info_plist
    local bundle_id

    while IFS= read -r line || [[ -n "$line" ]]; do
        # shellcheck disable=SC2086 # Split ps columns into pid, ppid, and command.
        set -- $line
        pid="${1:-}"
        _ppid="${2:-}"
        shift 2 || true
        command="$*"
        executable="${command%% *}"

        [[ "$pid" =~ ^[0-9]+$ ]] || continue
        case "$executable" in
            */Contents/MacOS/VoiceBar)
                app_dir="${executable%/Contents/MacOS/VoiceBar}"
                info_plist="$app_dir/Contents/Info.plist"
                if [[ -f "$info_plist" ]]; then
                    bundle_id="$("$PLIST_BUDDY" -c "Print :CFBundleIdentifier" "$info_plist" 2>/dev/null || true)"
                    if [[ "$bundle_id" = "$VOICEBAR_BUNDLE_ID" ]]; then
                        printf '%s\n' "$pid"
                    fi
                fi
                ;;
        esac
    done < <(voicebar_process_table)
}

voicebar_descendant_pids() {
    local root_pids="$1"
    [[ -n "$root_pids" ]] || return 0

    voicebar_ps_pid_ppid | awk -v roots="$root_pids" '
        BEGIN {
            n = split(roots, root, /[[:space:]]+/)
            for (i = 1; i <= n; i++) {
                if (root[i] ~ /^[0-9]+$/) {
                    target[root[i]] = 1
                }
            }
        }
        $1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ {
            pid = $1
            ppid = $2
            parent[pid] = ppid
            all_pids[pid] = 1
        }
        END {
            changed = 1
            while (changed == 1) {
                changed = 0
                for (pid in all_pids) {
                    if (target[parent[pid]] == 1 && target[pid] != 1) {
                        target[pid] = 1
                        descendant[pid] = 1
                        changed = 1
                    }
                }
            }
            for (pid in descendant) {
                print pid
            }
        }
    '
}

voicebar_target_pids() {
    local roots
    local root_args
    local descendants
    roots="$(voicebar_bundle_pids | sort -n -u)"
    [[ -n "$roots" ]] || return 0
    root_args="$(printf '%s\n' "$roots" | tr '\n' ' ')"
    descendants="$(voicebar_descendant_pids "$root_args" | sort -n -u)"
    printf '%s\n%s\n' "$roots" "$descendants" | awk '/^[0-9]+$/ { print }' | sort -n -u
}

live_pids_from_list() {
    local pid
    while IFS= read -r pid || [[ -n "$pid" ]]; do
        [[ "$pid" =~ ^[0-9]+$ ]] || continue
        if kill -0 "$pid" 2>/dev/null; then
            printf '%s\n' "$pid"
        fi
    done
}

wait_for_pids_exit() {
    local pids="$1"
    local attempts="$2"
    local remaining
    local _

    for _ in $(seq 1 "$attempts"); do
        remaining="$(printf '%s\n' "$pids" | live_pids_from_list)"
        if [[ -z "$remaining" ]]; then
            return 0
        fi
        sleep 0.2
    done
    return 1
}

voicebar_send_quit_event() {
    osascript -e "tell application id \"$VOICEBAR_BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
}

signal_pids() {
    local signal="$1"
    local pids="$2"
    local pid
    while IFS= read -r pid || [[ -n "$pid" ]]; do
        [[ "$pid" =~ ^[0-9]+$ ]] || continue
        kill "-$signal" "$pid" 2>/dev/null || true
    done <<< "$pids"
}

stop_voicebar_instances() {
    local pids
    local remaining
    pids="$(voicebar_target_pids)"
    if [[ -z "$pids" ]]; then
        echo "[build-app] No running $VOICEBAR_BUNDLE_ID instances found."
        return 0
    fi

    echo "[build-app] Stopping $VOICEBAR_BUNDLE_ID process tree:"
    printf '%s\n' "$pids" | sed 's/^/[build-app]   PID /'

    voicebar_send_quit_event
    if wait_for_pids_exit "$pids" "${VOICEBAR_QUIT_WAIT_ATTEMPTS:-25}"; then
        return 0
    fi

    remaining="$(printf '%s\n' "$pids" | live_pids_from_list)"
    if [[ -n "$remaining" ]]; then
        echo "[build-app] Sending TERM to remaining VoiceBar-owned PIDs..."
        signal_pids TERM "$remaining"
    fi
    if wait_for_pids_exit "$pids" "${VOICEBAR_TERM_WAIT_ATTEMPTS:-25}"; then
        return 0
    fi

    remaining="$(printf '%s\n' "$pids" | live_pids_from_list)"
    if [[ -n "$remaining" ]]; then
        echo "[build-app] Sending KILL to stuck VoiceBar-owned PIDs..."
        signal_pids KILL "$remaining"
    fi
    if ! wait_for_pids_exit "$pids" "${VOICEBAR_KILL_WAIT_ATTEMPTS:-10}"; then
        echo "[build-app] ERROR: VoiceBar-owned PIDs did not exit:" >&2
        printf '%s\n' "$pids" | live_pids_from_list >&2
        return 1
    fi
}

count_lines() {
    awk 'NF { count++ } END { print count + 0 }'
}

wait_for_exactly_one_voicebar_instance() {
    local attempts="${VOICEBAR_LAUNCH_WAIT_ATTEMPTS:-50}"
    local pids
    local count
    local _

    for _ in $(seq 1 "$attempts"); do
        pids="$(voicebar_bundle_pids | sort -n -u)"
        count="$(printf '%s\n' "$pids" | count_lines)"
        if [[ "$count" -eq 1 ]]; then
            echo "[build-app] Running VoiceBar instance: PID $pids"
            return 0
        fi
        sleep 0.2
    done

    echo "[build-app] ERROR: expected exactly one $VOICEBAR_BUNDLE_ID instance after relaunch." >&2
    echo "[build-app] Current matching PIDs:" >&2
    voicebar_bundle_pids | sort -n -u >&2
    return 1
}

relaunch_voicebar_app() {
    echo "[build-app] Relaunching $APP_DIR..."
    open "$APP_DIR"
    wait_for_exactly_one_voicebar_instance
}

if [[ "${VOICEBAR_BUILD_APP_SOURCE_ONLY:-0}" = "1" ]]; then
    # shellcheck disable=SC2317 # The exit path is used only when executed, not sourced.
    return 0 2>/dev/null || exit 0
fi

parse_build_app_args "$@"

if [[ "$STOP_RUNNING" -eq 1 ]]; then
    stop_voicebar_instances
else
    echo "[build-app] Skipping VoiceBar stop because --no-stop was provided."
fi

echo "[build-app] Building VoiceBar (release)..."
swift build -c release --package-path "$PACKAGE_DIR"

# Find the built binary (reuses cached build, no rebuild)
BIN_DIR="$(swift build -c release --package-path "$PACKAGE_DIR" --show-bin-path)"
BINARY="$BIN_DIR/VoiceBar"
if [ ! -f "$BINARY" ]; then
    echo "[build-app] ERROR: Binary not found at $BINARY"
    exit 1
fi

# Clean stale bundle before recreating. The old production bundle is moved to a
# pruned backup dir (outside /Applications) rather than rm'd.
if [ -d "$APP_DIR" ]; then
    if [ "$APP_DIR" = "/Applications/VoiceBar.app" ]; then
        mkdir -p "$VOICEBAR_BACKUP_DIR"
        backup_path="$VOICEBAR_BACKUP_DIR/VoiceBar.backup-$(date +%Y%m%d-%H%M%S).app.zip"
        echo "[build-app] Archiving old bundle to $backup_path..."
        ditto -c -k --keepParent "$APP_DIR" "$backup_path"
        rm -rf "$APP_DIR"
        # Keep only the most recent backup; prune older ones.
        find "$VOICEBAR_BACKUP_DIR" -maxdepth 1 -name 'VoiceBar.backup-*.app.zip' -type f \
            | sort -r | sed -n '2,$p' | while IFS= read -r old_backup; do
                rm -f "$old_backup"
            done
    else
        echo "[build-app] Removing old bundle..."
        rm -rf "$APP_DIR"
    fi
fi

echo "[build-app] Creating .app bundle at $APP_DIR..."
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

require_bundle_file() {
    local rel_path="$1"
    if [ ! -f "$REPO_ROOT/$rel_path" ]; then
        echo "[build-app] ERROR: required bundle file missing: $rel_path" >&2
        exit 1
    fi
}

cp "$BUNDLE_DIR/Info.plist" "$APP_DIR/Contents/"
cp "$BINARY" "$APP_DIR/Contents/MacOS/VoiceBar"
cp -R "$REPO_ROOT/src" "$APP_DIR/Contents/Resources/"
if [ -f "$REPO_ROOT/package.json" ]; then
    cp "$REPO_ROOT/package.json" "$APP_DIR/Contents/Resources/package.json"
fi

# Bundle the Silero VAD model — recording fails at the first chunk without it
# (vad.ts findModelPath resolves models/ relative to the bundled src). Omitting
# this silently breaks recording on every rebuild.
if [ -f "$REPO_ROOT/models/silero_vad.onnx" ]; then
    cp -R "$REPO_ROOT/models" "$APP_DIR/Contents/Resources/"
    echo "[build-app] VAD model bundled."
else
    echo "[build-app] WARNING: models/silero_vad.onnx not found — recording will fail until it is present." >&2
fi

# Bundle the edge-tts synth script — ALL daemon TTS fails (edge-tts exit code 2)
# without it (tts.ts resolves ../scripts/edge-tts-words.py relative to the
# bundled src). Same silent-loss bug class as the VAD model above (#241).
if [ -f "$REPO_ROOT/scripts/edge-tts-words.py" ]; then
    mkdir -p "$APP_DIR/Contents/Resources/scripts"
    cp "$REPO_ROOT/scripts/edge-tts-words.py" "$APP_DIR/Contents/Resources/scripts/"
    echo "[build-app] edge-tts synth script bundled."
else
    echo "[build-app] WARNING: scripts/edge-tts-words.py not found — daemon TTS will fail until it is present." >&2
fi

require_bundle_file "scripts/install-voicebar-f5-hidutil.sh"
require_bundle_file "scripts/apply-voicebar-f5-hidutil.sh"
require_bundle_file "launchd/com.voicelayer.f5-to-f18-hidutil.plist"
mkdir -p "$APP_DIR/Contents/Resources/scripts"
mkdir -p "$APP_DIR/Contents/Resources/launchd"
cp "$REPO_ROOT/scripts/install-voicebar-f5-hidutil.sh" "$APP_DIR/Contents/Resources/scripts/"
cp "$REPO_ROOT/scripts/apply-voicebar-f5-hidutil.sh" "$APP_DIR/Contents/Resources/scripts/"
cp "$REPO_ROOT/launchd/com.voicelayer.f5-to-f18-hidutil.plist" "$APP_DIR/Contents/Resources/launchd/"
chmod 755 "$APP_DIR/Contents/Resources/scripts/install-voicebar-f5-hidutil.sh"
chmod 755 "$APP_DIR/Contents/Resources/scripts/apply-voicebar-f5-hidutil.sh"
echo "[build-app] F5 hidutil setup files bundled."

# App icon
if [ -f "$BUNDLE_DIR/VoiceBar.icns" ]; then
    cp "$BUNDLE_DIR/VoiceBar.icns" "$APP_DIR/Contents/Resources/"
    echo "[build-app] Icon installed."
fi

# Developer signing keeps TCC permissions stable across rebuilds. A clean TCC
# re-grant is a macOS security click if ever needed; do not reset TCC here.
echo "[build-app] Signing..."
codesign --force --deep --sign "$SIGN_IDENTITY" --timestamp=none "$APP_DIR"

echo "[build-app] Verifying signature..."
if ! codesign -dv --verbose=4 "$APP_DIR" 2>&1 | grep -F "Authority=$SIGN_IDENTITY" >/dev/null; then
    echo "[build-app] ERROR: Installed app is not signed with $SIGN_IDENTITY"
    codesign -dv --verbose=4 "$APP_DIR" 2>&1
    exit 1
fi

if [ "${VOICEBAR_SKIP_LAUNCHD_INSTALL:-0}" = "1" ]; then
    echo "[build-app] Skipping retired MCP daemon LaunchAgent cleanup."
elif [ "$APP_DIR" != "/Applications/VoiceBar.app" ]; then
    echo "[build-app] Skipping retired MCP daemon LaunchAgent cleanup."
else
    echo "[build-app] Retiring MCP daemon LaunchAgent..."
    bash "$REPO_ROOT/launchd/install.sh"
fi

if [[ "$RELAUNCH_APP" -eq 1 ]]; then
    relaunch_voicebar_app
else
    echo "[build-app] Skipping VoiceBar relaunch because --no-relaunch was provided."
fi

echo "[build-app] Done: $APP_DIR"
echo "[build-app] To add to Login Items: System Settings > General > Login Items > +"
echo "[build-app] Or run: osascript -e 'tell application \"System Events\" to make login item at end with properties {path:\"$APP_DIR\", hidden:true}'"
