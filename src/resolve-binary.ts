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

/**
 * Resolve a binary by name. Tries `which` with enriched PATH, then probes
 * candidate paths directly. Returns full path or null.
 */
export function resolveBinary(
  name: string,
  candidates: string[] = [],
): string | null {
  // Try `which` with enriched PATH
  try {
    const result = Bun.spawnSync(["which", name]);
    if (result.exitCode === 0) {
      const path = result.stdout.toString().trim();
      if (path) return path;
    }
  } catch {
    // which not found — fall through
  }

  // Probe candidate paths directly
  const allCandidates = [
    ...candidates,
    `/opt/homebrew/bin/${name}`,
    `/usr/local/bin/${name}`,
    `/usr/bin/${name}`,
  ];

  for (const candidate of allCandidates) {
    try {
      const check = Bun.spawnSync([candidate, "--version"]);
      if (check.exitCode === 0) {
        console.error(`[voicelayer] Resolved ${name} at: ${candidate}`);
        return candidate;
      }
    } catch {
      // ENOENT — candidate doesn't exist
    }
  }

  return null;
}
