# QA Testing

Use VoiceLayer with Playwright for hands-free website testing. The agent browses pages, asks you what you see, and captures your observations in structured checklists.

## How It Works

1. Agent navigates to a page using Playwright MCP
2. Agent asks voice questions: *"How does the hero section look?"*
3. You speak your observations: *"The image is stretched on mobile"*
4. Agent logs findings using think mode (silent notes)
5. At the end, a structured markdown report is generated

## Typical Session Flow

```
Agent: qa_voice_announce("Starting QA session for the checkout page")
Agent: [navigates to /checkout with Playwright]
Agent: qa_voice_converse("How does the form layout look?")
User:  "The credit card fields are misaligned, the expiry date wraps to a second line"
Agent: qa_voice_think({ thought: "CC fields misaligned, expiry wraps", category: "red-flag" })
Agent: qa_voice_converse("What about the submit button?")
User:  "Looks good, centered, correct color"
Agent: qa_voice_think({ thought: "Submit button: PASS", category: "checklist-update" })
Agent: qa_voice_brief("Session complete. Found 1 issue: credit card field alignment on the checkout form.")
```

## QA Categories

VoiceLayer includes predefined QA schemas covering 6 categories and 31 checks:

| Category | Checks | Examples |
|----------|--------|---------|
| **Layout** | Responsive, alignment, spacing | Grid breaks, overflow, z-index |
| **Navigation** | Links, menus, breadcrumbs | Dead links, mobile nav, active states |
| **Forms** | Validation, labels, errors | Required fields, error messages, tab order |
| **Content** | Text, images, media | Typos, alt text, broken images |
| **Performance** | Load time, animations | Slow renders, janky scrolling |
| **Accessibility** | Contrast, screen readers, focus | Color contrast, ARIA labels, keyboard nav |

## Report Generation

After a QA session, findings are compiled into a structured markdown report:

```markdown
# QA Report: Checkout Page
Date: 2026-02-21
URL: https://example.com/checkout

## Issues Found

### HIGH: Credit card field alignment
- **Category:** Layout
- **Details:** Expiry date field wraps to second line on viewport < 768px
- **Suggested fix:** Reduce input width or stack vertically on mobile

## Passed Checks
- Submit button: centered, correct color
- Form labels: all present and clear
```

Reports are saved to `~/.voicelayer/reports/` by default.

## Agent Configuration

To use QA testing, your Claude Code session needs both VoiceLayer and Playwright MCP servers:

```json
{
  "mcpServers": {
    "qa-voice": {
      "command": "bun",
      "args": ["run", "/path/to/voicelayer/src/mcp-server.ts"]
    },
    "playwright": {
      "command": "npx",
      "args": ["@anthropic-ai/mcp-playwright"]
    }
  }
}
```

## Tips

- **Use think mode liberally** — silent notes don't interrupt the testing flow
- **Start with announce** — give context before diving into questions
- **End with brief** — summarize findings so the user has a verbal recap
- **Keep questions specific** — "How does the form look?" works better than "Any issues?"
