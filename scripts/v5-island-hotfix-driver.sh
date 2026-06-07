#!/usr/bin/env bash
set -euo pipefail

# Scripted CGEvent interaction gate for the V5 top-center island.
# Assumes a VoiceBar build is already visible, topCenter anchored, and V5 enabled.
# It does not install, launch, quit, or modify launchd/defaults.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="${V5_HOTFIX_OUT_DIR:-$ROOT_DIR/.verified/voicebar-v5/hotfix}"
mkdir -p "$OUT_DIR"

CG_HELPER="$(mktemp "${TMPDIR:-/tmp}/v5-island-cgevent.XXXXXX.swift")"
cleanup() {
  rm -f "$CG_HELPER"
}
trap cleanup EXIT

cat >"$CG_HELPER" <<'SWIFT'
import AppKit
import CoreGraphics
import Foundation

enum Command: String {
    case moveAway
    case clickHistory
    case clickTerms
    case closeHandle
    case clickOutside
    case dragUp
    case escape
    case f5
}

func displayBounds() -> CGRect {
    CGDisplayBounds(CGMainDisplayID())
}

func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
    CGPoint(x: x, y: y)
}

func postMouse(_ type: CGEventType, at location: CGPoint) {
    let source = CGEventSource(stateID: .hidSystemState)
    let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: location, mouseButton: .left)
    event?.post(tap: .cghidEventTap)
}

func move(to location: CGPoint) {
    CGWarpMouseCursorPosition(location)
    CGAssociateMouseAndMouseCursorPosition(boolean_t(1))
    usleep(120_000)
}

func click(_ location: CGPoint) {
    move(to: location)
    postMouse(.leftMouseDown, at: location)
    usleep(60_000)
    postMouse(.leftMouseUp, at: location)
    usleep(220_000)
}

func drag(from start: CGPoint, to end: CGPoint) {
    move(to: start)
    postMouse(.leftMouseDown, at: start)
    usleep(80_000)
    let steps = 12
    for step in 1...steps {
        let t = CGFloat(step) / CGFloat(steps)
        let location = CGPoint(
            x: start.x + ((end.x - start.x) * t),
            y: start.y + ((end.y - start.y) * t)
        )
        postMouse(.leftMouseDragged, at: location)
        usleep(16_000)
    }
    postMouse(.leftMouseUp, at: end)
    usleep(260_000)
}

func key(_ code: CGKeyCode) {
    let source = CGEventSource(stateID: .hidSystemState)
    CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true)?.post(tap: .cghidEventTap)
    usleep(70_000)
    CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false)?.post(tap: .cghidEventTap)
    usleep(260_000)
}

guard CommandLine.arguments.count == 2, let command = Command(rawValue: CommandLine.arguments[1]) else {
    fputs("usage: swift helper.swift <moveAway|clickHistory|clickTerms|closeHandle|clickOutside|dragUp|escape|f5>\n", stderr)
    exit(64)
}

let bounds = displayBounds()
let centerX = bounds.midX
let stripY = bounds.minY + 24
let sheetY = bounds.minY + 110

switch command {
case .moveAway:
    move(to: point(bounds.maxX - 24, bounds.maxY - 24))
case .clickHistory:
    click(point(centerX + 132, stripY))
case .clickTerms:
    click(point(centerX + 168, stripY))
case .closeHandle:
    click(point(centerX - 122, stripY))
case .clickOutside:
    click(point(bounds.maxX - 24, bounds.maxY - 24))
case .dragUp:
    drag(from: point(centerX, sheetY), to: point(centerX, stripY))
case .escape:
    key(53)
case .f5:
    key(96)
}
SWIFT

run_cg() {
  swift "$CG_HELPER" "$1" >/dev/null
}

shot() {
  local name="$1"
  screencapture -x "$OUT_DIR/$name.png"
  local bytes
  bytes="$(stat -f%z "$OUT_DIR/$name.png")"
  printf '[v5-driver] %s %s bytes\n' "$name.png" "$bytes"
}

cycle_close_path() {
  local path="$1"
  run_cg moveAway
  run_cg clickHistory
  sleep 0.5
  shot "v5-hotfix-${path}-open"
  case "$path" in
    island-tap) run_cg closeHandle ;;
    escape) run_cg escape ;;
    click-outside) run_cg clickOutside ;;
    drag-up) run_cg dragUp ;;
    record-start) run_cg f5 ;;
    *) printf 'unknown close path: %s\n' "$path" >&2; return 64 ;;
  esac
  sleep 0.7
  shot "v5-hotfix-${path}-closed"
  if [ "$path" = "record-start" ]; then
    run_cg f5
    sleep 0.7
  fi
}

cycle_close_path island-tap
cycle_close_path escape
cycle_close_path click-outside
cycle_close_path drag-up
cycle_close_path record-start

run_cg moveAway
run_cg clickTerms
sleep 0.5
shot "v5-hotfix-terms-card-stack"
run_cg escape
sleep 0.4
run_cg moveAway

printf '[v5-driver] artifacts: %s\n' "$OUT_DIR"
