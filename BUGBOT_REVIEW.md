# Bug Review: voice_ask default timeout 300s → 30s with outer guard

**PR**: fix/voice-ask-default-timeout-30s  
**Reviewer**: @bugbot  
**Date**: 2026-03-26  
**Status**: ✅ **APPROVED** - All issues resolved

## Executive Summary

✅ **APPROVED**

The PR successfully addresses the timeout problem (300s → 30s default) and adds a valuable outer timeout guard. The resource leak issue identified in the initial review has been **fixed in commit 209d4fe**, which properly clears the timer after Promise.race completes.

---

## Issues Found and Resolved

### ✅ FIXED: Resource Leak in Outer Timeout Guard

**Location**: `src/handlers.ts:301-318`  
**Status**: **RESOLVED in commit 209d4fe**

**Original Issue**: The `setTimeout` in `timeoutPromise` was never cleared when `converseFlow()` completed successfully, creating a resource leak.

**Fix Applied**:
```typescript
let timer: ReturnType<typeof setTimeout>;
const timeoutPromise = new Promise<McpResult>((resolve) => {
  timer = setTimeout(() => {
    console.error(
      `[voicelayer] voice_ask hard timeout after ${outerTimeoutMs / 1000}s`,
    );
    resolve(
      textResult(
        `[converse] Hard timeout after ${Math.round(outerTimeoutMs / 1000)}s. ` +
          "The voice pipeline may be stuck. Try again.",
        true,
      ),
    );
  }, outerTimeoutMs);
});

const result = await Promise.race([converseFlow(), timeoutPromise]);
clearTimeout(timer!);  // ✅ Timer is now properly cleaned up
return result;
```

**Impact**: Prevents spurious error logs and timer accumulation in long-running processes.

---

## Remaining Recommendations

### 🟡 CONSIDER: Timeout Buffer May Be Insufficient

**Location**: `src/handlers.ts:269`  
**Priority**: Medium

**Issue**: The outer timeout is set to `recording_timeout + 15s`, but this may not account for:
1. TTS synthesis time (edge-tts can take 5-10s for long messages)
2. Audio playback time (depends on message length)
3. Transcription time (whisper.cpp can take 2-5s)

**Current Code**:
```typescript
const outerTimeoutMs = (timeoutSeconds + 15) * 1000;
```

**Example Scenario**:
- User calls `voice_ask("Please explain the entire codebase in detail", timeout_seconds=30)`
- TTS synthesis: 8 seconds
- Audio playback: 25 seconds (long message)
- Recording: 30 seconds (user's timeout)
- Transcription: 5 seconds
- **Total: 68 seconds** vs outer timeout of **45 seconds** ⚠️

**Recommendation**: Increase the buffer or make it dynamic:

**Option 1: Conservative Fixed Buffer**
```typescript
const outerTimeoutMs = (timeoutSeconds + 30) * 1000; // 30s buffer instead of 15s
```

**Option 2: Dynamic Buffer Based on Message Length**
```typescript
// Estimate TTS duration: ~150 words/min = 2.5 words/sec
const estimatedTTSDuration = Math.ceil(validated.message.split(/\s+/).length / 2.5);
const outerTimeoutMs = (timeoutSeconds + estimatedTTSDuration + 20) * 1000;
```

**Rationale**: The outer timeout is a safety net for stuck processes, not a strict time limit. A larger buffer reduces false positives while still catching genuine hangs.

---

### 💡 NICE TO HAVE: Extract Magic Number to Named Constant

**Location**: `src/handlers.ts:269`  
**Priority**: Low (code quality)

**Current Code**:
```typescript
const outerTimeoutMs = (timeoutSeconds + 15) * 1000;
```

**Recommendation**:
```typescript
/**
 * Buffer time added to outer timeout guard.
 * Accounts for TTS synthesis (~5s), audio playback (variable), 
 * and transcription (~5s). May need tuning for long messages.
 */
const OUTER_TIMEOUT_BUFFER_SECONDS = 15;

const outerTimeoutMs = (timeoutSeconds + OUTER_TIMEOUT_BUFFER_SECONDS) * 1000;
```

**Benefit**: Makes the timeout calculation self-documenting and easier to tune.

---

### 💡 NICE TO HAVE: Improve Timeout Error Messages

**Location**: `src/handlers.ts:305` and `src/handlers.ts:293-294`  
**Priority**: Low (UX improvement)

**Current Messages**:
- Inner timeout: `"No response received within 30 seconds. The user may have stepped away."`
- Outer timeout: `"Hard timeout after 45s. The voice pipeline may be stuck. Try again."`

**Recommendation**: Make messages more actionable:
- Inner timeout: `"No response received within 30 seconds. If you spoke, try increasing timeout_seconds parameter."`
- Outer timeout: `"Voice pipeline timeout after 45s. This may indicate a system issue. Check logs and try again."`

---

## Code Quality Observations

### ✅ Excellent: Consistent Schema Updates

All three locations updated consistently:
- `src/schemas/mcp-inputs.ts`: `default(30)`, `min(5)`
- `src/mcp-tools.ts`: `default: 30`, `minimum: 5`
- `src/handlers.ts`: `validated.timeout_seconds ?? 30`, `Math.max(..., 5)`

### ✅ Excellent: Test Coverage

`src/__tests__/mcp-schemas.test.ts` updated to expect 30 instead of 300.

**Test Results**: ✅ 323 pass, 0 fail (after installing dependencies)

### ✅ Good: Defensive Programming

The outer timeout guard is a smart safety net for stuck subprocesses (sox, edge-tts, whisper).

### ✅ Good: Reasonable Defaults

- 30s default is much more appropriate than 300s for interactive use
- 5s minimum allows for quick interactions
- 3600s (1 hour) maximum prevents abuse

---

## Test Plan Assessment

✅ **All tests pass**: 323 pass, 0 fail  
⚠️ **Manual testing recommended**: The PR description mentions manual testing is pending

**Recommended Manual Tests**:
1. ✅ Call `voice_ask("test")` with default timeout - should return within ~30s if no speech
2. ✅ Call `voice_ask("test", timeout_seconds=5)` - should timeout quickly
3. ⚠️ Call `voice_ask("very long message...", timeout_seconds=10)` - verify outer timeout doesn't fire prematurely
4. ✅ Let `voice_ask` complete successfully and check logs for spurious timeout errors (should be clean now)

---

## Security Considerations

✅ **No security issues identified**

- Timeout values are properly clamped (5-3600 seconds)
- No injection vectors in timeout handling
- Resource cleanup prevents accumulation attacks

---

## Performance Considerations

✅ **Positive impact**

- Shorter default timeout (30s vs 300s) reduces Claude session hang time
- Timer cleanup prevents memory leaks in long-running processes
- Outer timeout guard prevents indefinite hangs from stuck subprocesses

---

## Breaking Changes

⚠️ **Minor breaking change** (behavioral)

**Impact**: Existing code that relies on the 300s default timeout will now timeout after 30s.

**Mitigation**: Users can explicitly set `timeout_seconds=300` if they need the old behavior.

**Assessment**: This is an **intentional improvement**. The 300s default was clearly too long for interactive use, and the new 30s default is more appropriate. Users who need longer timeouts should explicitly request them.

---

## Documentation

✅ **Adequate**

- PR description clearly explains the rationale
- Tool description updated to reflect new defaults
- Code comments explain the outer timeout guard

**Recommendation**: Consider adding a migration note to CHANGELOG.md:
```markdown
### Changed
- `voice_ask` default timeout reduced from 300s to 30s for better UX
- Minimum timeout lowered from 10s to 5s for quick interactions
- Added outer timeout guard (recording_timeout + 15s) to prevent pipeline hangs
```

---

## Summary

**Overall Assessment**: ✅ **APPROVED**

This is a **high-quality PR** that addresses a real usability problem (5-minute default timeout) and adds valuable defensive programming (outer timeout guard). The resource leak identified in the initial review has been properly fixed.

### What's Great:
1. ✅ Consistent changes across schemas, handlers, and docs
2. ✅ Proper timer cleanup (fixed in 209d4fe)
3. ✅ Good test coverage and all tests pass
4. ✅ Reasonable default values (30s, 5s min)
5. ✅ Smart outer timeout guard for stuck subprocesses

### Optional Improvements:
1. 💡 Consider increasing outer timeout buffer from 15s to 30s
2. 💡 Extract magic number to named constant
3. 💡 Improve timeout error messages for better UX

### Ready to Merge:
✅ Yes - all critical issues resolved, optional improvements can be addressed in follow-up PRs if needed.

---

**Reviewed by**: @bugbot (Claude Sonnet 4.5)  
**Review completed**: 2026-03-26  
**Final verdict**: ✅ APPROVED
