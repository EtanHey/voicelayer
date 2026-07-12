/**
 * edge-tts health check and retry logic.
 *
 * Problem: edge-tts fails randomly with exit code 2 (network issues,
 * module not found, rate limiting). This causes voice_speak and voice_ask
 * to crash without recovery.
 *
 * Solution:
 * - Health check: verify edge-tts is importable before use (cached 60s)
 * - Retry: on failure, retry once before giving up
 * - Never hang: always return an error instead of blocking
 */

import { readFileSync, unlinkSync } from "fs";
import type { WordBoundary } from "./socket-protocol";

const HEALTH_CACHE_TTL_MS = 60_000;
const SYNTH_TIMEOUT_MS = 30_000; // 30s hard timeout per synthesis attempt

let healthCacheResult: boolean | null = null;
let healthCacheTime = 0;

// AIDEV-NOTE: LaunchAgent PATH doesn't include Python framework dirs.
// Resolve full python3 path once at startup so edge-tts works in daemon mode.
let resolvedPython3: string = "python3";

/**
 * Resolve the full path to python3. Checks common locations when `which`
 * fails (e.g., inside a LaunchAgent with a minimal PATH).
 * Result is cached — called once at startup.
 */
export function resolvePython3Path(): string {
  // Try `which` first — works in interactive shells
  try {
    const which = Bun.spawnSync(["which", "python3"]);
    if (which.exitCode === 0) {
      const path = which.stdout.toString().trim();
      if (path) {
        resolvedPython3 = path;
        return resolvedPython3;
      }
    }
  } catch {
    // `which` not found (minimal images) — fall through to candidates
  }

  // Fallback: check common macOS/Linux locations
  const candidates = [
    "/Library/Frameworks/Python.framework/Versions/3.13/bin/python3",
    "/Library/Frameworks/Python.framework/Versions/3.12/bin/python3",
    "/Library/Frameworks/Python.framework/Versions/3.11/bin/python3",
    "/opt/homebrew/bin/python3",
    "/usr/local/bin/python3",
    "/usr/bin/python3",
  ];

  for (const candidate of candidates) {
    try {
      const check = Bun.spawnSync([candidate, "--version"]);
      if (check.exitCode === 0) {
        resolvedPython3 = candidate;
        console.error(`[voicelayer] Resolved python3 at: ${resolvedPython3}`);
        return resolvedPython3;
      }
    } catch {
      // ENOENT — candidate binary doesn't exist, try next
    }
  }

  console.error(
    "[voicelayer] Warning: python3 not found in PATH or common locations — edge-tts will fail",
  );
  return resolvedPython3;
}

/** Get the resolved python3 path. */
export function getPython3Path(): string {
  return resolvedPython3;
}

/**
 * Check if edge-tts Python module is installed and importable.
 * Caches result for 60 seconds to avoid repeated subprocess spawns.
 */
export function checkEdgeTTSHealth(): boolean {
  const now = Date.now();
  if (
    healthCacheResult !== null &&
    now - healthCacheTime < HEALTH_CACHE_TTL_MS
  ) {
    return healthCacheResult;
  }

  try {
    const result = Bun.spawnSync([
      resolvedPython3,
      "-c",
      "import edge_tts; print('ok')",
    ]);
    healthCacheResult = result.exitCode === 0;
    healthCacheTime = now;
    return healthCacheResult;
  } catch {
    healthCacheResult = false;
    healthCacheTime = now;
    return false;
  }
}

/** Reset the health check cache (for testing). */
export function resetHealthCache(): void {
  healthCacheResult = null;
  healthCacheTime = 0;
}

interface SynthesizeResult {
  success: boolean;
  attempts: number;
  audioFile?: string;
  wordBoundaries?: WordBoundary[];
  durationMs?: number;
  error?: string;
}

/**
 * Build the argv for the edge-tts word-timing script.
 *
 * AIDEV-NOTE: All caller-controlled values (--text, --voice, --rate) MUST be
 * passed in `--flag=value` form, never the two-token `--flag value` form.
 * Python argparse treats a two-token value that begins with `-` and is not a
 * negative number — e.g. text "-hello", "-h", or a lone "--word" — as a stray
 * option and aborts with exit code 2 ("expected one argument"). Because the
 * exit is deterministic, both the original attempt and the retry hit it, and the
 * failure surfaced as the misleading "edge-tts failed after 2 attempts (exit
 * code 2). Is edge-tts installed?" — even though edge-tts was installed and fine.
 * The `=` form binds the value to the flag unconditionally (argparse splits on
 * the first `=`), so any text — including one starting with a dash — passes
 * through verbatim. This was the root cause of intermittent voice_speak/voice_ask
 * failures (the intermittency was just which utterances happened to start with a
 * dash-led single token).
 */
export function buildEdgeTTSArgs(
  python3: string,
  scriptPath: string,
  text: string,
  voice: string,
  rate: string,
  audioFile: string,
  metadataFile: string,
): string[] {
  return [
    python3,
    scriptPath,
    `--text=${text}`,
    `--voice=${voice}`,
    `--rate=${rate}`,
    // write paths are absolute (start with "/"), never dash-led, but keep the
    // =-form for consistency so no argument can ever be re-interpreted as a flag.
    `--write-media=${audioFile}`,
    `--write-metadata=${metadataFile}`,
  ];
}

function parseWordBoundaries(metadataFile: string): WordBoundary[] {
  try {
    const metaRaw = readFileSync(metadataFile, "utf-8");
    return metaRaw
      .trim()
      .split("\n")
      .filter((line) => line.length > 0)
      .map((line) => {
        const parsed = JSON.parse(line);
        return {
          offset_ms: Math.round(parsed.offset / 10000),
          duration_ms: Math.round(parsed.duration / 10000),
          text: parsed.text as string,
        };
      });
  } catch {
    return [];
  }
}

/**
 * Synthesize with edge-tts, retrying once on failure.
 * Returns a result object instead of throwing, so callers can handle gracefully.
 */
export async function synthesizeWithRetry(
  text: string,
  voice: string,
  rate: string,
  audioFile: string,
  scriptPath: string,
  maxRetries = 1,
): Promise<SynthesizeResult> {
  const metadataFile = audioFile.replace(".mp3", ".meta.ndjson");
  let lastError = "";

  for (let attempt = 0; attempt <= maxRetries; attempt++) {
    if (attempt > 0) {
      console.error(
        `[voicelayer] edge-tts retry ${attempt}/${maxRetries} for: "${text.slice(0, 50)}..."`,
      );
    }

    try {
      const synth = Bun.spawn(
        buildEdgeTTSArgs(
          resolvedPython3,
          scriptPath,
          text,
          voice,
          rate,
          audioFile,
          metadataFile,
        ),
      );

      // Hard timeout per attempt — prevents hanging on network stalls
      const exitCode = await Promise.race([
        synth.exited,
        new Promise<number>((resolve) =>
          setTimeout(() => {
            try {
              synth.kill("SIGTERM");
            } catch {}
            resolve(-1);
          }, SYNTH_TIMEOUT_MS),
        ),
      ]);

      if (exitCode === -1) {
        lastError = `edge-tts timed out after ${SYNTH_TIMEOUT_MS / 1000}s`;
        console.error(
          `[voicelayer] ${lastError} (attempt ${attempt + 1}/${maxRetries + 1})`,
        );
        continue;
      }

      if (exitCode === 0) {
        const wordBoundaries = parseWordBoundaries(metadataFile);
        try {
          unlinkSync(metadataFile);
        } catch {}

        return {
          success: true,
          attempts: attempt + 1,
          audioFile,
          wordBoundaries,
        };
      }

      lastError = `exit code ${exitCode}`;
      console.error(
        `[voicelayer] edge-tts failed with ${lastError} (attempt ${attempt + 1}/${maxRetries + 1})`,
      );
    } catch (err) {
      lastError = err instanceof Error ? err.message : String(err);
      console.error(`[voicelayer] edge-tts spawn error: ${lastError}`);
    }
  }

  // All retries exhausted
  try {
    unlinkSync(metadataFile);
  } catch {}

  // AIDEV-NOTE: Fail LOUD but ACCURATE. The old message hard-coded
  // "Is edge-tts installed?" for every failure, which was actively misleading:
  // exit code 2 was almost always an argument-encoding bug (now fixed via the
  // =-form args in buildEdgeTTSArgs), and other failures are runtime/network
  // errors from Microsoft's edge-tts endpoint. Only point at a missing install
  // when the health check actually reports the module is unimportable.
  // `lastError` (e.g. "exit code 2") is always included so the real failure is
  // diagnosable, and the resolved interpreter path is surfaced so PATH
  // divergence in daemon mode is visible.
  const importable = checkEdgeTTSHealth();
  const base = `edge-tts synthesis failed after ${maxRetries + 1} attempts (${lastError}) using ${resolvedPython3}.`;
  const hint = importable
    ? ` edge-tts IS importable by that interpreter, so this is a runtime/network error from the edge-tts service, not a missing install.`
    : ` edge-tts is NOT importable by that interpreter — install it: ${resolvedPython3} -m pip install edge-tts`;

  return {
    success: false,
    attempts: maxRetries + 1,
    error: base + hint,
  };
}
