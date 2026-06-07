#!/usr/bin/env bash
set -euo pipefail

# Away-window only sweep for the INSTALLED /Applications VoiceBar.app.
# This script intentionally touches the resident app and LaunchAgent, so it
# refuses to run unless voicebarUI-LEAD explicitly opens a window.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FLOW_BAR_DIR="$ROOT_DIR/flow-bar"
OUT_DIR="${V5_INSTALLED_SWEEP_OUT_DIR:-$ROOT_DIR/.verified/voicebar-v5/installed-window-sweep}"
APP_PATH="/Applications/VoiceBar.app"
VOICEBAR_SOCKET_PATH="${VOICEBAR_SOCKET_PATH:-/tmp/voicelayer.sock}"
EXPECTED_REALFLOW_TRANSCRIPT="Run the tests and commit the changes"
BACKUP_PATH=""
HELPER_SWIFT=""

log() {
    printf '[v5-installed-sweep] %s\n' "$*"
}

die() {
    printf '[v5-installed-sweep] ERROR: %s\n' "$*" >&2
    exit 1
}

cleanup() {
    set +e
    if [ -n "$HELPER_SWIFT" ]; then
        rm -f "$HELPER_SWIFT"
    fi
}
trap cleanup EXIT INT TERM

require_window() {
    [ "${VOICEBAR_AWAY_WINDOW:-0}" = "1" ] ||
        die "refusing to touch installed app without VOICEBAR_AWAY_WINDOW=1"
    [ "${VOICEBAR_ALLOW_INSTALLED_SWEEP:-0}" = "1" ] ||
        die "refusing to install/relaunch without VOICEBAR_ALLOW_INSTALLED_SWEEP=1"
}

backup_installed_app() {
    if [ -d "$APP_PATH" ]; then
        BACKUP_PATH="/Applications/VoiceBar.backup-v5-window-$(date +%H%M%S).app"
        cp -R "$APP_PATH" "$BACKUP_PATH"
        log "backup: $BACKUP_PATH"
    else
        log "no existing $APP_PATH to back up"
    fi
}

configure_defaults() {
    log "configure_defaults: intentionally flipping resident VoiceBar to anchor=topCenter and v5IslandEnabled=true for this batch install"
    defaults write com.voicelayer.voicebar VoiceBar.anchorMode -string topCenter
    defaults write com.voicelayer.voicebar voicebar.v5IslandEnabled -bool true
    {
        printf 'VoiceBar.anchorMode=topCenter\n'
        printf 'voicebar.v5IslandEnabled=true\n'
        printf 'NOTE: this sweep intentionally flips Etan resident settings for the batch install.\n'
    } >"$OUT_DIR/configure-defaults.txt"
}

build_and_install() {
    mkdir -p "$OUT_DIR"
    VOICEBAR_FORCE_LAUNCHD_INSTALL=1 bash "$FLOW_BAR_DIR/build-app.sh"
}

launch_installed_app() {
    open -a "$APP_PATH"
    sleep 4
    pgrep -fl "/Applications/VoiceBar.app/Contents/MacOS/VoiceBar|VoiceBar.app/Contents/MacOS/VoiceBar" |
        tee "$OUT_DIR/launch-pids.txt"
}

make_helper() {
    HELPER_SWIFT="$(mktemp "${TMPDIR:-/tmp}/v5-installed-helper.XXXXXX.swift")"
    cat >"$HELPER_SWIFT" <<'SWIFT'
import AppKit
import CoreGraphics
import Foundation

let command = CommandLine.arguments.dropFirst().first ?? ""
let bounds = CGDisplayBounds(CGMainDisplayID())
let centerX = bounds.midX
let stripY = bounds.minY + 24

func post(_ type: CGEventType, at point: CGPoint) {
    let source = CGEventSource(stateID: .hidSystemState)
    CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left)?
        .post(tap: .cghidEventTap)
}

func move(_ point: CGPoint) {
    CGWarpMouseCursorPosition(point)
    CGAssociateMouseAndMouseCursorPosition(boolean_t(1))
    usleep(120_000)
}

func click(_ point: CGPoint) {
    move(point)
    post(.leftMouseDown, at: point)
    usleep(70_000)
    post(.leftMouseUp, at: point)
    usleep(260_000)
}

func drag(_ start: CGPoint, _ end: CGPoint) {
    move(start)
    post(.leftMouseDown, at: start)
    usleep(80_000)
    for step in 1...16 {
        let t = CGFloat(step) / 16
        let point = CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t)
        post(.leftMouseDragged, at: point)
        usleep(16_000)
    }
    post(.leftMouseUp, at: end)
    usleep(320_000)
}

func key(_ keyCode: CGKeyCode) {
    let source = CGEventSource(stateID: .hidSystemState)
    CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)?.post(tap: .cghidEventTap)
    usleep(70_000)
    CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)?.post(tap: .cghidEventTap)
    usleep(260_000)
}

switch command {
case "away":
    move(CGPoint(x: bounds.maxX - 24, y: bounds.maxY - 24))
case "hover":
    move(CGPoint(x: centerX + 150, y: stripY))
case "history":
    click(CGPoint(x: centerX + 132, y: stripY))
case "terms":
    click(CGPoint(x: centerX + 168, y: stripY))
case "dragdown":
    drag(CGPoint(x: centerX, y: stripY), CGPoint(x: centerX, y: stripY + 190))
case "escape":
    key(53)
case "pass-through-clicks":
    click(CGPoint(x: centerX, y: bounds.minY + 300))
    click(CGPoint(x: bounds.minX + bounds.width * 0.25, y: bounds.minY + 300))
    click(CGPoint(x: bounds.minX + bounds.width * 0.75, y: bounds.minY + 300))
default:
    fputs("unknown command: \(command)\n", stderr)
    exit(64)
}
SWIFT
}

send_socket_json() {
    local payload="$1"
    python3 - "$VOICEBAR_SOCKET_PATH" "$payload" <<'PY'
import socket
import sys
path, payload = sys.argv[1], sys.argv[2]
client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
client.settimeout(1.0)
client.connect(path)
client.sendall((payload + "\n").encode())
client.close()
PY
}

send_event() {
    send_socket_json "$1"
}

send_control() {
    local command="$1"
    local payload
    payload="$(python3 - "$command" <<'PY'
import json
import sys
print(json.dumps({"type": "control", "command": sys.argv[1]}, separators=(",", ":")))
PY
)"
    send_socket_json "$payload"
}

helper() {
    swift "$HELPER_SWIFT" "$1" >/dev/null
}

shot() {
    local name="$1"
    local path="$OUT_DIR/$name.png"
    screencapture -x "$path"
    stat -f '%N %z' "$path" | tee -a "$OUT_DIR/artifacts.txt"
}

frontmost_app() {
    osascript <<'APPLESCRIPT'
tell application "System Events"
    set frontApps to application processes whose frontmost is true
    if (count of frontApps) is 0 then return "unknown"
    set frontApp to item 1 of frontApps
    try
        set bundleID to bundle identifier of frontApp
        if bundleID is not missing value then return bundleID
    end try
    return name of frontApp
end tell
APPLESCRIPT
}

utc_now_iso() {
    python3 - <<'PY'
from datetime import datetime, timezone
print(datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"))
PY
}

wait_for_real_transcript() {
    local marker_iso="$1"
    local expected="$2"
    local output_json="$OUT_DIR/realflow-transcript-evidence.json"
    python3 - "$marker_iso" "$expected" "$output_json" <<'PY'
from __future__ import annotations

import json
import os
import plistlib
import re
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

marker_iso, expected, output_json = sys.argv[1], sys.argv[2], sys.argv[3]
deadline = time.time() + 120
home = Path.home()
prefs_path = home / "Library" / "Preferences" / "com.voicelayer.voicebar.plist"
archive_root = home / ".local" / "share" / "voicelayer" / "recordings"


def parse_iso(raw: str) -> datetime:
    if raw.endswith("Z"):
        raw = raw[:-1] + "+00:00"
    return datetime.fromisoformat(raw).astimezone(timezone.utc)


marker = parse_iso(marker_iso)


def normalize(text: str) -> str:
    text = text.lower()
    text = re.sub(r"[^a-z0-9]+", " ", text)
    return " ".join(text.split())


expected_normalized = normalize(expected)


def load_recent() -> list[str]:
    try:
        with prefs_path.open("rb") as handle:
            prefs = plistlib.load(handle)
    except Exception:
        return []
    items = prefs.get("VoiceBar.recentTranscriptions", [])
    if not isinstance(items, list):
        return []
    return [item for item in items if isinstance(item, str)]


def latest_archive_after_marker() -> dict[str, str] | None:
    if not archive_root.exists():
        return None
    latest: dict[str, str] | None = None
    latest_created: datetime | None = None
    for metadata_path in archive_root.glob("*/**/metadata.json"):
        transcript_path = metadata_path.with_name("voicelayer-transcript.txt")
        if not transcript_path.exists():
            continue
        try:
            metadata = json.loads(metadata_path.read_text())
            created_raw = str(metadata.get("created_at", ""))
            created_at = parse_iso(created_raw)
        except Exception:
            continue
        if created_at < marker:
            continue
        try:
            transcript = transcript_path.read_text().strip()
        except Exception:
            continue
        if latest_created is None or created_at > latest_created:
            latest_created = created_at
            latest = {
                "created_at": created_raw,
                "metadata_path": str(metadata_path),
                "transcript_path": str(transcript_path),
                "transcript": transcript,
            }
    return latest


last_payload: dict[str, object] = {}
while time.time() < deadline:
    recent = load_recent()
    latest_archive = latest_archive_after_marker()
    recent_top = recent[0] if recent else ""
    archive_text = latest_archive["transcript"] if latest_archive else ""
    payload = {
        "marker_iso": marker_iso,
        "expected": expected,
        "expected_normalized": expected_normalized,
        "recent_top": recent_top,
        "recent_top_normalized": normalize(recent_top),
        "latest_archive": latest_archive,
        "archive_transcript_normalized": normalize(archive_text),
    }
    last_payload = payload
    archive_matches = latest_archive is not None and normalize(archive_text) == expected_normalized
    recent_matches = normalize(recent_top) == expected_normalized
    if archive_matches and recent_matches:
        payload["status"] = "pass"
        Path(output_json).write_text(json.dumps(payload, indent=2) + "\n")
        print(json.dumps(payload))
        sys.exit(0)
    time.sleep(1)

last_payload["status"] = "fail"
Path(output_json).write_text(json.dumps(last_payload, indent=2) + "\n")
print(json.dumps(last_payload), file=sys.stderr)
sys.exit(1)
PY
}

capture_states() {
    send_event '{"type":"state","state":"idle"}'
    helper away
    sleep 1
    shot v5-installed-idle-synthetic-fullscreen

    helper hover
    sleep 1
    shot v5-installed-hover-synthetic-fullscreen

    send_event '{"type":"state","state":"recording","mode":"ptt"}'
    send_event '{"type":"audio_level","rms":0.82}'
    helper away
    sleep 1
    shot v5-installed-recording-synthetic-fullscreen

    send_event '{"type":"state","state":"transcribing"}'
    sleep 1
    shot v5-installed-transcribing-synthetic-fullscreen

    send_event '{"type":"state","state":"idle"}'
    helper hover
    helper history
    sleep 1
    shot v5-installed-history-synthetic-fullscreen
    helper escape

    helper hover
    helper terms
    sleep 1
    shot v5-installed-terms-synthetic-fullscreen
    helper escape

    helper away
    helper dragdown
    sleep 1
    shot v5-installed-grabdown-synthetic-fullscreen
    helper escape
}

hit_transparency_probe() {
    send_event '{"type":"state","state":"idle"}'
    helper away
    sleep 0.5
    local before_frontmost
    local after_frontmost
    before_frontmost="$(frontmost_app)"
    if [[ "$before_frontmost" == *"VoiceBar"* || "$before_frontmost" == "com.voicelayer.voicebar" ]]; then
        die "pass-through probe requires an app below VoiceBar to be frontmost; got $before_frontmost"
    fi
    shot v5-installed-hit-transparency-before-clicks
    helper pass-through-clicks
    sleep 0.5
    after_frontmost="$(frontmost_app)"
    {
        printf 'before_frontmost=%s\n' "$before_frontmost"
        printf 'after_frontmost=%s\n' "$after_frontmost"
        printf 'expected_island_state=idle\n'
        printf 'state_mutating_events_during_probe=none\n'
    } >"$OUT_DIR/hit-transparency-frontmost.txt"
    [ "$after_frontmost" = "$before_frontmost" ] ||
        die "pass-through probe changed frontmost app: before=$before_frontmost after=$after_frontmost"
    if [[ "$after_frontmost" == *"VoiceBar"* || "$after_frontmost" == "com.voicelayer.voicebar" ]]; then
        die "pass-through probe focused VoiceBar instead of the app below"
    fi
    shot v5-installed-hit-transparency-after-clicks
}

audio_self_test() {
    local fixture="$FLOW_BAR_DIR/Tests/VoiceBarTests/Fixtures/clean_speech.wav"
    [ -f "$fixture" ] || die "missing audio fixture: $fixture"
    local marker_iso
    marker_iso="$(utc_now_iso)"
    printf '%s\n' "$EXPECTED_REALFLOW_TRANSCRIPT" >"$OUT_DIR/realflow-expected-transcript.txt"
    printf '%s\n' "$marker_iso" >"$OUT_DIR/realflow-start-marker.txt"

    send_event '{"type":"state","state":"idle","source":"recording"}'
    sleep 0.5
    send_control start-recording
    sleep 2
    shot v5-installed-realflow-recording-before-playback
    afplay "$fixture" &
    local afplay_pid="$!"
    sleep 0.5
    shot v5-installed-realflow-recording-during-playback
    wait "$afplay_pid"
    sleep 0.4
    send_control stop-recording
    sleep 1
    shot v5-installed-realflow-transcribing-after-stop
    wait_for_real_transcript "$marker_iso" "$EXPECTED_REALFLOW_TRANSCRIPT" |
        tee "$OUT_DIR/realflow-transcript-evidence.stdout.json"
    shot v5-installed-realflow-after-transcription
}

main() {
    require_window
    backup_installed_app
    configure_defaults
    build_and_install
    launch_installed_app
    make_helper
    capture_states
    hit_transparency_probe
    audio_self_test
    log "resident app left running by design"
    log "artifacts: $OUT_DIR"
    if [ -n "$BACKUP_PATH" ]; then
        log "rollback: rm -rf '$APP_PATH' && cp -R '$BACKUP_PATH' '$APP_PATH'"
    fi
}

main "$@"
