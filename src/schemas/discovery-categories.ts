/**
 * Discovery call category templates.
 *
 * Each category has questions to track during a client call.
 * voice_prompt = what the AI whispers to you during the call.
 */

import type { DiscoveryCategory } from "./discovery";

export interface DiscoveryTemplate {
  category: DiscoveryCategory;
  question: string;
  voice_prompt: string;
}

export const SCOPE_QUESTIONS: DiscoveryTemplate[] = [
  {
    category: "scope",
    question: "What type of project is this?",
    voice_prompt: "Ask what exactly they want built. Website, app, or both?",
  },
  {
    category: "scope",
    question: "Is this a new project or updating existing?",
    voice_prompt: "Find out if this is greenfield or building on something existing.",
  },
  {
    category: "scope",
    question: "Who are the end users?",
    voice_prompt: "Ask who will be using this. What's their target audience?",
  },
  {
    category: "scope",
    question: "What's the core problem this solves?",
    voice_prompt: "Try to understand the business problem, not just the feature list.",
  },
];

export const TECHNICAL_QUESTIONS: DiscoveryTemplate[] = [
  {
    category: "technical",
    question: "Any technology preferences or constraints?",
    voice_prompt: "Ask if they have a preferred stack or existing tech they need to integrate with.",
  },
  {
    category: "technical",
    question: "What third-party integrations are needed?",
    voice_prompt: "Good time to ask about payment providers, CRMs, APIs they need to connect to.",
  },
  {
    category: "technical",
    question: "Where should this be hosted?",
    voice_prompt: "Ask about hosting preferences. Do they have existing infrastructure?",
  },
  {
    category: "technical",
    question: "What about authentication and user accounts?",
    voice_prompt: "Does this need user login? What kind of auth?",
  },
];

export const DESIGN_QUESTIONS: DiscoveryTemplate[] = [
  {
    category: "design",
    question: "Do they have brand guidelines or a design system?",
    voice_prompt: "Ask if they have a style guide, logos, brand colors ready.",
  },
  {
    category: "design",
    question: "Are there design files or wireframes?",
    voice_prompt: "Find out if they have Figma files or mockups already.",
  },
  {
    category: "design",
    question: "Any reference sites they like?",
    voice_prompt: "Ask for examples of websites they like the look and feel of.",
  },
];

export const CONTENT_QUESTIONS: DiscoveryTemplate[] = [
  {
    category: "content",
    question: "Who provides the content (text and images)?",
    voice_prompt: "Ask who's writing the copy and providing images.",
  },
  {
    category: "content",
    question: "Is a CMS needed for content management?",
    voice_prompt: "Do they need to update content themselves after launch?",
  },
  {
    category: "content",
    question: "Multi-language support needed?",
    voice_prompt: "Ask if the site needs to work in multiple languages.",
  },
];

export const BUDGET_QUESTIONS: DiscoveryTemplate[] = [
  {
    category: "budget",
    question: "What's the budget range?",
    voice_prompt: "Now's a good time to ask about budget. Even a rough range helps.",
  },
  {
    category: "budget",
    question: "What's the deadline or desired launch date?",
    voice_prompt: "Ask when they need this live. Is the date flexible?",
  },
  {
    category: "budget",
    question: "How do they prefer to handle payments?",
    voice_prompt: "Ask about payment terms. Milestone-based or monthly retainer?",
  },
];

export const PROCESS_QUESTIONS: DiscoveryTemplate[] = [
  {
    category: "process",
    question: "How do they prefer to communicate?",
    voice_prompt: "Ask if they prefer Slack, email, or weekly calls for updates.",
  },
  {
    category: "process",
    question: "Who's the decision-maker?",
    voice_prompt: "Important: who actually signs off on decisions? Just them or a team?",
  },
  {
    category: "process",
    question: "How many review rounds expected?",
    voice_prompt: "Ask about their review process. How many feedback rounds do they expect?",
  },
];

export const COMPETITIVE_QUESTIONS: DiscoveryTemplate[] = [
  {
    category: "competitive",
    question: "Who are their main competitors?",
    voice_prompt: "Ask who they compete with. Helps understand the market.",
  },
  {
    category: "competitive",
    question: "What differentiates them?",
    voice_prompt: "What makes them different from competitors? Key selling points?",
  },
];

export const ALL_DISCOVERY_CATEGORIES: Record<DiscoveryCategory, DiscoveryTemplate[]> = {
  scope: SCOPE_QUESTIONS,
  technical: TECHNICAL_QUESTIONS,
  design: DESIGN_QUESTIONS,
  content: CONTENT_QUESTIONS,
  budget: BUDGET_QUESTIONS,
  process: PROCESS_QUESTIONS,
  competitive: COMPETITIVE_QUESTIONS,
  "red-flags": [], // Red flags are detected, not prompted
};

export const TOTAL_DISCOVERY_QUESTIONS = Object.values(ALL_DISCOVERY_CATEGORIES).reduce(
  (sum, qs) => sum + qs.length,
  0
);
