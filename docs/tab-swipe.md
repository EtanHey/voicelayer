# Shared tab-swipe behaviour: VoiceBar notch tabs and BrainBar tabs

Status: agreed 2026-11-27 by the VoiceLayer lead and the BrainBar UI lead. One behaviour, in both apps. BrainBar built the
shared view first (brainlayer PR #1896, `brain-bar/Sources/BrainBar/NewDesign/GlassTabPager.swift`). VoiceBar runs a
copy of it in `flow-bar/Sources/VoiceBarUI/GlassTabPager.swift`.

## Behaviour

1. **Live tracking.** During a trackpad sideways swipe, the selection pill and the content both follow the fingers 1:1.
   The pill's frame (x and width) interpolates linearly between the two neighbouring tab slots by swipe progress.
2. **Release.** One spring settles pill and content together. The target tab comes from position plus projected
   velocity. The pill ends at the destination slot's resting size; it never stays stretched.
3. **Click.** A click on a tab moves pill and content together with the same spring, from their current presented
   position. The title never jumps while the content slides separately. Long press and drag use the same path.
4. **No layout shift.** Label slots have fixed widths for the whole control. Each slot is measured at its selected
   weight, so selection never changes a width. The pill is an overlay view; selection never re-lays out labels.
   The window/container height never changes on a frame where progress is fractional. Either hold one height across
   the transition and resize only after the settle, or drive the resize from the same spring. (BrainBar's QA found its
   layout shift came from the window resizing to each page's content right after a swap.)
5. **Interruptible.** A gesture or click during a settle retargets from the current presented position, carrying
   the current velocity.
6. **Reduce Motion.** The content crossfades and the pill moves without overshoot. Nothing slides.

## Shared constants

- Spring: critically damped, response 0.30 s, damping fraction 1.0, initial velocity = gesture velocity at release
  (0 for a click from rest). Changed only by agreement of both leads, from measurements.
- Pill: SwiftUI `GlassEffectContainer` + `.glassEffect` on an overlay view (macOS 26), a solid capsule before that.

## Acceptance (both apps, on mains and on battery)

- 120 fps screen recording of: a slow swipe across all tabs, a fast swipe, a click on a far tab, a click during a
  settle.
- No frame in which the pill or the content moves more than one third of a tab width from the previous frame.
- No non-moving element (labels, header, window frame) changes size or position in any frame.
- The pill rests at the destination slot's exact frame within 0.5 s of release or click.
- Tests pin rules 1 to 3 (progress to pill frame mapping; release target choice; click uses the same spring path).
- Report recorder cadence (repeated frames, pts gaps) so recorder drops are not blamed on the app.
- BrainBar's measured limits are the targets: pill moves at most 21.5 pt per frame, rest within 477 ms, first motion
  2 to 3 frames after the slop.

## Two lessons from BrainBar's 120 fps recording

1. Commit the selection to the app's state only at **rest**, never on the frame the spring starts. A publish on that
   frame rebuilt every view and froze 13 frames.
2. Keep **every page built and laid out**. Building a neighbour on the first swipe frame delayed its motion by about
   12 frames.

## In VoiceBar

Both notch tab rows use it: the History categories (Dictations / Ask / Narration, `NotchHistoryCategoryPanel`, in the
History drawer and on the Settings drawer's Dictation tab) and the Settings drawer's tabs (`NotchSettingsDrawer`).

- `GlassTabPager` holds the presented progress, the velocity and the spring. Each view keeps it in `@State` without
  observing it. Only the bar and the `NotchTabPage` wrappers observe it, so a frame of motion re-runs an offset, never
  a page or a row. `GlassTabPagerClock` ticks it from the display while a settle runs.
- `NotchTabGesture` feeds it from VoiceBar's scroll-event monitors with the existing axis lock
  (`NotchHistoryCategoryPager`). The axis is picked once in the first 6 pt, at 1.5 times more horizontal than
  vertical, so a vertical scroll never switches tab. The step that decides hands over the whole travel so far.
  Each event's own timestamp feeds the velocity.
- Release picks the tab at the presented position plus the projected velocity, at most one tab per swipe. The ends
  stop with a rubber band. A gesture the system cancels settles back on the tab it began on (Settings) or is released
  (History, as before).
- Clicks, Left/Right (focus rules unchanged: only while the History list or selector has focus in the key panel) and
  VoiceOver go through `GlassTabPager.select`, the same spring. A click during a swipe ends that swipe.
- The selection reaches the app (`archive.selectedScope`, `onSelectTab`) only at rest.
- Every Settings pane stays built and laid out side by side; panes slide with the pill. The Dictation pane's History
  panel reads the Ask and Narration archives only while its tab is the one shown, and takes no gestures, keys or focus
  while hidden.
- Slots are equal across the drawer's width (`GlassTabMetrics.fill`), one weight for every label; the selected
  colour is drawn only inside the pill. Each slot is exposed to VoiceOver as a button with its own identifier and
  tooltip (`NotchTabSlots`).
- Reduce Motion: the pages stay in place and cross-fade by the same progress; no velocity is carried in.

The VoiceBar copy's changes to BrainBar's file are listed at the top of `GlassTabPager.swift`. Each change is additive,
with a default that keeps BrainBar's behaviour.
