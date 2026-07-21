# VoiceBar v2.1.17 Ship Pass Design

## Goal

Ship the approved notch candidate with stable hover glass color, no empty teleprompter leading wing, and release metadata at `2.1.17`, while preserving the merged event-handling, glass, hardware-core, waveform, and teleprompter behavior.

## Evidence and Root Cause

- `PillHostingView.handlePointerMovement` is now the authoritative hover path. It feeds one `VoiceBarHoverHysteresis` state machine from the panel's global mouse monitor and emits only real hover-state changes.
- `VoiceBarTrackedGlassEffectView` independently installs an `NSTrackingArea` and forwards `mouseEntered` and `mouseExited` to `NSGlassEffectView`. That second hover path can transiently change native-glass rendering before the authoritative notch hover state settles, matching the first-hover color flash.
- `BarView.notchLeadingContent` renders `EmptyView()` for `.teleprompter`, but `VoiceBarNotchContract.geometry(for: .teleprompter)` still reserves a content-fit leading wing for the removed 50-point dictionary lane.
- The last two releases changed `package.json`, `server.json`, and both version values in `flow-bar/bundle/Info.plist`.

## Considered Approaches

1. Remove the redundant tracking area from the native glass host. This is the smallest fix and leaves the #370 global hover/hysteresis path as the single authority. Recommended.
2. Add more debounce around appearance or tint updates. This would treat the visible flash after it has already been triggered and could delay legitimate Light/Dark changes.
3. Replace or overlay the native glass material. This risks the sacred glass topology and opaque hardware core for a cosmetic defect.

For teleprompter geometry, the direct fix is to set only `.teleprompter`'s `leadingWingWidth` to zero. The lower body remains centered through its existing symmetric 140-point extents, and the right waveform wing remains unchanged.

## Testing and Acceptance

- Add a source-contract regression proving the native glass host has no private hover tracking or mouse-entry forwarding.
- Change the geometry contract test to require a zero-width teleprompter leading wing and unchanged waveform trailing wing.
- Verify those tests fail before production edits and pass afterward.
- Run focused Swift tests, the full Swift and Bun suites, the notch corpus, exact-head release build/notarization, and offscreen real-pixel hover/teleprompter capture.
- Stage the exact-head `.verified` receipt and include `Verified-Runtime: <head>` in the ready-for-review PR body.

## Safety Boundaries

- Do not change `PillHostingView`, #370 hit testing/pass-through, mounted-control routing, focus behavior, waveform rendering, or teleprompter content/right-side controls.
- Do not change the glass recipe, continuous material topology, or fixed opaque-black hardware core.
- Run all candidate app instances offscreen and terminate exact PIDs. Never replace or relaunch `/Applications/VoiceBar.app`.
- Stop after PR review handling; the lead owns merge, resident swap, tag, and release.
