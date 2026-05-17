# VoiceBar Hotkeys and Mouse Buttons

Status: current as of 2026-05-17.

This document records the known-good VoiceBar hotkey setup. Read it before changing
Karabiner, `hidutil`, or `HotkeyManager.swift`.

## Current Mapping

| Input | Owner | Behavior |
|-------|-------|----------|
| F5 / internal F18 relay | VoiceBar `CGEventTap` | Push-to-talk recording and double-tap lock |
| Shift+F5 / Shift+F18 relay | VoiceBar `CGEventTap` | Re-paste last transcript |
| Logitech side recording button | VoiceBar `CGEventTap` | Push-to-talk recording |
| Logitech side submit button | VoiceBar `CGEventTap` | Send Return/Enter to the focused app |
| F4 / Spotlight / Launchpad key | Karabiner | Wispr Flow Option+F4 push-to-talk |

The installed app is `/Applications/VoiceBar.app`.

## Button Numbering

There are two relevant numbering systems:

- Karabiner EventViewer reports HID-style names such as
  `{"pointing_button":"button4"}` and `{"pointing_button":"button5"}`.
- VoiceBar reads `CGEventField.mouseEventButtonNumber` from CoreGraphics.
  CoreGraphics uses zero-based extra mouse buttons: left = 0, right = 1,
  center = 2, and additional buttons start at 3.

In the current VoiceBar code:

- `defaultTargetMouseButtons = [4, 5]` records. This preserves the known
  physical Mouse 5 behavior and covers the observed Logitech side-button
  variants.
- `defaultEnterMouseButtons = [3]` sends Return/Enter. This corresponds to the
  other side button in the app-side CoreGraphics layer.

Do not assume Karabiner's `button4` equals VoiceBar's `buttonNumber == 4`.

## Why VoiceBar Owns Mouse Buttons

Karabiner can map mouse buttons in principle. The official Karabiner examples
show `from: { "pointing_button": "button4" }` mapping to keyboard events, and
its docs say the mouse must be enabled in the Devices tab for event
modification.

For this Logitech MX Anywhere 2S setup, however, local testing showed:

- Karabiner EventViewer saw the side button events.
- Karabiner complex modifications for the side buttons did not reliably produce
  the desired VoiceBar behavior.
- VoiceBar's app-side `CGEventTap` reliably saw and consumed
  `otherMouseDown` / `otherMouseUp` events.

The decision is therefore: keep side-button recording and side-button Enter in
VoiceBar, not Karabiner.

## Karabiner State

The active Karabiner file is:

```text
~/.config/karabiner/karabiner.json
```

As of this setup, it should not contain a `Logitech Mouse 4 sends Enter` rule.
That rule was removed to avoid double Enter if Karabiner starts transforming the
same event later.

Karabiner should still contain the F4/Wispr and modifier-guard rules:

- `Bare F4 triggers Wispr Flow Option+F4 push-to-talk; Shift+F4 passes through`
- `Prevent physical Option from triggering Wispr Flow`
- `Prevent physical Left Shift from triggering Wispr Flow paste`

The Logitech MX Anywhere 2S appears to Karabiner as:

```json
{
  "manufacturer": "Logitech",
  "product": "MX Anywhere 2S",
  "device_identifiers": {
    "is_keyboard": true,
    "is_pointing_device": true,
    "vendor_id": 1133,
    "product_id": 45082
  }
}
```

## Verification Commands

Run the focused Swift tests after changing hotkey logic:

```bash
swift test --package-path flow-bar --filter HotkeyManagerTests
```

Run the full VoiceBar Swift package tests before installing:

```bash
swift test --package-path flow-bar
```

Validate Karabiner JSON after any Karabiner edit:

```bash
jq empty ~/.config/karabiner/karabiner.json
karabiner_cli --select-profile Default
```

Rebuild and reinstall VoiceBar:

```bash
bash flow-bar/build-app.sh
pkill -x VoiceBar 2>/dev/null || true
pkill -f 'mcp-server-daemon\.ts' 2>/dev/null || true
open /Applications/VoiceBar.app
pgrep -fl 'VoiceBar|mcp-server-daemon'
```

Expected process state after restart:

- One `/Applications/VoiceBar.app/Contents/MacOS/VoiceBar` process.
- One Bun daemon using
  `/Applications/VoiceBar.app/Contents/Resources/src/mcp-server-daemon.ts`.

## Manual Smoke Test

Use a focused text input:

1. Click into a text editor or terminal prompt.
2. Press the recording side button, speak a short phrase, and release.
3. Confirm VoiceBar records, transcribes, and pastes.
4. Press the Enter side button three times slowly.
5. Confirm each press submits or inserts a newline exactly once.

If Enter works once and then feels unreliable, check focus first. The Return key
is posted to the currently focused app, so a focused menu, panel, or command
palette can consume it.

## Failure Modes To Avoid

- Do not narrow `defaultTargetMouseButtons` from `[4, 5]` without physical
  evidence. Doing that broke the known Mouse 5 recording path once.
- Do not re-add a Karabiner `button4 -> return_or_enter` rule while VoiceBar
  owns Enter; that can cause duplicate Return events.
- Do not rely on EventViewer alone to infer CoreGraphics button numbers.
- Do not claim a hotkey change works until the installed app has been rebuilt
  and restarted. Passing tests only verifies the source behavior.

## Source Pointers

- `flow-bar/Sources/VoiceBar/HotkeyManager.swift`
  - `defaultTargetMouseButtons`
  - `defaultEnterMouseButtons`
  - `mouseHotkeyAction`
  - `postReturnKeyPress`
- `flow-bar/Tests/VoiceBarTests/HotkeyManagerTests.swift`
  - default button configuration
  - Mouse 5 recording behavior
  - Mouse 4 Enter behavior

