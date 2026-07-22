# VoiceBar Notch Morph Prototypes — Design

## Goal

Deliver one isolated, notarized VoiceBar build with three runtime-selectable compact-to-teleprompter morph candidates. The build is a selection artifact, not a merge candidate. It must preserve the Phase 1 continuous readable glass, the fixed opaque hardware core, the #359 dismissal behavior, and existing hit geometry.

## Ground truth

- Phase 1 replaced the old compact/teleprompter material split with one continuous U-shaped `NSGlassEffectView` host. The physical core is a separate, nonanimated black overlay.
- SwiftUI `.glassEffect` is not an acceptable material renderer in this `.nonactivatingPanel`; real captures proved that it degrades to a tint. P2 may exercise SwiftUI glass identity/container choreography, but it may not replace the proven AppKit glass pixels.
- The current `.transition(.identity)` is retained only at the idle/non-idle mount boundary. The hero compact-to-teleprompter transition now changes one shell's geometry; the prototype layer must animate that stable owner rather than reinstate the removed painted seam.
- Existing motion constants remain the base: mass `0.72`, stiffness `310`, damping `31`, panel delay `0.05s`, and content exit `0.12s`.
- Research ranking recovered from BrainLayer: matched geometry is the ship-safe baseline, native glass container/identity is the Tahoe experiment, and 2–4% squash/≤4px overshoot is an optional delight layer. Text must remain sharp; the core must not enter any animation namespace.

## Runtime selection

`VoiceBarNotchMorphVariant` has three values:

1. `p1-matched` — shared-shell `matchedGeometryEffect` using a top anchor and frame-only interpolation.
2. `p2-native-glass` — P1 geometry plus macOS 26 `GlassEffectContainer(spacing:)` and `glassEffectID`, while the content-bearing material remains `NSGlassEffectView`. The AppKit host is nested in `NSGlassEffectContainerView` so the native renderer, not SwiftUI `.glassEffect`, owns pixels.
3. `p3-spring-delight` — P1 plus a bounded material-edge squash/settle treatment. It never transforms the text or black core.

The initial variant comes from `VOICEBAR_NOTCH_MORPH_VARIANT`. A checkmarked `Preferences > Morph Prototype` submenu changes the shared observable selection live and persists it in the isolated defaults suite. The selector is intentionally present in this prototype branch only.

## View hierarchy

```text
VoiceBarNotchView
├── VoiceBarGlassContainer(variant)
│   └── compact/teleprompter hero branches
│       └── one shared matched-geometry shell identity
│           └── one explicitly animatable continuous geometry
│               └── one continuous VoiceBarGlassMaterial
│                   └── leading + trailing + lower content slots
└── fixedHardwareCore (black, no namespace, animation=nil, zIndex 10)
```

The two conditional hero branches exist only to give SwiftUI a source and destination for the same shell identity. A stable teleprompter-sized canvas prevents AppKit window resizing from pre-committing the destination. `VoiceBarNotchContinuousShape` exposes every geometry dimension through `VectorArithmetic`, so SwiftUI drives one real U-shaped mask through the intermediate frames rather than cross-fading two surfaces. Each settled state still has exactly one continuous material host.

## Animation contracts

- P1: use the existing physical spring constants. `matchedGeometryEffect` shares the top-anchored shell identity while explicit animatable geometry supplies deterministic mask frames. The content subtree mounts only after the shell duration and fades in within the remaining 350ms budget, preventing clipped or transformed text.
- P2: use the same geometry spring. On macOS 26, apply a shared glass identity inside a container with a small neck spacing. Pre-26 resolves to P1.
- P3: use hero damping near `0.75`, cap scale deformation at 2.5%, and settle inside 350ms. Only material edge/specular treatment receives the squash; content and hardware core do not.
- Reduced Motion: all variants resolve to the existing opacity treatment and no squash.
- Panel frame animation must keep the hardware-core screen center invariant. Geometry tests prove the invariant; the isolated capture harness records the real transition for visual review.
- Closing removes the content before the 120ms-delayed shell contraction. Opening grows empty glass first, then mounts complete content; no frame shows readable text outside its containing glass.

## Verification

- RED source/model tests first for parsing, menu selection, fallback, shared identity, core exclusion, text exclusion, and bounded P3 constants.
- Re-run Phase 1 settled readability and dismissal captures for every variant or, at minimum, the selected app with all variants exercised through the same exact binary.
- Add a transition capture harness that drives compact speaking-with-hidden-teleprompter to visible teleprompter and back, records 60fps video for cadence plus independent full PNG sequences for pixel truth, and emits variant-labelled receipts.
- Inspect light/dark and busy/black/bright frames. Reject clipped text, moving core, disconnected glass, sparse readable pixels, stale dismissal frames, or frame times above the 60fps budget.

## Non-goals

- No Metal domain warp or metaball blur.
- No resident install, launchd reload, release, merge, or winner selection.
- No changes to waveform truth, core dimensions, hit regions, route semantics, or #359 dismissal ownership.
