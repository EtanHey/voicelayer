# Bug Review: PID Lockfile for Orphan MCP Server Cleanup

## Executive Summary

**Status**: 🟡 **APPROVED WITH CRITICAL FIXES REQUIRED**

The PR correctly identifies the orphan MCP server problem and implements a reasonable solution. However, there are **critical race conditions** and **reliability issues** that must be fixed before merge.

**Key Findings**:
1. 🔴 **CRITICAL**: Race condition in lock acquisition - no wait after SIGTERM
2. 🔴 **CRITICAL**: Silent failure in `safeWriteFileSync` breaks lock acquisition
3. 🟠 **HIGH**: No verification that killed process actually died
4. 🟡 **MEDIUM**: `killedStale` flag is misleading for dead processes
5. 🟢 **GOOD**: Comprehensive test coverage for basic scenarios

---

## Critical Issues

### 🔴 Issue #1: Race Condition - No Wait After SIGTERM

**File**: `src/process-lock.ts:83-92`

**Problem**: The code sends SIGTERM to the stale process but immediately claims the lock without waiting for the process to actually terminate.

```typescript:83:92:src/process-lock.ts
if (isProcessAlive(stalePid)) {
  try {
    process.kill(stalePid, "SIGTERM");
    console.error(
      `[voicelayer] Killed orphan MCP server (PID ${stalePid}) — was started at ${existing.startedAt}`,
    );
  } catch {
    console.error(
      `[voicelayer] Could not kill orphan MCP server (PID ${stalePid}) — claiming lock anyway`,
    );
  }
}

writePidFile();
```

**Impact**:
- The old process may still be running when the new process starts
- Both processes will try to connect to the Voice Bar socket simultaneously
- This defeats the entire purpose of the PID lockfile
- Race condition window: typically 10-100ms for graceful SIGTERM shutdown

**Fix Required**:
```typescript
if (isProcessAlive(stalePid)) {
  try {
    process.kill(stalePid, "SIGTERM");
    console.error(
      `[voicelayer] Sent SIGTERM to orphan MCP server (PID ${stalePid})`,
    );
    
    // Wait for process to die (with timeout)
    const maxWaitMs = 2000;
    const startTime = Date.now();
    while (isProcessAlive(stalePid) && Date.now() - startTime < maxWaitMs) {
      // Sleep 50ms between checks
      Bun.sleepSync(50);
    }
    
    if (isProcessAlive(stalePid)) {
      console.error(
        `[voicelayer] Process ${stalePid} did not die after SIGTERM, sending SIGKILL`,
      );
      try {
        process.kill(stalePid, "SIGKILL");
        Bun.sleepSync(100); // SIGKILL is immediate, but give kernel time
      } catch {
        console.error(
          `[voicelayer] Could not SIGKILL ${stalePid} — claiming lock anyway`,
        );
      }
    } else {
      console.error(
        `[voicelayer] Killed orphan MCP server (PID ${stalePid}) — was started at ${existing.startedAt}`,
      );
    }
  } catch {
    console.error(
      `[voicelayer] Could not signal orphan MCP server (PID ${stalePid}) — claiming lock anyway`,
    );
  }
}
```

**Why This Matters**:
- SIGTERM is a graceful shutdown signal - processes can take time to clean up
- The MCP server has signal handlers that call `releaseProcessLock()` and `disconnectFromBar()`
- These cleanup operations take time (socket close, file I/O)
- Without waiting, you get a race where both processes are active

---

### 🔴 Issue #2: Silent Failure in `safeWriteFileSync`

**File**: `src/process-lock.ts:110` and `src/paths.ts:88-101`

**Problem**: `safeWriteFileSync` silently returns on symlink detection instead of throwing an error. This means `writePidFile()` can fail silently, and the process will think it owns the lock when it doesn't.

```typescript:88:101:src/paths.ts
export function safeWriteFileSync(filePath: string, content: string): void {
  if (existsSync(filePath)) {
    try {
      const stat = lstatSync(filePath);
      if (stat.isSymbolicLink()) {
        console.error(
          `[voicelayer] Refusing to write: ${filePath} is a symlink`,
        );
        return; // ❌ SILENT FAILURE
      }
    } catch {}
  }
  writeFileSync(filePath, content, { mode: 0o600 });
}
```

**Impact**:
- If an attacker creates `/tmp/voicelayer-mcp.pid` as a symlink, the MCP server will fail to acquire the lock
- The server will continue running without a lock, defeating the orphan prevention
- Multiple MCP servers can run simultaneously
- This is a **security issue** (symlink attack) AND a **reliability issue** (silent failure)

**Fix Required**:

Option 1: Make `safeWriteFileSync` throw on symlink:
```typescript
export function safeWriteFileSync(filePath: string, content: string): void {
  if (existsSync(filePath)) {
    try {
      const stat = lstatSync(filePath);
      if (stat.isSymbolicLink()) {
        throw new Error(`Refusing to write: ${filePath} is a symlink`);
      }
    } catch (err) {
      if ((err as any).message?.includes("symlink")) throw err;
      // Other errors (EACCES, etc.) are non-fatal
    }
  }
  writeFileSync(filePath, content, { mode: 0o600 });
}
```

Option 2: Check if write succeeded in `acquireProcessLock`:
```typescript
function writePidFile(): void {
  const data: PidLockData = {
    pid: process.pid,
    startedAt: new Date().toISOString(),
  };
  safeWriteFileSync(MCP_PID_FILE, JSON.stringify(data));
  
  // Verify write succeeded
  const written = readPidFile();
  if (!written || written.pid !== process.pid) {
    throw new Error(
      `Failed to write PID file ${MCP_PID_FILE} — may be a symlink or permission issue`,
    );
  }
}
```

**Recommendation**: Use Option 2 (verify write) as it's more robust and handles all write failures, not just symlinks.

---

### 🟠 Issue #3: No Verification That Process Actually Died

**File**: `src/process-lock.ts:83-100`

**Problem**: After sending SIGTERM, the code doesn't verify that the process actually terminated. It just logs and moves on.

**Impact**:
- If SIGTERM fails (EPERM, process ignoring signal, etc.), both processes run
- The new process will overwrite the PID file, but the old process is still connected to Voice Bar
- Voice Bar socket only accepts one connection, so the new process will fail to connect

**Fix**: See Issue #1 fix above (includes verification loop).

---

## High Priority Issues

### 🟠 Issue #4: Misleading `killedStale` Flag

**File**: `src/process-lock.ts:75-101`

**Problem**: The `killedStale` flag is set to `true` even when the process was already dead (line 76). This is misleading.

```typescript:74:101:src/process-lock.ts
// Stale process found — try to kill it
const stalePid = existing.pid;
let killedStale = true; // ❌ Set to true even if process is already dead

if (stalePid === process.pid) {
  // We already own the lock (shouldn't happen, but handle gracefully)
  return { acquired: true, killedStale: false };
}

if (isProcessAlive(stalePid)) {
  try {
    process.kill(stalePid, "SIGTERM");
    console.error(
      `[voicelayer] Killed orphan MCP server (PID ${stalePid}) — was started at ${existing.startedAt}`,
    );
  } catch {
    console.error(
      `[voicelayer] Could not kill orphan MCP server (PID ${stalePid}) — claiming lock anyway`,
    );
  }
} else {
  console.error(
    `[voicelayer] Cleaned up stale PID file (PID ${stalePid} is dead)`,
  );
}

writePidFile();
return { acquired: true, killedStale, stalePid };
```

**Impact**:
- Misleading logs in `mcp-server.ts:115-118` (says "Replaced orphan" when process was already dead)
- Incorrect telemetry/debugging information

**Fix**:
```typescript
const stalePid = existing.pid;
let killedStale = false; // Default to false

if (stalePid === process.pid) {
  return { acquired: true, killedStale: false };
}

if (isProcessAlive(stalePid)) {
  killedStale = true; // Only set true if we actually kill a living process
  try {
    process.kill(stalePid, "SIGTERM");
    // ... wait logic from Issue #1 fix ...
  } catch {
    console.error(
      `[voicelayer] Could not kill orphan MCP server (PID ${stalePid}) — claiming lock anyway`,
    );
  }
} else {
  console.error(
    `[voicelayer] Cleaned up stale PID file (PID ${stalePid} is dead)`,
  );
}
```

---

## Medium Priority Issues

### 🟡 Issue #5: No Handling of PID Reuse

**File**: `src/process-lock.ts:32-40`

**Problem**: PIDs can be reused by the OS. If the PID in the lockfile now belongs to a different process (not an MCP server), we'll kill an innocent process.

```typescript:32:40:src/process-lock.ts
export function isProcessAlive(pid: number): boolean {
  try {
    process.kill(pid, 0);
    return true;
  } catch (err: unknown) {
    const code = (err as NodeJS.ErrnoException).code;
    // EPERM = alive but we can't signal it; ESRCH = not found (dead)
    return code === "EPERM";
  }
}
```

**Impact**:
- Low probability but high severity
- Could kill unrelated system processes
- More likely on systems with fast PID wraparound (containers, busy servers)

**Mitigation Options**:

1. **Check process start time** (best option):
```typescript
function isProcessAlive(pid: number): boolean {
  try {
    process.kill(pid, 0);
    return true;
  } catch (err: unknown) {
    const code = (err as NodeJS.ErrnoException).code;
    return code === "EPERM";
  }
}

function isSameProcess(pid: number, startedAt: string): boolean {
  if (!isProcessAlive(pid)) return false;
  
  // Check process start time via /proc (Linux) or ps (macOS)
  try {
    const result = Bun.spawnSync(["ps", "-p", String(pid), "-o", "lstart="]);
    if (result.exitCode !== 0) return false;
    
    const psStartTime = Buffer.from(result.stdout).toString("utf8").trim();
    const lockStartTime = new Date(startedAt).getTime();
    const psStartTimeMs = new Date(psStartTime).getTime();
    
    // Allow 1 second tolerance for clock skew
    return Math.abs(psStartTimeMs - lockStartTime) < 1000;
  } catch {
    // If we can't verify, assume it's the same process (fail open)
    return true;
  }
}
```

2. **Check process name** (simpler but less reliable):
```typescript
function isVoiceLayerMCP(pid: number): boolean {
  try {
    const result = Bun.spawnSync(["ps", "-p", String(pid), "-o", "comm="]);
    if (result.exitCode !== 0) return false;
    const comm = Buffer.from(result.stdout).toString("utf8").trim();
    return comm.includes("bun") || comm.includes("node") || comm.includes("voicelayer");
  } catch {
    return false;
  }
}
```

**Recommendation**: Use process start time check (Option 1). It's more reliable and prevents killing innocent processes.

---

### 🟡 Issue #6: Race Condition in Concurrent Startup

**File**: `src/process-lock.ts:66-101`

**Problem**: If two MCP servers start simultaneously, both can read the PID file, see no lock, and both write their PIDs. The second write wins, and the first process thinks it has the lock but doesn't.

**Scenario**:
1. Process A reads PID file → null (no lock)
2. Process B reads PID file → null (no lock)
3. Process A writes PID file (PID=1234)
4. Process B writes PID file (PID=5678) ← overwrites A's lock
5. Process A thinks it has the lock, but B actually owns it

**Impact**:
- Low probability (requires simultaneous startup within ~1ms window)
- Both processes will run, defeating the lock
- More likely in automated testing or CI environments

**Fix**: Use atomic file operations with `O_EXCL` flag:
```typescript
import { openSync, writeSync, closeSync, constants } from "fs";

function writePidFile(): void {
  const data: PidLockData = {
    pid: process.pid,
    startedAt: new Date().toISOString(),
  };
  const content = JSON.stringify(data);
  
  try {
    // O_CREAT | O_EXCL = atomic create-if-not-exists
    const fd = openSync(MCP_PID_FILE, constants.O_WRONLY | constants.O_CREAT | constants.O_EXCL, 0o600);
    writeSync(fd, content);
    closeSync(fd);
  } catch (err: any) {
    if (err.code === "EEXIST") {
      // File was created between our read and write — retry lock acquisition
      throw new Error("PID file created by another process — retry");
    }
    throw err;
  }
}
```

However, this doesn't work for the overwrite case (when we're replacing a stale lock). Better approach:

```typescript
function writePidFile(): void {
  const data: PidLockData = {
    pid: process.pid,
    startedAt: new Date().toISOString(),
  };
  
  // Use rename for atomic overwrite
  const tempFile = `${MCP_PID_FILE}.${process.pid}.tmp`;
  writeFileSync(tempFile, JSON.stringify(data), { mode: 0o600 });
  renameSync(tempFile, MCP_PID_FILE); // Atomic on POSIX
}
```

**Recommendation**: Use atomic rename approach. It's simple and works for both create and overwrite cases.

---

## Low Priority Issues

### 🟢 Issue #7: Test Coverage Gap - Concurrent Acquisition

**File**: `src/__tests__/process-lock.test.ts`

**Problem**: No test for concurrent lock acquisition (Issue #6 scenario).

**Recommendation**: Add test:
```typescript
it("handles concurrent lock acquisition", async () => {
  // Simulate race: two processes try to acquire simultaneously
  const child1 = Bun.spawn(["bun", "test-acquire-lock.ts"]);
  const child2 = Bun.spawn(["bun", "test-acquire-lock.ts"]);
  
  await Promise.all([child1.exited, child2.exited]);
  
  // Only one should have succeeded
  const pidFile = readFileSync(MCP_PID_FILE, "utf-8");
  const data = JSON.parse(pidFile);
  expect([child1.pid, child2.pid]).toContain(data.pid);
});
```

---

### 🟢 Issue #8: Missing Test - SIGTERM Handler

**File**: `src/__tests__/process-lock.test.ts`

**Problem**: No test verifies that the SIGTERM handler actually releases the lock.

**Recommendation**: Add test:
```typescript
it("releases lock on SIGTERM", async () => {
  const child = Bun.spawn(["bun", "run", "src/mcp-server.ts"], {
    stdout: "pipe",
    stderr: "pipe",
  });
  
  // Wait for startup
  await new Promise(resolve => setTimeout(resolve, 500));
  
  // Verify lock is held
  const beforeKill = readFileSync(MCP_PID_FILE, "utf-8");
  const data = JSON.parse(beforeKill);
  expect(data.pid).toBe(child.pid);
  
  // Send SIGTERM
  child.kill("SIGTERM");
  await child.exited;
  
  // Verify lock is released
  expect(existsSync(MCP_PID_FILE)).toBe(false);
});
```

---

## Positive Observations

✅ **Good**: Clear problem statement and documentation  
✅ **Good**: Comprehensive test coverage for basic scenarios  
✅ **Good**: Graceful handling of corrupt PID files  
✅ **Good**: Uses `safeWriteFileSync` to prevent symlink attacks  
✅ **Good**: Signal handlers properly call `releaseProcessLock()`  
✅ **Good**: `isProcessAlive` correctly handles EPERM vs ESRCH  

---

## Recommendations

### Must Fix Before Merge

1. **Fix Issue #1**: Add wait loop after SIGTERM (with SIGKILL fallback)
2. **Fix Issue #2**: Verify PID file write succeeded
3. **Fix Issue #3**: Verify killed process actually died

### Should Fix Before Merge

4. **Fix Issue #4**: Correct `killedStale` flag logic
5. **Fix Issue #5**: Add process start time verification (prevent PID reuse)
6. **Fix Issue #6**: Use atomic file operations (prevent race condition)

### Nice to Have

7. **Fix Issue #7**: Add concurrent acquisition test
8. **Fix Issue #8**: Add SIGTERM handler test

---

## Testing Checklist

Before merging, manually verify:

- [ ] Start two MCP servers sequentially — second kills first
- [ ] Start two MCP servers simultaneously — only one survives
- [ ] Kill MCP server with SIGTERM — PID file is removed
- [ ] Kill MCP server with SIGKILL — next startup cleans up stale PID
- [ ] Create symlink at `/tmp/voicelayer-mcp.pid` — server refuses to start or removes symlink
- [ ] Start MCP server, wait 5 seconds, start another — first is killed cleanly
- [ ] Corrupt PID file — next startup cleans up and acquires lock

---

## Verdict

**Status**: 🟡 **APPROVED WITH CRITICAL FIXES REQUIRED**

The PR addresses a real reliability problem (orphan MCP servers), but the implementation has **critical race conditions** that must be fixed:

1. **No wait after SIGTERM** — old process may still be running when new process starts
2. **Silent write failures** — process may think it has lock when it doesn't
3. **No kill verification** — can't confirm old process actually died

**These issues defeat the purpose of the PID lockfile.**

The fixes are straightforward (add wait loop, verify writes, check process death), but they are **essential for correctness**.

**Recommendation**: Fix Issues #1, #2, #3 before merge. Issues #4-#6 are important but non-blocking.
