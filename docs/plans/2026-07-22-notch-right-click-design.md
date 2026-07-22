# VoiceBar Notch Right-Click Restoration Design

## Problem

PR #370 deliberately restricted VoiceBar's interactive region to mounted 20×20
control glyphs. That protects macOS menu-bar controls in the transparent panel
margins, but the same predicate now controls `NSView.hitTest`, the panel context
menu, and `NSPanel.ignoresMouseEvents`. A secondary click on visible wing or notch
body pixels therefore never reaches `FloatingPillPanel.sendEvent`.

## Approaches considered

1. **Restore the old oversized rectangular hit region.** This would restore the
   menu but would also regress #370 by intercepting macOS status controls in
   transparent margins. Rejected.
2. **Make hit testing event-type-aware.** Secondary clicks could claim the visible
   shape while primary clicks keep the glyph-only behavior. This is precise, but
   `NSPanel.ignoresMouseEvents` is window-wide rather than event-specific, so the
   panel still needs visible-shape mouse eligibility before AppKit can inspect the
   event type.
3. **Use two explicit geometry predicates.** Keep mounted-control geometry for
   controls and drag starts, and use the exact rendered notch path for host/window
   event admission and context-menu eligibility. This is selected because the
   rendered path is already tight to pixels and does not overlap the protected
   transparent margins.

## Selected design

Add a rendered-surface provider to `PillHostingView` and a context-menu provider
to `FloatingPillPanel`. App wiring supplies
`VoiceBarPanelLayout.containsVisibleSurface` to both. `hitTest` claims the hosting
view anywhere inside that tight path (`super.hitTest(point) ?? self`) and returns
`nil` outside it. `FloatingPillPanel.shouldHandleContextMenu` uses the same tight
path, while `startsDrag` remains mounted-control-only.

Window-wide passthrough also switches from `containsInteractiveContent` to
`containsVisibleSurface`: when the pointer is on rendered pixels, the panel can
receive an AppKit event; when it is in transparent panel margins, the panel sets
`ignoresMouseEvents = true`, so the event goes to the macOS window beneath it.
The panel remains `.nonactivatingPanel`, never calls `makeKey`, and cannot become
main, so admitting a click on VoiceBar's own rendered surface does not activate
the app or steal focus.

## Verification

- TDD regression coverage proves visible wing/body points hit the hosting view
  and qualify for the context menu in idle, launcher, recording, compact-status,
  and teleprompter states.
- Negative coverage proves shadow/transparent-margin points still return `nil`,
  cannot start a drag, and cannot open the VoiceBar menu.
- Lifecycle coverage proves passthrough uses the visible-surface predicate while
  drag continues to use mounted-control geometry.
- Full Swift and Bun suites, corpus verification, exact-head isolated notarized
  build, and offscreen real-UI right-click acceptance provide release evidence.
