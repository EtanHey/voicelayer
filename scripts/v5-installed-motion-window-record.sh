#!/usr/bin/env bash
set -euo pipefail

# Away-window only motion capture for the INSTALLED /Applications VoiceBar.app.
# Does not build, install, or relaunch. It records the resident app's motion
# only when voicebarUI-LEAD explicitly opens a window.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="${V5_MOTION_OUT_DIR:-$ROOT_DIR/.verified/voicebar-v5/lane-c}"
HELPER_SWIFT=""

log() {
    printf '[v5-motion] %s\n' "$*"
}

die() {
    printf '[v5-motion] ERROR: %s\n' "$*" >&2
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
        die "refusing to drive installed app without VOICEBAR_AWAY_WINDOW=1"
    [ "${VOICEBAR_ALLOW_MOTION_RECORDING:-0}" = "1" ] ||
        die "refusing motion recording without VOICEBAR_ALLOW_MOTION_RECORDING=1"
}

verify_resident_v5() {
    local anchor
    local v5_enabled
    anchor="$(defaults read com.voicelayer.voicebar VoiceBar.anchorMode 2>/dev/null || true)"
    v5_enabled="$(defaults read com.voicelayer.voicebar voicebar.v5IslandEnabled 2>/dev/null || true)"
    {
        printf 'VoiceBar.anchorMode=%s\n' "$anchor"
        printf 'voicebar.v5IslandEnabled=%s\n' "$v5_enabled"
        if [ -f /tmp/voicebar-v5-surface-diagnostic.txt ]; then
            printf '\n/tmp/voicebar-v5-surface-diagnostic.txt:\n'
            cat /tmp/voicebar-v5-surface-diagnostic.txt
        fi
    } >"$OUT_DIR/preflight.txt"
    [ "$anchor" = "topCenter" ] || die "resident anchor is not topCenter: $anchor"
    [ "$v5_enabled" = "1" ] || [ "$v5_enabled" = "true" ] ||
        die "resident v5 flag is not enabled: $v5_enabled"
    pgrep -fl "/Applications/VoiceBar.app/Contents/MacOS/VoiceBar" >"$OUT_DIR/voicebar-pids.txt" ||
        die "installed VoiceBar process is not running"
    if [ -f /tmp/voicebar-v5-surface-diagnostic.txt ]; then
        grep -F "surfaceStyle=v5Island" /tmp/voicebar-v5-surface-diagnostic.txt >/dev/null ||
            die "runtime diagnostic does not show surfaceStyle=v5Island"
    fi
}

make_helper() {
    HELPER_SWIFT="$(mktemp "${TMPDIR:-/tmp}/v5-motion-helper.XXXXXX.swift")"
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

func move(_ point: CGPoint, pause: useconds_t = 70_000) {
    CGWarpMouseCursorPosition(point)
    CGAssociateMouseAndMouseCursorPosition(boolean_t(1))
    usleep(pause)
}

func glide(_ start: CGPoint, _ end: CGPoint, steps: Int, frameDelay: useconds_t) {
    move(start, pause: 120_000)
    for step in 1...steps {
        let t = CGFloat(step) / CGFloat(steps)
        move(
            CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t),
            pause: frameDelay
        )
    }
}

func click(_ point: CGPoint) {
    move(point, pause: 120_000)
    post(.leftMouseDown, at: point)
    usleep(70_000)
    post(.leftMouseUp, at: point)
    usleep(260_000)
}

func drag(_ start: CGPoint, _ end: CGPoint, steps: Int) {
    move(start, pause: 140_000)
    post(.leftMouseDown, at: start)
    usleep(90_000)
    for step in 1...steps {
        let t = CGFloat(step) / CGFloat(steps)
        let point = CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t)
        post(.leftMouseDragged, at: point)
        usleep(16_000)
    }
    post(.leftMouseUp, at: end)
    usleep(350_000)
}

func key(_ keyCode: CGKeyCode) {
    let source = CGEventSource(stateID: .hidSystemState)
    CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)?.post(tap: .cghidEventTap)
    usleep(70_000)
    CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)?.post(tap: .cghidEventTap)
    usleep(260_000)
}

switch command {
case "park":
    move(CGPoint(x: bounds.maxX - 24, y: bounds.maxY - 24), pause: 180_000)
case "hover-slide":
    glide(
        CGPoint(x: centerX + 420, y: stripY + 110),
        CGPoint(x: centerX + 156, y: stripY),
        steps: 42,
        frameDelay: 16_000
    )
    usleep(550_000)
    glide(
        CGPoint(x: centerX + 156, y: stripY),
        CGPoint(x: centerX + 420, y: stripY + 110),
        steps: 42,
        frameDelay: 16_000
    )
case "grab-down":
    drag(CGPoint(x: centerX, y: stripY), CGPoint(x: centerX, y: stripY + 230), steps: 44)
    usleep(700_000)
    key(53)
case "history-morph":
    glide(
        CGPoint(x: centerX + 420, y: stripY + 110),
        CGPoint(x: centerX + 150, y: stripY),
        steps: 28,
        frameDelay: 16_000
    )
    click(CGPoint(x: centerX + 132, y: stripY))
    usleep(900_000)
    key(53)
case "terms-morph":
    glide(
        CGPoint(x: centerX + 420, y: stripY + 110),
        CGPoint(x: centerX + 150, y: stripY),
        steps: 28,
        frameDelay: 16_000
    )
    click(CGPoint(x: centerX + 168, y: stripY))
    usleep(900_000)
    key(53)
default:
    fputs("unknown command: \(command)\n", stderr)
    exit(64)
}
SWIFT
}

helper() {
    swift "$HELPER_SWIFT" "$1" >/dev/null
}

record_motion() {
    local name="$1"
    local command="$2"
    local seconds="${3:-8}"
    local path="$OUT_DIR/$name.mov"
    helper park
    screencapture -v -V "$seconds" "$path" &
    local recorder_pid="$!"
    sleep 1
    helper "$command"
    wait "$recorder_pid"
    stat -f '%N %z' "$path" | tee -a "$OUT_DIR/artifacts.txt"
}

main() {
    require_window
    mkdir -p "$OUT_DIR"
    verify_resident_v5
    make_helper
    record_motion "v5-lane-c-hover-slide-60fps-installed" "hover-slide" 8
    record_motion "v5-lane-c-grab-down-track-60fps-installed" "grab-down" 9
    record_motion "v5-lane-c-history-sheet-morph-60fps-installed" "history-morph" 8
    record_motion "v5-lane-c-terms-sheet-morph-60fps-installed" "terms-morph" 8
    log "motion artifacts: $OUT_DIR"
}

main "$@"
