import { arch, platform } from "node:os";

/**
 * Binary resolution for daemon/LaunchAgent context.
 *
 * Problem: When VoiceLayer runs as a LaunchAgent or is spawned by VoiceBar,
 * /opt/homebrew/bin isn't in PATH. Binaries like sox, whisper-cli, python3
 * can't be found via `which`.
 *
 * Solution (from R64 research / CodexBar v0.9.1 pattern):
 * 1. Try login shell PATH capture ($SHELL -l -c "echo $PATH") with timeout
 * 2. Merge with deterministic fallback paths (/opt/homebrew/bin, /usr/local/bin)
 * 3. Cache enriched PATH for the session
 * 4. Use enriched PATH for all binary lookups
 */

/** Deterministic fallback paths for macOS (Apple Silicon + Intel) and Linux. */
const FALLBACK_PATHS = [
  "/opt/homebrew/bin",
  "/opt/homebrew/sbin",
  "/usr/local/bin",
  "/usr/bin",
  "/bin",
  "/usr/sbin",
  "/sbin",
];

/** Cached enriched PATH — resolved once at startup. */
let enrichedPATH: string | null = null;

/**
 * Capture user's full PATH from their login shell.
 * Times out after 3s (slow oh-my-zsh configs are common).
 */
function captureLoginShellPATH(): string | null {
  const shell = process.env.SHELL || "/bin/zsh";
  try {
    const result = Bun.spawnSync([shell, "-l", "-c", "echo $PATH"], {
      timeout: 3000,
      env: { HOME: process.env.HOME || "" },
    });
    if (result.exitCode === 0) {
      const path = result.stdout.toString().trim();
      if (path && path.includes("/")) return path;
    }
  } catch {
    // Timeout or shell not found — fall through
  }
  return null;
}

/**
 * Build enriched PATH by merging login shell PATH with deterministic fallbacks.
 * Called once at daemon startup. Result is cached.
 */
export function initEnrichedPATH(): string {
  if (enrichedPATH) return enrichedPATH;

  const currentPATH = process.env.PATH || "";
  const shellPATH = captureLoginShellPATH();

  // Merge: current PATH + shell PATH + fallbacks, deduplicated
  const seen = new Set<string>();
  const parts: string[] = [];

  for (const source of [currentPATH, shellPATH, FALLBACK_PATHS.join(":")]) {
    if (!source) continue;
    for (const p of source.split(":")) {
      if (p && !seen.has(p)) {
        seen.add(p);
        parts.push(p);
      }
    }
  }

  enrichedPATH = parts.join(":");

  // Also set it in process.env so all child processes inherit
  process.env.PATH = enrichedPATH;

  return enrichedPATH;
}

/** Get the cached enriched PATH (must call initEnrichedPATH first). */
export function getEnrichedPATH(): string {
  return enrichedPATH || process.env.PATH || "";
}

/** Per-spawn wall-clock bound for a single `which` / `--version` probe. */
const SPAWN_TIMEOUT_MS = 1_500;

/**
 * Total bound across one `resolveBinary()` call.
 *
 * The per-spawn timeout stops one wedged child; without a total budget the
 * sequence (`which`, then up to four candidate probes) could still hold a
 * caller for five times that. Resolution on a healthy machine is milliseconds.
 */
const RESOLVE_BUDGET_MS = 3_000;

/** The `Bun.spawnSync` surface this module uses — injectable for tests. */
export type BinarySpawnSync = (
  cmd: string[],
  options: { stdout: "pipe"; stderr: "ignore"; timeout: number },
) => {
  exitCode?: number | null;
  stdout?: { toString(): string } | string;
  exitedDueToTimeout?: boolean;
};

const defaultBinarySpawn: BinarySpawnSync = (cmd, options) =>
  Bun.spawnSync(cmd, options);

let binarySpawn: BinarySpawnSync = defaultBinarySpawn;
const resolvedPaths = new Map<string, string>();
const pendingPaths = new Map<string, Promise<string | null>>();
let resolutionGeneration = 0;
const isMediaBinary = (name: string) => name === "ffmpeg" || name === "ffprobe";
const versionFlag = (name: string) => isMediaBinary(name) ? "-version" : "--version";
const preferHomebrew = (name: string) => isMediaBinary(name) && platform() === "darwin" && arch() === "arm64";
function remember(name: string, path: string): string {
  resolvedPaths.set(name, path);
  return path;
}

export function __setBinarySpawnForTests(spawn: BinarySpawnSync): void {
  __resetBinarySpawnForTests();
  binarySpawn = spawn;
}

export function __resetBinarySpawnForTests(): void {
  binarySpawn = defaultBinarySpawn;
  resolvedPaths.clear();
  pendingPaths.clear();
  resolutionGeneration++;
}

export interface ResolveBinaryOptions {
  /** Bound for a single probe. Defaults to `SPAWN_TIMEOUT_MS`. */
  spawnTimeoutMs?: number;
  /** Bound across the whole call. Defaults to `RESOLVE_BUDGET_MS`. */
  budgetMs?: number;
}

interface ProbeOutcome {
  exitCode: number | null;
  stdout: string;
  timedOut: boolean;
}

function runProbe(cmd: string[], timeoutMs: number): ProbeOutcome {
  try {
    const result = binarySpawn(cmd, {
      stdout: "pipe",
      stderr: "ignore",
      timeout: timeoutMs,
    });
    const exitCode = result.exitCode ?? null;
    const raw = result.stdout;
    return {
      exitCode,
      stdout: typeof raw === "string" ? raw : (raw?.toString() ?? ""),
      timedOut: result.exitedDueToTimeout === true,
    };
  } catch {
    // ENOENT — the candidate does not exist. Not a timeout.
    return { exitCode: null, stdout: "", timedOut: false };
  }
}

/**
 * Resolve a binary by name. Tries `which` with enriched PATH, then probes
 * candidate paths directly. Returns full path or null.
 *
 * AIDEV-NOTE: every spawn here is bounded — a `Bun.spawnSync` with no `timeout`
 * holds the Bun event loop for as long as the child takes, and this function
 * sits on the capture path (`rec`/sox in `src/input.ts` and `src/audio-utils.ts`)
 * as well as on `python3`, `brew` and whisper lookups. A wedged binary must cost
 * a bounded wait and a null, never a stalled recording. Prefer the async
 * `resolveBinaryAsync()` (added in PR #9) for new callers that can await —
 * it never blocks the loop at all, where this one still blocks for up to
 * `budgetMs`.
 */
export function resolveBinary(
  name: string,
  candidates: string[] = [],
  options: ResolveBinaryOptions = {},
): string | null {
  const cached = resolvedPaths.get(name);
  if (cached) return cached;
  const spawnTimeoutMs = options.spawnTimeoutMs ?? SPAWN_TIMEOUT_MS;
  const budgetMs = options.budgetMs ?? RESOLVE_BUDGET_MS;
  const started = Date.now();
  let timedOut = false;

  /** Remaining budget, or null once it is spent. */
  const nextTimeout = (): number | null => {
    const remaining = budgetMs - (Date.now() - started);
    if (remaining <= 0) return null;
    return Math.min(spawnTimeoutMs, remaining);
  };

  const giveUp = (): null => {
    if (timedOut) {
      console.error(
        `[voicelayer] Binary resolution for '${name}' timed out after ${Date.now() - started}ms — treating as not found`,
      );
    }
    return null;
  };

  // Native Homebrew wins over a stale Intel PATH twin on Apple Silicon.
  const preferred = preferHomebrew(name) ? `/opt/homebrew/bin/${name}` : undefined;
  if (preferred) {
    const timeout = nextTimeout();
    if (timeout === null) return giveUp();
    const check = runProbe([preferred, versionFlag(name)], timeout);
    if (check.timedOut) timedOut = true;
    if (check.exitCode === 0) return remember(name, preferred);
  }

  // Try `which` with enriched PATH
  const whichTimeout = nextTimeout();
  if (whichTimeout === null) return giveUp();
  const which = runProbe(["which", name], whichTimeout);
  if (which.timedOut) timedOut = true;
  if (which.exitCode === 0) {
    const path = which.stdout.trim();
    if (path) {
      if (!isMediaBinary(name)) return remember(name, path);
      const timeout = nextTimeout();
      if (timeout === null) return giveUp();
      const check = runProbe([path, "-version"], timeout);
      if (check.timedOut) timedOut = true;
      if (check.exitCode === 0) return remember(name, path);
    }
  }

  // Probe candidate paths directly
  const allCandidates = [
    ...candidates,
    `/opt/homebrew/bin/${name}`,
    `/usr/local/bin/${name}`,
    `/usr/bin/${name}`,
  ];

  for (const candidate of allCandidates) {
    const timeout = nextTimeout();
    if (timeout === null) return giveUp();
    const check = runProbe([candidate, versionFlag(name)], timeout);
    if (check.timedOut) timedOut = true;
    if (check.exitCode === 0) {
      console.error(`[voicelayer] Resolved ${name} at: ${candidate}`);
      return remember(name, candidate);
    }
  }

  return giveUp();
}

/** Default per-probe bound for the async resolver. */
const ASYNC_RESOLVE_TIMEOUT_MS = 1_500;

/**
 * Run one probe command with an enforced wall-clock bound, without ever
 * blocking the event loop. Returns exit code 0/non-zero, or null on timeout.
 */
async function probeExitCode(
  cmd: string[],
  timeoutMs: number,
): Promise<number | null> {
  try {
    const proc = Bun.spawn(cmd, { stdout: "ignore", stderr: "ignore" });
    let timedOut = false;
    const timer = setTimeout(() => {
      timedOut = true;
      try {
        proc.kill("SIGKILL");
      } catch {}
    }, timeoutMs);
    try {
      const exitCode = await proc.exited;
      return timedOut ? null : exitCode;
    } finally {
      clearTimeout(timer);
    }
  } catch {
    return null;
  }
}

/**
 * Async, bounded twin of `resolveBinary`.
 *
 * AIDEV-NOTE: `resolveBinary` shells out with `Bun.spawnSync` and no timeout —
 * a hanging `which` or `<candidate> --version` holds the Bun event loop for as
 * long as the child takes. That is tolerable where it is already used (one-shot
 * setup paths), but NOT on any path a daemon startup or a recording waits on.
 * Every probe here is `Bun.spawn` plus an enforced timer, so a wedged binary
 * costs `timeoutMs` and a SIGKILL rather than the whole process.
 *
 * The sync twin retains its capture-path lookup and timing behavior for other
 * binaries; ffmpeg and ffprobe use their supported `-version` probe. New callers on
 * latency-sensitive paths should use this one.
 */
export function resolveBinaryAsync(
  name: string,
  candidates: string[] = [],
  timeoutMs: number = ASYNC_RESOLVE_TIMEOUT_MS,
): Promise<string | null> {
  const cached = resolvedPaths.get(name);
  if (cached) return Promise.resolve(cached);
  const pending = pendingPaths.get(name);
  if (pending) return pending;
  const generation = resolutionGeneration;
  const result = resolveBinaryAsyncUncached(name, candidates, timeoutMs).then(path => {
    if (path && generation === resolutionGeneration) remember(name, path);
    return path;
  }).finally(() => {
    if (pendingPaths.get(name) === result) pendingPaths.delete(name);
  });
  pendingPaths.set(name, result);
  return result;
}

async function resolveBinaryAsyncUncached(
  name: string,
  candidates: string[] = [],
  timeoutMs: number = ASYNC_RESOLVE_TIMEOUT_MS,
): Promise<string | null> {
  if (preferHomebrew(name)) {
    const preferred = `/opt/homebrew/bin/${name}`;
    if (await probeExitCode([preferred, versionFlag(name)], timeoutMs) === 0) return preferred;
  }
  try {
    const proc = Bun.spawn(["which", name], {
      stdout: "pipe",
      stderr: "ignore",
    });
    let timedOut = false;
    const timer = setTimeout(() => {
      timedOut = true;
      try {
        proc.kill("SIGKILL");
      } catch {}
    }, timeoutMs);
    try {
      const [out, exitCode] = await Promise.all([
        new Response(proc.stdout).text(),
        proc.exited,
      ]);
      if (!timedOut && exitCode === 0) {
        const path = out.trim();
        if (path && (!isMediaBinary(name) || await probeExitCode([path, "-version"], timeoutMs) === 0)) return path;
      }
    } finally {
      clearTimeout(timer);
    }
  } catch {
    // which not found — fall through to the candidate probes
  }

  const allCandidates = [
    ...candidates,
    `/opt/homebrew/bin/${name}`,
    `/usr/local/bin/${name}`,
    `/usr/bin/${name}`,
  ];

  for (const candidate of allCandidates) {
    if ((await probeExitCode([candidate, versionFlag(name)], timeoutMs)) === 0) {
      return candidate;
    }
  }

  return null;
}
