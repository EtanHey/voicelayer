# Notch #360 Continuous Glass Design

## Status

Approved by the #360 handoff and Etan's 2026-07-21 scope addition. The actual panel-to-compact morph animation remains a separate follow-up.

## Goal

Restore readable teleprompter text over busy content and visible compact-wing controls over black and bright menu bars while preserving #359's geometry, waveform, contrast polarity, and playback-edge dismissal behavior.

The expanded teleprompter must be one unbroken material surface from both top wings into the lower panel. Compact and expanded surfaces must live under one persistent container so a later round can replace today's identity/fade transition with a fluid geometry morph without rewriting material or content ownership.

## Evidence and root cause

The archived #359 full-presence frame shows sharp terminal content bleeding through the expanded panel. The teleprompter interior standard deviation was measured near 53, versus about 1.7 in the earlier readable frosted frame. The compact wing backing becomes indistinguishable from a black menu bar.

The W3 physical-notch matrix independently proved that direct SwiftUI glass, `GlassEffectContainer`, and AppKit glass all render correctly in an unfocused nonactivating panel on this Mac. Direct SwiftUI glass produced a visible adaptive surface in both Light and Dark when the modifier was applied to the content-bearing view with a quiet neutral tint.

The current product applies `VoiceBarGlassMaterial` to an empty `Color.clear` teleprompter sibling, then nests that material sibling beside the slots inside `teleprompterSurfaceUnit`. The readability regression first appears after that grouping change, while the material recipe itself is unchanged. Compact wings already apply glass directly to their content, but the product adds a fixed black tint and black overlay in Dark appearance; that recipe collapses to a flat tint over black.

The working hypothesis is therefore specific: the empty nested glass sibling prevents the expanded surface from behaving like the proven content-bearing direct-glass sample, and the fixed dark overlay defeats adaptive contrast in compact states.

## Approaches considered

### 1. Content-bearing native glass in one persistent container — selected

Apply the continuous teleprompter shape directly to the combined leading, trailing, and lower content slots. Put both compact wings and the expanded continuous surface under one stable `GlassEffectContainer` owned by the notch shell. Use the W3-proven neutral glass tint and no fixed dark filled overlay on macOS 26.

This is the smallest change that addresses the measured root cause, preserves the arbitrary continuous notch shape, and keeps the surface hierarchy ready for future `glassEffectID` or matched-geometry morph work.

### 2. AppKit glass/visual-effect bridge

Wrap the SwiftUI slots in `NSGlassEffectView` on macOS 26 and `NSVisualEffectView` on older systems. W3 proves this renders, but an AppKit bridge would need custom masking and hosted-content synchronization for the irregular continuous shape. That adds a second ownership boundary precisely where the future morph needs a single SwiftUI geometry owner.

Keep this as the fallback if direct native glass fails the new real-pixel gate after one minimal implementation attempt.

### 3. Opaque or luminance-adaptive scrim

Add a solid veil behind teleprompter text and halos behind compact glyphs. This could satisfy contrast measurements but would preserve the root defect: a tint pretending to be glass. It also introduces per-content patches instead of one adaptive material system.

## Architecture

`VoiceBarNotchView` keeps one fixed shell and one persistent glass container for every non-idle visual state. Compact mode still owns two content-bearing wings because they are physically separated by the black camera island. Teleprompter mode owns one content-bearing `VoiceBarNotchContinuousShape` whose path includes both wings and the lower body while excluding the physical hardware core.

The material modifier remains the single recipe boundary. On macOS 26 it uses regular native glass with a quiet neutral tint proven by W3, without a fixed black fill. On macOS 14–25 it keeps the existing guarded material fallback. The black hardware core and its seam veils remain foreground layers and never receive glass.

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
- #359's playback-edge dismissal and geometry contracts to remain unchanged.

The acceptance gate then uses a real isolated VoiceBar app over a separate controlled AppKit backdrop window and captures actual composited pixels. Measurements are deterministic:

- Capture three settled 472 × 245 pt teleprompter frames at the certified backing scale. In each frame, compute 8-bit luma from sRGB inside the normalized lower-body ROI `(x: 0.15, y: 0.58, width: 0.70, height: 0.22)`. This excludes the shape edge, top wings, text rows, and controls. Every frame must contain at least 1,000 pixels and have luma standard deviation at or below 10.
- Grade text in normalized ROI `(0.16, 0.18, 0.68, 0.28)` against the median luma/color of the adjacent glyph-free body ROI. Use the existing WCAG relative-luminance formula and opaque-stroke candidate rule: at least eight foreground pixels and the median of the strongest opaque stroke sample must meet 4.5:1 in every settled frame.
- Launch the same compact Recording geometry over two real helper-window fixtures: uniform black (`sRGB 0,0,0`) and a bright checker whose cell channels are 0.82–1.0. The helper also renders an AppKit `NSImage(systemSymbolName:)` reference with `NSColor.labelColor` outside the glass. Measure the fixed glyph and backing ROIs in three frames per fixture. Each VoiceBar glyph must meet the existing 3.0:1 control floor and must be no worse than the same-frame native reference ratio.
- Capture dismissal from at least 300 ms before the playback-finished edge through at least 300 ms after it at no slower than 25 ms cadence. Reuse the existing opacity normalization and interior-SD audit. There must be zero frames with text opacity at least 0.9 after material opacity falls below 0.5, and no opaque-text frame may exceed interior SD 10.

Every capture instance uses unique sockets, never touches the resident app, and terminates by exact PID in a trap.
