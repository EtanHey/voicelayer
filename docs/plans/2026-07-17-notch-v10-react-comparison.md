# Notch V10 React Comparison Implementation Plan

> **For implementation workers:** use TDD task-by-task. Do not commit or push.

**Goal:** Build two comparable React notch prototypes—neutral smoke and adaptive glass—then integrate them on one local comparison page.

**Architecture:** Each worker owns a separate component directory under `site/components/notch-lab/`. Each directory contains its own geometry module, Bun tests, React component, and CSS module. The root agent reviews both and adds the shared Next page only after both variants pass their focused tests.

**Tech Stack:** Next.js 16, React 19, TypeScript, CSS Modules, Bun test, existing VoiceLayer site dependencies.

---

### Task 1: Neutral-smoke prototype

**Files:**
- Create: `site/components/notch-lab/neutral/geometry.ts`
- Test: `site/components/notch-lab/neutral/geometry.test.ts`
- Create: `site/components/notch-lab/neutral/NeutralNotchPrototype.tsx`
- Create: `site/components/notch-lab/neutral/neutral-notch.module.css`

1. Write failing geometry tests for the 185x32 core, zero-extra idle state, side-only recording, 4–6px inverse join, lower-panel-only teleprompter, and fixed waveform slot.
2. Run the focused test and confirm expected RED failures.
3. Implement the minimal geometry module and confirm GREEN.
4. Implement the component and neutral material without backdrop filtering.
5. Run focused tests and TypeScript/build verification.

### Task 2: Adaptive-glass prototype

**Files:**
- Create: `site/components/notch-lab/adaptive/geometry.ts`
- Test: `site/components/notch-lab/adaptive/geometry.test.ts`
- Create: `site/components/notch-lab/adaptive/AdaptiveNotchPrototype.tsx`
- Create: `site/components/notch-lab/adaptive/adaptive-notch.module.css`

1. Write the same failing geometry tests as Task 1 plus material-boundary assertions: opaque hardware core, glass only outside/below it, and clipped overflow.
2. Run the focused test and confirm expected RED failures.
3. Implement minimal geometry and confirm GREEN.
4. Implement subtle adaptive glass with a dark internal teleprompter content layer.
5. Run focused tests and TypeScript/build verification.

### Task 3: Comparison page integration

**Files:**
- Create: `site/app/lab/notch-v10/page.tsx`
- Create: `site/app/lab/notch-v10/notch-v10.module.css`
- Test: `site/app/lab/notch-v10/page.test.ts`

1. Write a failing page contract test for both variant labels and imports.
2. Confirm RED.
3. Add a shared state/material comparison surface showing both prototypes against the same light/dark/purple audit backgrounds.
4. Confirm GREEN and run the full site build.

### Task 4: Visual verification and handoff

1. Launch the site locally without touching VoiceBar runtime.
2. Inspect Idle, Recording, and Teleprompter for both variants at full resolution.
3. Capture comparison receipts, including the purple audit background that exposed V9 spill.
4. Fix any clipping, seam, or overflow defect through a failing test first.
5. Open the comparison page and primary React source in Zed for Etan.
6. Report paths, test/build output, and honest remaining differences. Do not commit or push.
