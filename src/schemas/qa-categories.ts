/**
 * QA category templates — structured check lists per category.
 *
 * Each category has ~5-8 checks to run on every page.
 * These are the QUESTIONS the QA agent asks about each page.
 */

import type { QACategory, Severity } from "./checklist";

export interface CheckTemplate {
  category: QACategory;
  question: string;
  severity: Severity;
  voice_prompt: string; // Natural speech version of the question
}

export const ACCESSIBILITY_CHECKS: CheckTemplate[] = [
  {
    category: "accessibility",
    question: "Do all form inputs have visible labels or ARIA labels?",
    severity: "high",
    voice_prompt:
      "Looking at the form inputs on this page. Do all the fields have proper labels?",
  },
  {
    category: "accessibility",
    question: "Is the heading hierarchy correct (h1 > h2 > h3, no skips)?",
    severity: "medium",
    voice_prompt:
      "Checking the heading structure. Are the headings in the right order, no skipping levels?",
  },
  {
    category: "accessibility",
    question: "Can all interactive elements be reached via keyboard tab?",
    severity: "high",
    voice_prompt:
      "Testing keyboard navigation. Can you tab through all the buttons and links?",
  },
  {
    category: "accessibility",
    question: "Do focus indicators appear on interactive elements?",
    severity: "medium",
    voice_prompt:
      "When you tab through elements, can you see a clear focus indicator on each one?",
  },
  {
    category: "accessibility",
    question: "Do all images have descriptive alt text?",
    severity: "medium",
    voice_prompt:
      "Checking images. Do they all have meaningful alt text, not just empty or generic labels?",
  },
  {
    category: "accessibility",
    question: "Is the color contrast sufficient for all text (WCAG AA)?",
    severity: "high",
    voice_prompt:
      "Looking at the text contrast. Is everything readable, especially lighter text on light backgrounds?",
  },
];

export const RESPONSIVE_CHECKS: CheckTemplate[] = [
  {
    category: "responsive",
    question: "Does the layout adapt correctly at this viewport?",
    severity: "high",
    voice_prompt:
      "At this screen size, does the layout look right? Any overlapping or misaligned elements?",
  },
  {
    category: "responsive",
    question: "Is there any horizontal overflow or horizontal scroll?",
    severity: "high",
    voice_prompt:
      "Can you see any horizontal scrolling? Elements going off-screen to the right?",
  },
  {
    category: "responsive",
    question: "Is text readable without zooming?",
    severity: "medium",
    voice_prompt:
      "Is all the text large enough to read comfortably at this size?",
  },
  {
    category: "responsive",
    question: "Are touch targets at least 44x44px on mobile?",
    severity: "medium",
    voice_prompt:
      "On mobile, are the buttons and links big enough to tap easily?",
  },
  {
    category: "responsive",
    question: "Does the navigation work at this viewport?",
    severity: "high",
    voice_prompt:
      "How does the navigation behave at this screen size? Does it collapse to a hamburger menu on mobile?",
  },
  {
    category: "responsive",
    question: "Do images scale properly without distortion?",
    severity: "medium",
    voice_prompt:
      "Are the images scaling properly? No stretching or cropping issues?",
  },
];

export const CONTENT_CHECKS: CheckTemplate[] = [
  {
    category: "content",
    question: "Is there any placeholder or lorem ipsum text?",
    severity: "high",
    voice_prompt:
      "Do you see any placeholder text or lorem ipsum anywhere on this page?",
  },
  {
    category: "content",
    question: "Are there any spelling or grammar errors?",
    severity: "medium",
    voice_prompt:
      "Reading through the text. Do you notice any spelling mistakes or grammar issues?",
  },
  {
    category: "content",
    question: "Are all links functional (no 404s or dead links)?",
    severity: "high",
    voice_prompt:
      "Let me check the links on this page. Any of them broken or leading to error pages?",
  },
  {
    category: "content",
    question: "Are all images loading correctly?",
    severity: "high",
    voice_prompt:
      "Are all images showing up? Any missing or broken image placeholders?",
  },
  {
    category: "content",
    question: "Is the content hierarchy clear and scannable?",
    severity: "low",
    voice_prompt:
      "Can you scan this page quickly and understand the structure? Is the hierarchy clear?",
  },
];

export const INTERACTION_CHECKS: CheckTemplate[] = [
  {
    category: "interaction",
    question: "Do all buttons have appropriate click/hover states?",
    severity: "low",
    voice_prompt:
      "When you hover over buttons, do they show a visual change? Active states working too?",
  },
  {
    category: "interaction",
    question: "Does form validation work correctly?",
    severity: "high",
    voice_prompt:
      "If you submit a form with empty or wrong data, do you get clear error messages?",
  },
  {
    category: "interaction",
    question: "Do modals and overlays open and close correctly?",
    severity: "medium",
    voice_prompt:
      "If there are any modals or popups, do they open and close properly?",
  },
  {
    category: "interaction",
    question: "Does the navigation route correctly?",
    severity: "high",
    voice_prompt:
      "When you click navigation links, do they go to the right pages?",
  },
  {
    category: "interaction",
    question: "Is scroll behavior smooth and expected?",
    severity: "low",
    voice_prompt:
      "How's the scrolling? Any jumpiness or unexpected behavior?",
  },
];

export const PERFORMANCE_CHECKS: CheckTemplate[] = [
  {
    category: "performance",
    question: "Are images optimized (WebP/AVIF, reasonable file sizes)?",
    severity: "medium",
    voice_prompt:
      "Checking image sizes. Are they using modern formats like WebP? Any oversized images?",
  },
  {
    category: "performance",
    question: "Is lazy loading implemented for below-fold content?",
    severity: "low",
    voice_prompt:
      "Are images below the fold lazy-loaded, or do they all load at once?",
  },
  {
    category: "performance",
    question: "Are there visible layout shifts during loading?",
    severity: "medium",
    voice_prompt:
      "When the page loads, do things jump around? Any content shifting after images load?",
  },
  {
    category: "performance",
    question: "Do animations perform smoothly (no jank)?",
    severity: "low",
    voice_prompt:
      "If there are animations, are they smooth or do they stutter?",
  },
];

export const SEO_CHECKS: CheckTemplate[] = [
  {
    category: "seo",
    question: "Does the page have a meaningful meta title?",
    severity: "medium",
    voice_prompt:
      "Checking the page title in the browser tab. Is it descriptive and not just the site name?",
  },
  {
    category: "seo",
    question: "Does the page have a meta description?",
    severity: "medium",
    voice_prompt:
      "Is there a meta description set for search engines?",
  },
  {
    category: "seo",
    question: "Are Open Graph tags present for social sharing?",
    severity: "low",
    voice_prompt:
      "Would this page look good when shared on social media? Are the OG tags set?",
  },
  {
    category: "seo",
    question: "Is there exactly one h1 per page?",
    severity: "medium",
    voice_prompt:
      "How many h1 headings does this page have? Should be exactly one.",
  },
  {
    category: "seo",
    question: "Is a canonical URL specified?",
    severity: "low",
    voice_prompt:
      "Is there a canonical URL set to avoid duplicate content issues?",
  },
];

/** All check templates grouped by category */
export const ALL_CATEGORIES: Record<QACategory, CheckTemplate[]> = {
  accessibility: ACCESSIBILITY_CHECKS,
  responsive: RESPONSIVE_CHECKS,
  content: CONTENT_CHECKS,
  interaction: INTERACTION_CHECKS,
  performance: PERFORMANCE_CHECKS,
  seo: SEO_CHECKS,
};

/** Total number of checks across all categories */
export const TOTAL_CHECKS = Object.values(ALL_CATEGORIES).reduce(
  (sum, checks) => sum + checks.length,
  0
);
