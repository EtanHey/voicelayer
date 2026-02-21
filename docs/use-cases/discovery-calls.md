# Discovery Calls

Use VoiceLayer as a client discovery call assistant. The agent asks structured questions, tracks unknowns, detects red flags, and generates project briefs — all through voice interaction.

## How It Works

1. Agent greets the client via announce mode
2. Agent asks discovery questions using converse mode
3. While the client speaks, agent silently notes insights and flags via think mode
4. Agent follows up on unknowns with targeted questions
5. At the end, a structured project brief is generated

## Typical Session Flow

```
Agent: qa_voice_announce("Starting discovery call for the e-commerce project")
Agent: qa_voice_converse("Can you walk me through the main goals for this project?")
User:  "We need a Shopify replacement. Current store is too slow and we want custom checkout."
Agent: qa_voice_think({ thought: "Shopify migration, performance + custom checkout are key drivers", category: "insight" })
Agent: qa_voice_converse("What's your timeline looking like?")
User:  "We need it live by April, there's a big sale event"
Agent: qa_voice_think({ thought: "Hard deadline April - sale event. Tight timeline.", category: "red-flag" })
Agent: qa_voice_converse("How many products are in your current catalog?")
User:  "Around 5000 SKUs with variants"
Agent: qa_voice_think({ thought: "5000 SKUs + variants = significant data migration", category: "insight" })
Agent: qa_voice_brief("Great conversation. Key takeaways: Shopify migration focused on performance and custom checkout, 5000 SKUs to migrate, hard April deadline for a sale event.")
```

## Discovery Categories

VoiceLayer includes predefined discovery schemas covering 7 categories and 23 questions:

| Category | Focus | Example Questions |
|----------|-------|-------------------|
| **Goals** | Business objectives | What problem are you solving? |
| **Users** | Target audience | Who are the primary users? |
| **Technical** | Stack and constraints | What's the current tech stack? |
| **Timeline** | Deadlines and phases | When does this need to be live? |
| **Budget** | Resources and constraints | What's the budget range? |
| **Competition** | Market position | Who are your competitors? |
| **Success** | Metrics and KPIs | How will you measure success? |

## Project Brief Generation

After a discovery call, findings are compiled into a project brief:

```markdown
# Project Brief: E-Commerce Migration
Date: 2026-02-21
Client: Example Corp

## Overview
Migration from Shopify to custom e-commerce platform.
Focus: performance optimization and custom checkout flow.

## Key Requirements
- Custom checkout with multi-step flow
- 5000+ SKU catalog migration with variants
- Performance: sub-2s page loads

## Red Flags
- Hard April deadline (sale event) — tight for scope
- No existing API documentation for current Shopify customizations

## Unknowns
- Payment processor preference (Stripe? PayPal?)
- Hosting requirements (cloud provider, region)

## Suggested Next Steps
1. Technical audit of current Shopify store
2. Data migration proof-of-concept (100 SKUs)
3. Checkout flow wireframes for approval
```

Briefs are saved to `~/.voicelayer/briefs/` by default.

## Live Thinking Log

During the call, the agent's think notes are written to `/tmp/voicelayer-thinking.md`. Open this in a split-screen editor to see real-time insights:

```bash
# In another terminal, watch the thinking log
tail -f /tmp/voicelayer-thinking.md
```

This lets you glance at the agent's observations without interrupting the conversation.

## Tips

- **Don't rush** — set longer `timeout_seconds` (600+) for discovery calls
- **Use think for red flags** — the `red-flag` category makes concerns easy to find later
- **Consult before ending** — "I think we've covered the main topics. Anything else?" via consult mode
- **Review the thinking log** after the call — it often catches things you missed
