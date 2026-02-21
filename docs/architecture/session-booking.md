# Session Booking

VoiceLayer uses lockfile-based session booking to prevent microphone conflicts when multiple Claude Code sessions run simultaneously.

## The Problem

You might have several Claude Code terminals open — one working on frontend, another on backend. If both try to record from the mic at the same time, audio gets corrupted and transcription fails.

## How It Works

### Lockfile Mutex

Session booking uses an exclusive lockfile at `/tmp/voicelayer-session.lock`:

```json
{
  "pid": 12345,
  "sessionId": "mcp-12345",
  "startedAt": "2026-02-21T10:30:00.000Z"
}
```

### Booking Flow

1. **First `converse` call** — auto-books if not already booked
2. **Stale lock check** — if the lock exists but the PID is dead, remove it
3. **Atomic creation** — uses `wx` file flag (exclusive create) to prevent race conditions
4. **Session-level** — once booked, the session holds the mic for its entire lifetime
5. **Auto-release** — lock released on process exit (SIGTERM, SIGINT, exit handlers)

### What Other Sessions See

When a session tries to `converse` but the mic is booked by another:

```
[converse] Line is busy — voice session owned by mcp-12345
(PID 12345) since 2026-02-21T10:30:00.000Z.
Fall back to text input, or wait for the other session to finish.
```

This returns with `isError: true`, allowing the agent to gracefully fall back to text-based interaction.

### Non-Blocking Modes Are Unaffected

Announce, brief, consult, and think don't require mic access — they work regardless of session booking state. Only `converse` (which records audio) needs exclusive access.

## Stale Lock Cleanup

Locks can become stale if a process crashes without running cleanup handlers:

1. On every booking check, VoiceLayer reads the lock and checks if the PID is alive
2. Uses `process.kill(pid, 0)` — signal 0 checks process existence without sending a signal
3. `ESRCH` error = process is dead = stale lock = remove it
4. `EPERM` error = process exists but different user = treat as alive

This means crashed sessions don't permanently block the mic.

## Race Condition Safety

Two sessions might try to book simultaneously. VoiceLayer handles this with atomic file creation:

```typescript
// Uses 'wx' flag — fails if file already exists (atomic)
writeFileSync(LOCK_FILE, JSON.stringify(lock), { flag: "wx" });
```

If both sessions race to create the lockfile, only one succeeds. The loser gets `EEXIST` and sees a "line busy" error.

## Manual Lock Management

If something goes wrong, you can manually manage the lock:

```bash
# Check who has the lock
cat /tmp/voicelayer-session.lock

# Force-release (only if the owning process is actually dead)
rm /tmp/voicelayer-session.lock
```

!!! warning
    Only remove the lockfile if you're certain the owning process is dead. Removing an active lock can cause audio corruption.

## Process Lifecycle

```
MCP Server starts
    │
    ├── Registers SIGTERM handler → releaseVoiceSession()
    ├── Registers SIGINT handler  → releaseVoiceSession()
    └── Registers exit handler    → releaseVoiceSession()
    │
    ... serves tool calls ...
    │
    ├── First converse call → bookVoiceSession()
    │                          ├── cleanStaleLock()
    │                          ├── Check existing lock
    │                          └── Atomic create lockfile
    │
    ... more tool calls ...
    │
Process exits → cleanup runs
    ├── releaseVoiceSession() (only if we own the lock)
    └── clearStopSignal() (remove /tmp/voicelayer-stop)
```
