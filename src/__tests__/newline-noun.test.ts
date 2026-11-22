import { test, expect } from "bun:test";
import { applyRules } from "../rules-engine";
for (const text of [
"The file is missing its final new line.",
"Keep a new line here.",
"Keep an extra new line here.",
"Check his final new line.",
"Check her final new line.",
"Check each final new line.",
"The end new line",
"The problem is the parser's new line handling.",
"The output is the same new line every time.",
"It comes with the default new line behavior.",
"The diff is the Windows new line, not Unix.",
"The culprit is the CRLF new line, honestly.",
'The error is the "new line" token.',
// Ambiguous list cues retain words rather than override noun protections.
"The first thing is the parser, new line, the second is storage.",
"We start with the parser, new line, then storage.",
"We got the parser, new line, then storage.",
]) test(text, () => expect(applyRules(text)).toContain("new line"));
for (const text of [
"Alpha, new line, beta.",
]) test(text, () => expect(applyRules(text)).toContain("\n"));
