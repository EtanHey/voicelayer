# @bugbot Review Summary - PID Lockfile PR

## Verdict: 🟡 APPROVED WITH CRITICAL FIXES REQUIRED

The orphan MCP server problem is real and this solution is on the right track, but **critical race conditions** must be fixed before merge.

---

## Critical Issues (Must Fix)

### 🔴 #1: No Wait After SIGTERM
**File**: `src/process-lock.ts:83-92`

The code sends SIGTERM but immediately claims the lock without waiting for the process to die. This creates a race where both processes are active simultaneously.

**Fix**: Add wait loop with timeout (max 2s), then SIGKILL if needed.

### 🔴 #2: Silent Write Failure
**File**: `src/process-lock.ts:110`, `src/paths.ts:88-101`

`safeWriteFileSync` silently returns on symlink detection. The process thinks it has the lock when it doesn't.

**Fix**: Verify PID file write succeeded by reading it back.

### 🔴 #3: No Kill Verification
**File**: `src/process-lock.ts:83-100`

No verification that SIGTERM actually killed the process. Both processes may run if kill fails.

**Fix**: Check `isProcessAlive()` after SIGTERM (included in #1 fix).

---

## High Priority Issues (Should Fix)

### 🟠 #4: Misleading `killedStale` Flag
**File**: `src/process-lock.ts:75-76`

Flag is `true` even when process was already dead. Misleading logs and telemetry.

**Fix**: Initialize to `false`, only set `true` when actually killing a live process.

### 🟠 #5: PID Reuse Risk
**File**: `src/process-lock.ts:32-40`

PIDs can be reused. May kill innocent processes if PID now belongs to different process.

**Fix**: Check process start time via `ps` before killing.

### 🟠 #6: Concurrent Startup Race
**File**: `src/process-lock.ts:66-101`

Two processes starting simultaneously can both think they own the lock.

**Fix**: Use atomic file operations (rename temp file to final location).

---

## What Works Well

✅ Clear problem identification and documentation  
✅ Comprehensive test coverage for basic scenarios  
✅ Graceful handling of corrupt PID files  
✅ Proper signal handlers for cleanup  
✅ Correct EPERM vs ESRCH handling in `isProcessAlive`  

---

## Testing Checklist

Before merge, manually verify:

- [ ] Start two MCP servers sequentially — second kills first
- [ ] Start two MCP servers simultaneously — only one survives  
- [ ] SIGTERM cleanup — PID file removed
- [ ] SIGKILL scenario — next startup cleans up stale PID
- [ ] Symlink attack — server refuses or cleans up

---

## Bottom Line

**The race conditions defeat the purpose of the PID lockfile.** Without waiting for SIGTERM to complete, both processes will be active simultaneously, causing the exact socket conflicts this PR aims to prevent.

**Fix Issues #1, #2, #3 before merge.** Issues #4-#6 are important but can be addressed in follow-up.

---

*Review conducted by @bugbot*  
*Full detailed review: [BUGBOT_REVIEW.md](./BUGBOT_REVIEW.md)*
