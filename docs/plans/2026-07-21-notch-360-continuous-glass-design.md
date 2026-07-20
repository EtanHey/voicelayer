# Notch #360 Continuous Glass Design

## Status

Approved by the #360 handoff, Etan's 2026-07-21 scope addition, and the code-verified material correction in `docs.local/research/notch-ground-truth-2026-07-21.md`. The actual panel-to-compact morph animation remains a separate follow-up.

## Goal

Restore readable teleprompter text over busy content and visible compact-wing controls over black and bright menu bars while preserving #359's geometry, waveform, contrast polarity, and playback-edge dismissal behavior.

The expanded teleprompter must be one unbroken material surface from both top wings into the lower panel. Compact and expanded surfaces must live under one persistent container so a later round can replace today's identity/fade transition with a fluid geometry morph without rewriting material or content ownership.

## Evidence and root cause

The archived #359 full-presence frame shows sharp terminal content bleeding through the expanded panel. The teleprompter interior standard deviation was measured near 53, versus about 1.7 in the earlier readable frosted frame. The compact wing backing becomes indistinguishable from a black menu bar.

The W3 physical-notch matrix independently proved that direct SwiftUI glass and `GlassEffectContainer` render correctly in an unfocused nonactivating panel on this Mac. Direct SwiftUI glass produced a visible adaptive surface in both Light and Dark when the modifier was applied to the content-bearing view with a quiet neutral tint.

The current product applies `VoiceBarGlassMaterial` to an empty `Color.clear` teleprompter sibling, then nests that material sibling beside the slots inside `teleprompterSurfaceUnit`. The readability regression first appears after that grouping change, while the material recipe itself is unchanged. Compact wings already apply glass directly to their content, but the product adds a fixed black tint and black overlay in Dark appearance; that recipe collapses to a flat tint over black. At the core join, `VoiceBarNotchCoreSeamStop` paints a four-stop opacity ramp (`0 → 0.06 → 0.52 → 1`) rather than continuing the material across the seam.

The working hypothesis is therefore specific: the empty nested glass sibling prevents the expanded surface from behaving like the proven content-bearing direct-glass sample, the fixed dark overlay defeats adaptive contrast in compact states, and the hand-painted seam ramp interrupts the material that should own the complete panel-to-notch join.

## Approaches considered

### 1. Content-bearing native glass in one persistent container — selected

Apply `VoiceBarNotchContinuousShape` directly to the combined leading, trailing, and optional lower content slots. Keep that one material-owning surface under one stable `GlassEffectContainer` for every non-idle state. In compact geometry the shape contains the two hardware-separated wing subpaths; in teleprompter geometry the same shape becomes one connected top-and-lower-body path. Use the W3-proven neutral glass tint and no fixed dark filled overlay on macOS 26.

This is the smallest change that addresses the measured root cause, preserves the arbitrary continuous notch shape, and keeps the surface hierarchy ready for future `glassEffectID` or matched-geometry morph work.

### 2. Stronger SwiftUI glass recipe

If the quiet native tint is still too translucent in captured pixels, tune the SwiftUI `.glassEffect` tint or layer a shape-bound readability treatment inside the same modifier boundary, then regrade the real frames. The pre-macOS-26 implementation remains SwiftUI `.ultraThinMaterial`.

An AppKit material bridge is not an allowed fallback. The product path must not introduce `NSVisualEffectView`; doing so would contradict the verified rendering architecture and add a second ownership boundary precisely where the future morph needs one SwiftUI geometry owner.

### 3. Opaque or luminance-adaptive scrim

Add a solid veil behind teleprompter text and halos behind compact glyphs. This could satisfy contrast measurements but would preserve the root defect: a tint pretending to be glass. It also introduces per-content patches instead of one adaptive material system.

## Architecture

`VoiceBarNotchView` keeps one fixed shell, one persistent glass container, and one content-bearing `VoiceBarNotchContinuousShape` surface for every non-idle visual state. Compact geometry contains two wing subpaths because the black camera island physically separates them. Teleprompter geometry connects both wings through the lower body. The surface's SwiftUI identity and material ownership do not hand off when the path changes.

The material modifier remains the single recipe boundary. On macOS 26 it uses `.glassEffect` with regular native glass and a quiet neutral tint, without a fixed black fill. On macOS 14–25 it uses SwiftUI `.ultraThinMaterial`. `NSVisualEffectView` is forbidden in the notch material path.

The black hardware core remains a fixed foreground layer and never receives glass. The painted `VoiceBarNotchCoreSeamStop`/`VoiceBarBlackToGlassFade` veils are removed; the continuous material shape itself owns the top-wing-to-lower-panel join and replaces that hand ramp.

The expanded content and material share the same view lifetime. #359's playback-edge state change and AppKit layout ordering remain untouched, so material and text still disappear as one unit.

## Morph-ready boundary

The persistent glass container is outside the compact/teleprompter state switch. Geometry continues to come from `VoiceBarNotchGeometry` and the existing continuous shape. The current PR does not add a new motion curve or animate the shape. A later animation round can attach stable glass IDs or matched geometry inside this already-shared container and interpolate compact-to-expanded geometry without moving content into a new material host.

The current identity/removal behavior remains a policy choice, not an architectural requirement. Tests must forbid separate empty material and content siblings, but must not require the roughly 150 ms opacity fade as the only valid transition.

## Verification design

TDD begins with source/descriptor regressions that require:

- one owning wrapper around the combined leading, trailing, and lower slots to receive exactly one `VoiceBarGlassMaterial` modifier, with all expanded slots as descendants rather than separate material owners;
- exactly one continuous expanded material surface with no inset frame;
- one persistent container outside the compact/expanded switch;
- no fixed black native-glass overlay;
- no painted core seam ramp and no `NSVisualEffectView` material path;
- #359's playback-edge dismissal and geometry contracts to remain unchanged.

The acceptance gate then uses a real isolated VoiceBar app over a separate controlled AppKit backdrop window and captures actual composited pixels. Measurements are deterministic:

- Capture three settled 472 × 245 pt teleprompter frames at the certified backing scale. In each frame, compute 8-bit luma from sRGB inside the normalized lower-body ROI `(x: 0.15, y: 0.58, width: 0.70, height: 0.22)`. This excludes the shape edge, top wings, text rows, and controls. Every frame must contain at least 1,000 pixels and have luma standard deviation at or below 10.
- Grade text in normalized ROI `(0.16, 0.18, 0.68, 0.28)` against the median luma/color of the adjacent glyph-free body ROI. Use the existing WCAG relative-luminance formula and opaque-stroke candidate rule: at least eight foreground pixels and the median of the strongest opaque stroke sample must meet 4.5:1 in every settled frame.
- Launch the same compact Recording geometry over two real helper-window fixtures: uniform black (`sRGB 0,0,0`) and a bright checker whose cell channels are 0.82–1.0. The helper also renders an AppKit `NSImage(systemSymbolName:)` reference with `NSColor.labelColor` outside the glass. Measure the fixed glyph and backing ROIs in three frames per fixture. Each VoiceBar glyph must meet the existing 3.0:1 control floor and must be no worse than the same-frame native reference ratio.
- Capture dismissal from at least 300 ms before the playback-finished edge through at least 300 ms after it at no slower than 25 ms cadence. Reuse the existing opacity normalization and interior-SD audit. There must be zero frames with text opacity at least 0.9 after material opacity falls below 0.5, and no opaque-text frame may exceed interior SD 10.

Every capture instance uses unique sockets, never touches the resident app, and terminates by exact PID in a trap.
