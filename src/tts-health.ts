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

let healthCacheResult: boolean | null = null;
let healthCacheTime = 0;

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
      "python3",
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
  let lastExitCode = 0;

  for (let attempt = 0; attempt <= maxRetries; attempt++) {
    if (attempt > 0) {
      console.error(
        `[voicelayer] edge-tts retry ${attempt}/${maxRetries} for: "${text.slice(0, 50)}..."`,
      );
    }

    try {
      const synth = Bun.spawn([
        "python3",
        scriptPath,
        "--text",
        text,
        "--voice",
        voice,
        "--rate",
        rate,
        "--write-media",
        audioFile,
        "--write-metadata",
        metadataFile,
      ]);
      lastExitCode = await synth.exited;

      if (lastExitCode === 0) {
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

      console.error(
        `[voicelayer] edge-tts failed with exit code ${lastExitCode} (attempt ${attempt + 1}/${maxRetries + 1})`,
      );
    } catch (err) {
      console.error(
        `[voicelayer] edge-tts spawn error: ${err instanceof Error ? err.message : String(err)}`,
      );
    }
  }

  // All retries exhausted
  try {
    unlinkSync(metadataFile);
  } catch {}

  return {
    success: false,
    attempts: maxRetries + 1,
    error: `edge-tts failed after ${maxRetries + 1} attempts (last exit code: ${lastExitCode}). Is edge-tts installed? Run: pip3 install edge-tts`,
  };
}
