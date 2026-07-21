# Notch #360 Continuous Glass Design

## Status

Approved by the #360 handoff and Etan's 2026-07-21 scope/material corrections. Etan's later ground-truth correction supersedes the original SwiftUI-only hypothesis: macOS 26 uses AppKit `NSGlassEffectView` through `NSViewRepresentable`; `NSVisualEffectView` remains forbidden. The actual panel-to-compact morph animation remains a separate follow-up.

## Goal

Restore readable teleprompter text over busy content and visible compact-wing controls over black and bright menu bars while preserving #359's geometry, waveform, contrast polarity, and playback-edge dismissal behavior.

The expanded teleprompter must be one unbroken material surface from both top wings into the lower panel. Compact and expanded surfaces must live under one persistent container so a later round can replace today's identity/fade transition with a fluid geometry morph without rewriting material or content ownership.

## Evidence and root cause

The archived #359 full-presence frame shows sharp terminal content bleeding through the expanded panel. The teleprompter interior standard deviation was measured near 53, versus about 1.7 in the earlier readable frosted frame. The compact wing backing becomes indistinguishable from a black menu bar.

The initial W3 matrix made direct SwiftUI glass look viable in an unfocused nonactivating panel, but the production-like real-pixel fixture disproved that conclusion. In an `NSPanel` with `.nonactivatingPanel`, SwiftUI `.glassEffect` degraded to a flat translucent treatment: busy backing content remained visible rather than being frosted. The WindowServer lensing path survives when the same SwiftUI geometry owns an AppKit `NSGlassEffectView`, its containing panel is explicitly clear, and the glass view has an active-in-app tracking area.

The current product also applies `VoiceBarGlassMaterial` to an empty `Color.clear` teleprompter sibling, adds a fixed dark tint/overlay to compact wings, and paints the core join with `VoiceBarNotchCoreSeamStop`'s four-stop opacity ramp (`0 → 0.06 → 0.52 → 1`). Those ownership and paint layers compound the failure, but they are not a substitute for fixing the degraded native host.

The verified root cause is therefore the nonactivating-panel rendering path plus the old split ownership: macOS 26 needs an `NSGlassEffectView` content host, the panel backing must stay clear, and one arbitrary shape must own the entire external wing-to-lower-panel glass. The camera/core footprint must remain opaque black and absent from the glass mask so lensing never reveals the hardware edge.

## Approaches considered

### 1. AppKit native glass in one persistent SwiftUI geometry host — selected

Apply `VoiceBarNotchContinuousShape` to the combined leading, trailing, and optional lower content slots. On macOS 26, use that SwiftUI shape as the mask of one `NSGlassEffectView` embedded by `NSViewRepresentable`, with the SwiftUI content hosted as the glass view's `contentView`. Keep that one material-owning surface under one stable SwiftUI container for every non-idle state. In compact geometry the shape contains the two hardware-separated external wing subpaths; in teleprompter geometry it becomes one connected U-shaped external surface around the opaque black core and through the lower body. Use regular native glass with a quiet neutral tint.

The bridge sets the containing window background to clear and installs an `NSTrackingArea` with `.mouseEnteredAndExited` and `.activeInActiveApp`. This is the smallest change that addresses the measured root cause, preserves the arbitrary continuous notch shape, and leaves a stable geometry/content owner ready for matched-geometry morph work. A later phase can prototype native `GlassEffectContainer`/`glassEffectID` separately behind availability checks without making it the Phase 1 material path.

### 2. Stronger SwiftUI glass recipe — rejected on macOS 26

Tuning SwiftUI `.glassEffect` did not restore lensing in the production-like nonactivating panel. More tint would turn the defect into a more opaque slab rather than real frosting. The pre-macOS-26 implementation remains SwiftUI `.ultraThinMaterial`.

`NSVisualEffectView` is not an allowed fallback and is not used. `NSGlassEffectView` is the macOS 26 glass API required by the verified rendering path; the representable preserves SwiftUI as the geometry and state owner.

### 3. Opaque or luminance-adaptive scrim

Add a solid veil behind teleprompter text and halos behind compact glyphs. This could satisfy contrast measurements but would preserve the root defect: a tint pretending to be glass. It also introduces per-content patches instead of one adaptive material system.

## Architecture

`VoiceBarNotchView` keeps one fixed shell, one persistent SwiftUI glass wrapper, and one content-bearing `VoiceBarNotchContinuousShape` surface for every non-idle visual state. Compact geometry contains two wing subpaths because the black camera island physically separates them. Teleprompter geometry connects both external wings through the below-bezel body while excluding the camera/core footprint. The surface's SwiftUI identity and material ownership do not hand off when the path changes.

The material modifier remains the single recipe boundary. On macOS 26 it embeds `NSGlassEffectView` with regular native glass, a quiet neutral tint, a shape mask, clear window backing, and active-in-app tracking. On macOS 14–25 it uses SwiftUI `.ultraThinMaterial`. `NSVisualEffectView` is forbidden in the notch material path.

The black hardware core remains a fixed foreground layer and never receives glass. The painted `VoiceBarNotchCoreSeamStop`/`VoiceBarBlackToGlassFade` veils are removed; the continuous material shape itself owns the top-wing-to-lower-panel join and replaces that hand ramp.

The expanded content and material share the same view lifetime. Native glass can begin a WindowServer fade before hosted SwiftUI content is removed, so the playback-finished edge first clears and flushes hosted text, yields one frame, then orders the panel out after 50 ms. This preserves #359's atomic-dismissal contract without locking the future compact/expanded transition to a fade.

## Morph-ready boundary

The persistent SwiftUI wrapper is outside the compact/teleprompter state switch. Geometry continues to come from `VoiceBarNotchGeometry` and the existing continuous shape. The current PR does not add a new compact/expanded motion curve or animate the shape. A later animation round can attach matched geometry to this already-shared shell, or prototype native glass IDs behind macOS 26 availability, without changing content ownership or moving the fixed core.

The current identity/removal behavior remains a policy choice, not an architectural requirement. Tests must forbid separate empty material and content siblings, but must not require the roughly 150 ms opacity fade as the only valid transition.

## Verification design

TDD begins with source/descriptor regressions that require:

- one owning wrapper around the combined leading, trailing, and lower slots to receive exactly one `VoiceBarGlassMaterial` modifier, with all expanded slots as descendants rather than separate material owners;
- exactly one continuous expanded material surface with no inset frame;
- one persistent container outside the compact/expanded switch;
- no fixed black native-glass overlay;
- one macOS 26 `NSGlassEffectView` representable with clear window backing, active-in-app tracking, and no `NSVisualEffectView` path;
- no painted core seam ramp and no glass in the opaque hardware-core footprint;
- #359's playback-edge dismissal and geometry contracts to remain unchanged.

The acceptance gate then uses a real isolated VoiceBar app over a separate controlled AppKit backdrop window and captures actual composited pixels. Measurements are deterministic:

- Capture three settled 472 × 245 pt teleprompter frames at the certified backing scale. In each frame, compute 8-bit luma from sRGB inside the normalized lower-body ROI `(x: 0.15, y: 0.58, width: 0.70, height: 0.22)`. This excludes the shape edge, top wings, text rows, and controls. Every frame must contain at least 1,000 pixels and have luma standard deviation at or below 10.
- Grade text in normalized ROI `(0.16, 0.18, 0.68, 0.28)` against the median luma/color of the adjacent glyph-free body ROI. Use the existing WCAG relative-luminance formula and opaque-stroke candidate rule: at least eight foreground pixels and the median of the strongest opaque stroke sample must meet 4.5:1 in every settled frame.
- Launch the same compact Recording geometry over two real helper-window fixtures: uniform black (`sRGB 0,0,0`) and a bright checker whose cell channels are 0.82–1.0. The helper also renders an AppKit `NSImage(systemSymbolName:)` reference with `NSColor.labelColor` outside the glass. Measure the fixed glyph and backing ROIs in three frames per fixture. Each VoiceBar glyph must meet the existing 3.0:1 control floor and must be no worse than the same-frame native reference ratio.
- Capture dismissal from at least 300 ms before the playback-finished edge through at least 300 ms after it at no slower than 25 ms cadence. Reuse the existing opacity normalization and interior-SD audit. There must be zero frames with text opacity at least 0.9 after material opacity falls below 0.5, and no opaque-text frame may exceed interior SD 10.

Every capture instance uses unique sockets, never touches the resident app, and terminates by exact PID in a trap.
