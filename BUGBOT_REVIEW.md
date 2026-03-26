# Bug Review: edge-tts Health Check and Retry Logic

## Executive Summary

**Status**: ✅ **APPROVED WITH MINOR RECOMMENDATIONS**

This PR adds robust retry logic and health checking for edge-tts, addressing random failures (exit code 2) that crash `voice_speak` and `voice_ask`. The implementation is solid and well-tested.

**Key Findings**:
1. ✅ **Core implementation is correct** - Retry logic properly handles failures
2. ✅ **Good test coverage** - 5 new tests covering all major scenarios
3. 🟡 **Health check defined but unused** - `checkEdgeTTSHealth()` is never called in production code
4. 🟢 **Proper error handling** - Returns structured results instead of throwing
5. 🟢 **Good defensive programming** - Cleanup on failure, proper resource management

---

## Critical Issues

**None found.** The code is production-ready.

---

## Medium Issues

### 🟡 Issue #1: Health Check Function Not Used in Production

**Files**: 
- `src/tts-health.ts:26` (defines `checkEdgeTTSHealth()`)
- `src/tts.ts` (never calls it)

**Problem**: The `checkEdgeTTSHealth()` function is implemented and tested but never called in production code. The PR description mentions "health check (cached 60s)" but it's not actually being used.

**Current Flow**:
```typescript
// tts.ts line 300
const result = await synthesizeWithRetry(text, voice, rate, audioFile, scriptPath);
// No health check before calling synthesizeWithRetry
```

**Analysis**:
The health check could be useful for:
1. **Early failure detection** - Fail fast if edge-tts is not installed
2. **Better error messages** - Tell user to install edge-tts before attempting synthesis
3. **Avoiding unnecessary retries** - Don't retry if the module isn't installed

However, the current implementation works fine without it because:
- `synthesizeWithRetry()` will fail quickly if edge-tts is missing
- The error message already includes installation instructions
- Retrying on "module not found" is harmless (just wastes ~100ms)

**Recommendation**:
Either:
1. **Add health check before synthesis** (preferred):
```typescript
// In tts.ts, before calling synthesizeWithRetry
if (!checkEdgeTTSHealth()) {
  throw new Error("edge-tts not installed. Run: pip3 install edge-tts");
}
```

2. **Remove the health check function** if it's not needed:
   - Remove `checkEdgeTTSHealth()` and related code
   - Remove the 3 health check tests
   - Update PR description

3. **Document it's for future use** - Add comment explaining why it exists

**Impact**: Low - Current code works fine, this is just unused code

---

### 🟡 Issue #2: Inconsistent Retry Count Reporting

**File**: `src/tts-health.ts:101-146`

**Problem**: The retry loop and attempt counting could be clearer.

**Current Code**:
```typescript
for (let attempt = 0; attempt <= maxRetries; attempt++) {
  if (attempt > 0) {
    console.error(`[voicelayer] edge-tts retry ${attempt}/${maxRetries} for: ...`);
  }
  // ... synthesis ...
}
```

**Analysis**:
- With `maxRetries = 1`, the loop runs for `attempt = 0` and `attempt = 1` (2 total attempts)
- The log message says "retry 1/1" which is correct for the retry count
- But `result.attempts` returns `attempt + 1`, which is 2 (total attempts, not retries)
- This is semantically correct but could be confusing

**Example**:
- First attempt fails → logs nothing
- Second attempt fails → logs "retry 1/1"
- Returns `{ attempts: 2 }` ✅ Correct (2 total attempts)

**Recommendation**: 
Add a comment clarifying the distinction between "retries" and "attempts":
```typescript
// attempts = total tries (original + retries)
// maxRetries = number of additional tries after first failure
for (let attempt = 0; attempt <= maxRetries; attempt++) {
```

**Impact**: Very Low - Code is correct, just potentially confusing

---

## Minor Issues

### 🟢 Issue #3: Potential Race Condition in Health Check Cache

**File**: `src/tts-health.ts:19-49`

**Observation**: The health check cache uses module-level variables without synchronization:
```typescript
let healthCacheResult: boolean | null = null;
let healthCacheTime = 0;

export function checkEdgeTTSHealth(): boolean {
  const now = Date.now();
  if (healthCacheResult !== null && now - healthCacheTime < HEALTH_CACHE_TTL_MS) {
    return healthCacheResult;  // Cache hit
  }
  // ... spawn subprocess and update cache ...
}
```

**Analysis**: 
If multiple concurrent calls to `checkEdgeTTSHealth()` occur when the cache is expired, they might all spawn `python3` subprocesses simultaneously. However:

1. **In practice, this is not an issue** because:
   - `checkEdgeTTSHealth()` is currently unused in production
   - Even if used, TTS calls are typically serialized (playback queue)
   - `Bun.spawnSync()` is synchronous, so the function completes before returning
   - The race window is tiny (~50ms for the subprocess)

2. **Worst case**: Multiple `python3` processes spawn simultaneously
   - No data corruption (each sets the same cache value)
   - Minor performance impact (wasted subprocess spawns)
   - Self-correcting (cache gets set by first completion)

**Recommendation**: 
If health check is integrated into production and high concurrency is expected, consider adding a simple lock:
```typescript
let healthCheckInProgress = false;

export function checkEdgeTTSHealth(): boolean {
  // ... cache check ...
  
  if (healthCheckInProgress) {
    // Another check is in progress, return cached or default
    return healthCacheResult ?? false;
  }
  
  healthCheckInProgress = true;
  try {
    // ... spawn subprocess ...
  } finally {
    healthCheckInProgress = false;
  }
}
```

**Impact**: Very Low - Current code is fine for typical usage patterns

---

### 🟢 Issue #5: Metadata File Cleanup on Success

**File**: `src/tts-health.ts:125-129`

**Observation**: The metadata file is cleaned up in the success path:
```typescript
if (lastExitCode === 0) {
  const wordBoundaries = parseWordBoundaries(metadataFile);
  try {
    unlinkSync(metadataFile);  // ✅ Good
  } catch {}
  return { success: true, ... };
}
```

But also in the failure path:
```typescript
// All retries exhausted
try {
  unlinkSync(metadataFile);  // ✅ Also good
} catch {}
```

**Analysis**: This is actually **correct** - the file might not exist on failure, but we try to clean it up anyway. The `try/catch` prevents errors if the file doesn't exist.

**Verdict**: ✅ No issue - proper resource cleanup

---

### 🟢 Issue #6: Error Message Includes Last Exit Code

**File**: `src/tts-health.ts:157`

**Observation**: The error message includes the last exit code:
```typescript
error: `edge-tts failed after ${maxRetries + 1} attempts (last exit code: ${lastExitCode}). Is edge-tts installed? Run: pip3 install edge-tts`,
```

**Analysis**: This is **good** - helps with debugging. Exit code 2 typically means network/rate limiting, while exit code 1 might mean module not found.

**Verdict**: ✅ No issue - helpful for debugging

---

### 🟢 Issue #7: Word Boundary Parsing Error Handling

**File**: `src/tts-health.ts:66-84`

**Observation**: The `parseWordBoundaries()` function returns an empty array on any error:
```typescript
function parseWordBoundaries(metadataFile: string): WordBoundary[] {
  try {
    // ... parsing logic ...
  } catch {
    return [];  // Silent failure
  }
}
```

**Analysis**: This is **correct** for this use case:
- Word boundaries are optional metadata for UI features (teleprompter)
- If parsing fails, TTS should still work (just without word highlighting)
- The audio file is the primary output, not the metadata

**Recommendation**: Consider logging a warning on parse failure:
```typescript
} catch (err) {
  console.error(`[voicelayer] Failed to parse word boundaries: ${err}`);
  return [];
}
```

**Impact**: Very Low - Current behavior is acceptable

---

## Test Coverage Analysis

### ✅ Well-Covered Scenarios

1. **Health check returns true when installed** ✅
2. **Health check returns false when not found** ✅
3. **Health check caching works** ✅
4. **Retry succeeds on second attempt** ✅
5. **Retry fails after max retries** ✅

### 🟡 Missing Test Scenarios

1. **Integration test**: Call `synthesizeEdgeChunk()` from `tts.ts` to verify end-to-end flow
2. **Network timeout**: Simulate edge-tts hanging (not exiting) - does it timeout?
3. **Partial file write**: What if edge-tts writes a corrupt MP3 file?
4. **Concurrent calls**: Multiple `synthesizeWithRetry()` calls at once - does caching work correctly?

**Recommendation**: These are edge cases and not critical for initial release. Current test coverage is sufficient.

---

## Code Quality Observations

### ✅ Positive Aspects

1. **Structured error handling** - Returns result objects instead of throwing
2. **Proper resource cleanup** - Metadata files cleaned up in all paths
3. **Good logging** - Clear messages for debugging
4. **Caching** - Health check cached for 60s to avoid repeated subprocess spawns
5. **Type safety** - Proper TypeScript interfaces for results
6. **Retry strategy** - Conservative (only 1 retry) to avoid long delays
7. **Test quality** - Good mocking, proper cleanup, clear test names

### 🟢 Minor Style Suggestions

1. **Line 103**: Consider extracting the log message to a constant:
```typescript
const MAX_TEXT_LOG_LENGTH = 50;
console.error(`[voicelayer] edge-tts retry ${attempt}/${maxRetries} for: "${text.slice(0, MAX_TEXT_LOG_LENGTH)}..."`);
```

2. **Line 98**: The `metadataFile` variable could be `const`:
```typescript
const metadataFile = audioFile.replace(".mp3", ".meta.ndjson");
```

3. **Type annotation**: The `SynthesizeResult` interface could use JSDoc:
```typescript
/**
 * Result of edge-tts synthesis with retry.
 * @property success - Whether synthesis succeeded
 * @property attempts - Total number of attempts (original + retries)
 * @property audioFile - Path to synthesized MP3 (only on success)
 * @property wordBoundaries - Parsed word timing metadata (only on success)
 * @property error - Error message (only on failure)
 */
interface SynthesizeResult { ... }
```

---

## Integration Analysis

### ✅ Proper Integration with `tts.ts`

**File**: `src/tts.ts:293-322`

The integration is clean:

```typescript
async function synthesizeEdgeChunk(...): Promise<SynthesizedChunk> {
  const result = await synthesizeWithRetry(text, voice, rate, audioFile, scriptPath);
  
  if (!result.success) {
    throw new Error(result.error || "edge-tts synthesis failed after retries");
  }
  
  const durationMs = Math.max(
    probeAudioDurationMs(audioFile) ?? 0,
    inferBoundaryEndMs(result.wordBoundaries || []),
  );
  
  return {
    audioFile,
    wordBoundaries: result.wordBoundaries || [],
    durationMs,
  };
}
```

**Analysis**:
- ✅ Proper error propagation (throws on failure)
- ✅ Handles optional word boundaries with `|| []`
- ✅ Maintains backward compatibility (same return type)
- ✅ No breaking changes to existing code

---

## Backward Compatibility

### ✅ No Breaking Changes

1. **Function signature unchanged**: `synthesizeEdgeChunk()` still returns `Promise<SynthesizedChunk>`
2. **Error behavior unchanged**: Still throws on failure (just with better error messages)
3. **Word boundaries still optional**: Empty array fallback maintained
4. **No new dependencies**: Uses existing Bun APIs

---

## Performance Impact

### ✅ Minimal Performance Impact

**Success case (no retry needed)**:
- No additional overhead (just one extra function call)
- Same execution time as before

**Failure case (retry triggered)**:
- Adds ~1-2 seconds for one retry attempt
- Better than crashing and requiring manual intervention

**Health check caching**:
- 60-second cache prevents repeated subprocess spawns
- First call: ~50ms overhead (spawn python3)
- Subsequent calls: ~0.1ms (cache hit)

**Note**: Health check is currently unused, so no performance impact in production.

---

## Security Considerations

### ✅ No Security Issues

1. **No user input in subprocess** - All parameters are validated/sanitized by caller
2. **No shell injection** - Uses array syntax for `Bun.spawn()` (not shell string)
3. **File paths are controlled** - Generated by `ttsFilePath()` function
4. **No credential exposure** - No API keys or secrets involved

---

## Recommendations Summary

### Must Fix Before Merge
**None** - Code is production-ready as-is.

### Should Consider (Non-Blocking)

1. **Use or remove health check** - Either call `checkEdgeTTSHealth()` before synthesis or remove it
2. **Add clarifying comments** - Document retry vs. attempt counting
3. **Add warning on parse failure** - Log when word boundary parsing fails

### Nice to Have

4. **Add integration test** - Test full flow through `tts.ts`
5. **Add JSDoc comments** - Document `SynthesizeResult` interface
6. **Extract magic numbers** - `MAX_TEXT_LOG_LENGTH`, `HEALTH_CACHE_TTL_MS` are good, add more

---

## Testing Checklist

Before merging, manually verify:

- [x] 312 tests pass (verified in test run)
- [ ] Manual: Kill edge-tts mid-synthesis - should retry and succeed
- [ ] Manual: Uninstall edge-tts - should fail gracefully with clear error
- [ ] Manual: Trigger rate limiting - should retry once then fail with helpful message
- [ ] Manual: Call `voice_speak` 10 times rapidly - should queue properly

---

## Verdict

**Status**: ✅ **APPROVED**

The PR successfully addresses the edge-tts reliability issue with a clean, well-tested implementation. The retry logic is conservative (1 retry) and properly handles failures. The only notable issue is that the health check function is defined but never used - this should either be integrated or removed for code cleanliness.

**The code is production-ready and can be merged as-is.** The recommendations above would improve code quality but are not blockers.

---

## Files Reviewed

- ✅ `src/tts-health.ts` - New health check and retry module
- ✅ `src/tts.ts` - Integration with existing TTS code
- ✅ `src/__tests__/edge-tts-retry.test.ts` - Test coverage
- ✅ `src/socket-protocol.ts` - Protocol changes (unrelated to this feature)
- ✅ `src/voice-bar-launcher.ts` - Launcher changes (unrelated to this feature)
- ✅ `flow-bar/` Swift changes - VoiceBar app changes (unrelated to this feature)

---

*Review conducted by @bugbot - Automated code review agent*  
*Focus: Bug detection, error handling, edge cases, and code quality*
