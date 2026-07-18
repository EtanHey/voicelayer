# Notch V10 React Comparison Design

## Goal

Create two interactive React mocks of the same VoiceBar notch shell so Etan can compare a neutral-smoke material against subtle adaptive glass without geometry drift.

## Shared silhouette

The preview represents the real built-in display's 185-point camera housing and 32-point menu-bar height. Idle is only the black hardware footprint. Recording expands horizontally into content-driven left and right wings while leaving the center black. Teleprompter keeps those wings and adds a single panel directly underneath the complete assembly.

The panel-to-menu-bar join uses a 4–6px concave inverse corner: visually a softened inside 90-degree turn, then immediately vertical. It must not narrow into a neck, flare into wide shoulders, expose a purple material band, or let content escape its mask.

## Variant A — neutral smoke

Opaque black camera core, near-black wings, and a neutral charcoal teleprompter body. No backdrop sampling. Separation comes from a hairline inner highlight and restrained shadow only when expanded. This is the recommended production-safe baseline.

## Variant B — adaptive glass

The camera footprint remains opaque black. Only pixels extending outside/below the hardware footprint may sample the background. The glass is clipped by the identical shell mask and capped at subtle saturation/tint. Teleprompter text sits on a darker internal content layer so wallpaper color cannot reduce legibility.

## Interaction and motion

A state switch exposes Idle, Recording, and Teleprompter. Recording shows mic/live state + timer on the left and truthful fixed-slot waveform + pause/stop/cancel on the right. Teleprompter shows a three-line focus gradient and compact transport. Width and height animate together on open; close is quiet and non-overshooting. Pausing freezes the waveform; stopping uses staggered decay rather than synchronized disappearance.

## Acceptance

- Both variants share the same geometry tokens and state content.
- No material or content renders outside the shell at any state.
- The inverse join consumes at most 6px vertically and horizontally.
- Recording never creates a lower panel.
- Teleprompter is the only lower panel in the first pass.
- The prototype works on the existing VoiceLayer Next/React toolchain and can be inspected locally in a browser and Zed.
- No resident VoiceBar, daemon, sockets, or `/Applications/VoiceBar.app` are touched.

## Repository safety

This is an uncommitted visual prototype. No commit or push is authorized by this task.
