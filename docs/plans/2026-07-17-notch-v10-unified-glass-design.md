# Notch V10 Unified Glass Design

## Status

Approved by Etan on 2026-07-17. This is a React interaction mock only; it does not modify the native VoiceBar app.

## Goal

Create the center candidate between the neutral-smoke and adaptive-glass extremes, prove its full opening and closing motion, and expose its geometry clearly enough to tune live in Zed before native implementation.

## Material

- The 185 × 32 physical camera housing stays pure opaque black.
- Glass exists only outside or below the physical housing.
- Every top wing is the same `GlassWing` component and uses one shared liquid-glass material recipe. Idle-hover, Recording, and Teleprompter may change only wing width, content, and whether the wing is joined to the lower surface; they must not substitute a transparent outline shell.
- The first 12–16px of each glass wing blends out of the black housing instead of meeting it at a hard separator.
- The teleprompter is one continuous glass surface. It has no inset card, frame, or second dark panel.
- A short shadow/opacity veil below the core visually joins black hardware to the continuous glass panel without tinting the camera area.
- Text contrast comes from local text shadow and a quiet content veil, not a framed background.

## States and interaction

1. **Idle:** only the physical 185 × 32 black core is visible.
2. **Hover launcher:** hovering the idle core preserves the 32px height and opens compact glass side wings. Mic occupies the 36px leading wing; History then Dictionary occupy the 64px trailing wing. History and Dictionary show a pressed/selected demonstration only; Mic opens Recording. Hover never grows downward.
3. **Recording:** compact glass wings flank the unchanged black core. The left wing carries status/timer; the right carries a fixed waveform slot and pause, stop, and cancel controls. No lower panel.
4. **Teleprompter:** the wings remain, the redundant Speaking label is removed, and the continuous glass surface grows downward. It carries three focused lines plus back, pause/resume, and close controls.
5. **Closing:** content exits first, the lower surface folds upward, then the wings retract into the hardware core. The waveform decays instead of disappearing in one frame.

## Motion

- Use Framer Motion for interruptible width/height and content presence transitions.
- Opening uses a restrained spring with no toy-like bounce. Wings establish first; the lower panel follows roughly 50ms later.
- Closing reverses the hierarchy: content fades out over roughly 120ms, panel retracts, wings finish at idle.
- State buttons plus a replay control make every transition inspectable in Helium.
- Reduced-motion users receive short opacity transitions without spring travel.

## Editability

- All silhouette dimensions and motion timings live in named constants at the top of `HybridNotchPrototype.tsx`.
- Tailwind classes own ordinary layout, spacing, typography, and controls.
- `unified-glass.module.css` owns only backdrop sampling, exact masks, and black-to-glass edge fades.

## Acceptance criteria

- Idle adds no pixels outside the physical housing until hovered.
- Hover is exactly 285 × 32: 36px leading Mic wing + 185px core + 64px trailing History/Dictionary wing.
- Hover has no lower surface; the teleprompter is the only downward expansion.
- Hover exposes exactly History, Dictionary, and Mic.
- Mic enters Recording.
- The hardware core never receives glass or backdrop blur.
- No hard black separators appear between the core and the glass wings.
- The teleprompter contains no inset frame.
- Opening and closing can be replayed and visibly preserve the state hierarchy.
- The existing two extremes remain visible as references below the large hybrid candidate.

## Approved narrow-wing refinement

Etan approved a stepped single-surface variant on 2026-07-17:

- Recording top wings use 72px leading and 152px trailing to fit their distinct content.
- Teleprompter top wings use their own content-fit 76px leading and 88px trailing geometry because that state only carries the book/timer and waveform.
- Recording therefore spans 409 × 32, while its content centers inside each wing.
- The teleprompter body remains 465px wide and is centered on the 185px hardware core with equal 140px body extents.
- In teleprompter state, the one continuous glass mask curves from the 349px top bar into the wider centered body, leaving content-fit asymmetric wings but a body centered around the hardware. The shoulders are geometry in the single mask, not two stacked glass layers.
- Each teleprompter wing reserves the same core-side safety zone: the 16px black-to-glass fade, then an 8px clear gap before content. Each also keeps 8px of outer-edge padding. Only the content slot differs: 44px for book/timer and 56px for waveform.
- Hover and Recording wings keep a visible 16%-white outline around each wing's top, bottom, and outer edge. Their core-facing edges remain borderless, so the glass still fades into the hardware without a separator.
- Hover and Recording render the shared `GlassWing` material locally because no lower surface exists. Teleprompter uses that same component integrated into the approved continuous body mask, avoiding a doubled tint where the wing and body meet.
- The teleprompter body keeps its quiet outer edge.
