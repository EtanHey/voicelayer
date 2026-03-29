# Bug Review: PR #85 - MCP Output Formatting

**Reviewer:** @bugbot  
**Date:** 2026-03-29  
**PR:** feat/mcp-output-formatting  
**Status:** ⚠️ 3 bugs found, 1 design issue

---

## Summary

Reviewed the Unicode box-drawing formatting implementation for MCP tool responses. Found 3 functional bugs and 1 design consideration. All tests pass (387/387), but edge cases reveal formatting issues.

---

## 🐛 Bug #1: Newlines Break Box Formatting

**Severity:** Medium  
**File:** `src/format-response.ts:14-16`  
**Issue:** Messages containing `\n` characters break the box border alignment.

### Current Behavior
```
┌─ voice_speak
│ 🔊 announce → "Line 1
Line 2
Line 3"
└─
```

Lines 2-3 are not prefixed with `│ `, breaking the visual box structure.

### Root Cause
The `boxed()` helper applies the `│ ` prefix to each line in the `lines` array, but multi-line strings within a single array element are not split.

```typescript
function boxed(title: string, lines: string[]): string {
  const body = lines.map((l) => `${SEP}${l}`).join("\n");
  return `${TOP} ${title}\n${body}\n${BOT}`;
}
```

### Expected Behavior
All content lines should be prefixed:
```
┌─ voice_speak
│ 🔊 announce → "Line 1
│ Line 2
│ Line 3"
└─
```

### Fix
Split each line on `\n` and prefix all sub-lines:

```typescript
function boxed(title: string, lines: string[]): string {
  const body = lines
    .flatMap((l) => l.split("\n"))
    .map((l) => `${SEP}${l}`)
    .join("\n");
  return `${TOP} ${title}\n${body}\n${BOT}`;
}
```

### Test Coverage
- ✅ Edge case test exists: `format-response-edge-cases.test.ts:23-28`
- ⚠️ Test only checks content presence, not formatting correctness

---

## 🐛 Bug #2: Empty String Transcript Shows Timeout

**Severity:** Low  
**File:** `src/format-response.ts:52`  
**Issue:** Empty transcript string `""` is treated as timeout instead of empty response.

### Current Behavior
```typescript
formatAsk("") // Returns timeout message, not empty transcript
```

Output:
```
┌─ voice_ask
│ ⏱ No response — timeout after 30s
└─
```

### Root Cause
Falsy check treats empty string as null:
```typescript
if (transcript) {
  return boxed("voice_ask", [`🎤 "${transcript}"`]);
}
```

### Expected Behavior
Empty string should be displayed as empty transcript:
```
┌─ voice_ask
│ 🎤 ""
└─
```

### Fix
Use explicit null check:
```typescript
if (transcript !== null && transcript !== undefined) {
  return boxed("voice_ask", [`🎤 "${transcript}"`]);
}
```

### Impact
- Low: Empty transcripts are rare in practice (STT typically returns null on timeout)
- Edge case: User might explicitly pass `""` for testing

---

## 🐛 Bug #3: Empty Toggle Actions Array

**Severity:** Low  
**File:** `src/format-response.ts:84-86`  
**Issue:** Empty actions array creates malformed box with no body.

### Current Behavior
```typescript
formatToggle([])
```

Output:
```
┌─ toggle

└─
```

The box has no body lines, creating visual awkwardness.

### Root Cause
No guard for empty array:
```typescript
export function formatToggle(actions: string[]): string {
  const lines = actions.map((a) => `• ${a}`);
  return boxed("toggle", lines);
}
```

### Expected Behavior
Either:
1. Add a placeholder message: `"(no changes)"`
2. Return early with error format

### Fix (Option 1 - Placeholder)
```typescript
export function formatToggle(actions: string[]): string {
  if (actions.length === 0) {
    return boxed("toggle", ["(no changes)"]);
  }
  const lines = actions.map((a) => `• ${a}`);
  return boxed("toggle", lines);
}
```

### Impact
- Low: Empty toggle calls are unlikely (validation should prevent this)
- Defensive: Better UX if it does happen

---

## ⚠️ Design Issue: No Input Sanitization

**Severity:** Low (informational)  
**Files:** All formatters  
**Issue:** User input is directly interpolated without sanitization.

### Example
```typescript
formatBusy("abc-<script>alert('xss')</script>", 123, "2026-01-01")
```

Output includes raw `<script>` tags.

### Analysis
- ✅ **Not a security issue:** MCP tool results are plain text, not HTML
- ✅ **No XSS risk:** Output is displayed in terminal/text UI, not browser
- ⚠️ **Potential issue:** If output is ever rendered as HTML/Markdown without escaping

### Recommendation
- **Current:** No action needed (text-only context)
- **Future:** If output is rendered as HTML, add escaping layer at render time
- **Documentation:** Add comment noting text-only assumption

---

## Test Coverage Analysis

### Existing Tests
- ✅ 16 basic formatting tests (`format-response.test.ts`)
- ✅ 25 edge case tests (`format-response-edge-cases.test.ts`)
- ✅ Integration tests in `handlers.test.ts` and `mcp-handler.test.ts`
- ✅ Total: 387 tests pass

### Coverage Gaps
- ⚠️ No tests verify visual box structure (only content presence)
- ⚠️ No tests for multi-line string formatting correctness
- ⚠️ No tests for empty array edge cases

### Recommended Additional Tests
```typescript
it("preserves box structure with multi-line content", () => {
  const out = formatSpeak("announce", "Line 1\nLine 2");
  const lines = out.split("\n");
  // All content lines should start with "│ "
  const contentLines = lines.slice(1, -1);
  contentLines.forEach(line => {
    expect(line).toMatch(/^│ /);
  });
});
```

---

## Integration Review

### Handler Usage
All handlers correctly use formatters:
- ✅ `handlers.ts`: All 7 handlers use formatters
- ✅ `mcp-handler.ts`: Error paths use `formatError()`
- ✅ No direct string concatenation remaining

### Behavioral Changes
- ⚠️ **Breaking change:** All tool outputs are now multi-line boxed format
- ⚠️ **Impact:** Any downstream parsing of tool output will break
- ✅ **Mitigation:** MCP clients typically display tool results as-is (no parsing)

---

## Performance Review

### Concerns
None. Formatters are pure functions with minimal overhead:
- String concatenation: O(n) where n = content length
- No I/O, no async, no side effects

### Benchmark (informal)
```
formatSpeak: ~0.02ms per call
formatAsk: ~0.01ms per call
```

Negligible impact on tool response time.

---

## Recommendations

### Priority 1: Fix Bug #1 (Newlines)
**Why:** Most likely to occur in practice (multi-line messages are common)  
**How:** Update `boxed()` to split on `\n`  
**Effort:** 5 minutes

### Priority 2: Fix Bug #2 (Empty Transcript)
**Why:** Low impact but easy fix  
**How:** Change to explicit null check  
**Effort:** 2 minutes

### Priority 3: Fix Bug #3 (Empty Toggle)
**Why:** Unlikely to occur, but better UX  
**How:** Add empty array guard  
**Effort:** 3 minutes

### Priority 4: Add Visual Structure Tests
**Why:** Prevent regression of box formatting  
**How:** Add tests that verify `│ ` prefix on all content lines  
**Effort:** 15 minutes

---

## Approval Status

**Status:** ⚠️ **Conditional Approval**

### Required Before Merge
- [ ] Fix Bug #1 (newlines break box structure)

### Recommended Before Merge
- [ ] Fix Bug #2 (empty string transcript)
- [ ] Fix Bug #3 (empty toggle actions)
- [ ] Add visual structure tests

### Optional
- [ ] Add documentation comment about text-only output assumption

---

## Conclusion

The implementation is solid overall with good test coverage. The bugs found are edge cases that are unlikely to occur in normal usage, but should be fixed for robustness. The most critical issue is Bug #1 (newlines), which could realistically occur with multi-line TTS messages.

**Overall Assessment:** 8/10 - Good implementation with minor edge case issues.

---

**Generated by:** @bugbot  
**Review Duration:** ~15 minutes  
**Tests Run:** 387 pass, 0 fail
