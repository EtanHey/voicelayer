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
]) test(text, () => expect(applyRules(text)).toContain("new line"));
for (const text of [
"The first thing is the parser, new line, the second is storage.",
"We start with the parser, new line, then storage.",
"We got the parser, new line, then storage.",
"Alpha, new line, beta.",
]) test(text, () => expect(applyRules(text)).toContain("\n"));
