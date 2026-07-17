# Notch V10 Unified Glass Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Build an editable React mock of the approved unified-liquid-glass notch, including the idle hover launcher and replayable opening/closing motion.

**Architecture:** Add one isolated hybrid prototype beside the two existing reference prototypes. Keep geometry and motion as pure exported contracts for Bun tests, use Framer Motion for presentation state, Tailwind for ordinary styling, and a narrow CSS module for exact glass masks/fades.

**Tech Stack:** Next.js 16, React 19, Tailwind CSS 4, Framer Motion 12, CSS Modules, Bun test.

---

### Task 1: Lock geometry, launcher, material, and motion contracts

**Files:**
- Create: `site/components/notch-lab/hybrid/contract.test.ts`
- Create: `site/components/notch-lab/hybrid/contract.ts`

**Step 1:** Write failing tests for the 185 × 32 idle core, approved 285 × 32 side-wing hover launcher, 409 × 32 recording width, 465 × 228 teleprompter surface, teleprompter-only lower surface, 16px material blend, zero inset frames, launcher actions, and ordered open/close phases.

**Step 2:** Run `bun test ./components/notch-lab/hybrid/contract.test.ts` from `site/` and verify it fails because `contract.ts` does not exist.

**Step 3:** Implement only the constants and pure geometry/motion functions needed by the tests.

**Step 4:** Re-run the focused test and verify zero failures.

### Task 2: Build the hybrid interactive prototype

**Files:**
- Create: `site/components/notch-lab/hybrid/HybridNotchPrototype.tsx`
- Create: `site/components/notch-lab/hybrid/unified-glass.module.css`
- Test: `site/components/notch-lab/hybrid/HybridNotchPrototype.test.ts`

**Step 1:** Write a source-contract test requiring Framer Motion presence/layout, Tailwind geometry markers, History/Dictionary/Mic controls, Mic-to-recording wiring, and the absence of an inset teleprompter frame.

**Step 2:** Run the source test and verify the missing component produces the expected RED.

**Step 3:** Implement the component with top-of-file geometry/motion constants, idle hover/focus handling, recording/teleprompter controls, and a replay sequence.

**Step 4:** Implement only the CSS needed for glass sampling, edge fades, and continuous-panel masking.

**Step 5:** Run hybrid tests and the targeted TypeScript build until green.

### Task 3: Put the center candidate above the references

**Files:**
- Modify: `site/app/lab/notch-v10/page.tsx`
- Modify: `site/app/lab/notch-v10/notch-v10.module.css`
- Modify: `site/app/lab/notch-v10/page.test.ts`

**Step 1:** Extend the page test to require the large unified-glass candidate and retain both reference imports.

**Step 2:** Run the page test and verify it fails before page integration.

**Step 3:** Render the hybrid candidate full-width above the two smaller reference cards.

**Step 4:** Run all notch-lab tests.

### Task 4: Verify the actual render

**Files:**
- Store receipts under: `docs.local/design/notch-v10-react-comparison/receipts/`

**Step 1:** Run `npm run build -- --webpack` because Turbopack cannot traverse this worktree's external `node_modules` symlink.

**Step 2:** Relaunch the built route on `127.0.0.1:3017`.

**Step 3:** Inspect Hover, Recording, Teleprompter, and Closing in Helium at normal and reduced motion.

**Step 4:** Capture the hybrid teleprompter and hover launcher receipts.

**Step 5:** Open the hybrid TSX and route in Zed for operator tuning.

No commit or push is included because repository instructions require explicit permission.

### Task 5: Narrow top wings without narrowing the teleprompter body

**Files:**
- Modify: `site/components/notch-lab/hybrid/contract.test.ts`
- Modify: `site/components/notch-lab/hybrid/contract.ts`
- Modify: `site/components/notch-lab/hybrid/HybridNotchPrototype.tsx`

**Step 1:** Change the contract test to require 36/64px hover wings, 72/152px recording wings, and separate 104/176px teleprompter-body extents at the unchanged 465px body width.

**Step 2:** Run the focused contract test and verify RED against the old coupled wing/body geometry.

**Step 3:** Add body extents to the geometry contract, center the compact wing contents, and apply one continuous clipped glass outline with curved shoulders only in teleprompter state.

**Step 4:** Run all focused notch tests, build with webpack, restart `127.0.0.1:3017`, and visually inspect Recording and Teleprompter in Helium.

No commit or push is included.

### Task 6: Center the body independently from content-fit wings

**Files:**
- Modify: `site/components/notch-lab/hybrid/contract.test.ts`
- Modify: `site/components/notch-lab/hybrid/contract.ts`
- Modify: `site/components/notch-lab/hybrid/HybridNotchPrototype.tsx`

**Step 1:** Require teleprompter-specific 64/72px top wings and equal 140/140px body extents around the 185px core; require borderless compact wings and a teleprompter-only outline.

**Step 2:** Run the contract test and confirm RED against the asymmetric 104/176 body.

**Step 3:** Decouple teleprompter wing widths from Recording, center the body, and condition the glass edge on lower-surface presence.

**Step 4:** Run focused tests, rebuild, restart the live route, and visually inspect the three states.

### Task 7: Restore compact outlines and reserve fade-safe wing padding

**Files:**
- Modify: `site/components/notch-lab/hybrid/contract.test.ts`
- Modify: `site/components/notch-lab/hybrid/HybridNotchPrototype.test.ts`
- Modify: `site/components/notch-lab/hybrid/contract.ts`
- Modify: `site/components/notch-lab/hybrid/HybridNotchPrototype.tsx`

**Step 1:** Require compact-state outlines, a shared 8px fade-to-content gap, a shared 8px outer inset, and 76/88px content-fit teleprompter wings.

**Step 2:** Run the focused contract tests and confirm RED against the mistaken borderless 64/72px implementation.

**Step 3:** Restore the compact outline and apply mirrored fade-safe padding: outer/fade+gap on the leading wing and fade+gap/outer on the trailing wing.

**Step 4:** Run the focused suites, rebuild, restart the live route, and visually inspect Hover, Recording, and Teleprompter.

No commit or push is included.

### Task 8: Unify every top wing on the liquid-glass component

**Files:**
- Modify: `site/components/notch-lab/hybrid/HybridNotchPrototype.test.ts`
- Modify: `site/components/notch-lab/hybrid/HybridNotchPrototype.tsx`

**Step 1:** Require one reusable `GlassWing` component and one shared material class recipe used by both compact wings and the approved continuous Teleprompter surface.

**Step 2:** Run the source-contract test and confirm RED against the split implementation where a global backdrop owns the material while compact wing wrappers own only their outlines and content.

**Step 3:** Move compact tint, backdrop blur, highlight, fade, radius, and outline into `GlassWing`; use the component for both leading and trailing wings in every state. Keep Teleprompter integrated with its existing single body mask so its approved appearance does not double-tint.

**Step 4:** Run the focused suites, build, restart the live route, and inspect Idle-hover, Recording, and Teleprompter for material parity and unchanged Teleprompter geometry.

No commit or push is included.
