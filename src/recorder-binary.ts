/**
 * Single resolution point for the `rec` (sox) binary.
 *
 * AIDEV-NOTE: R-014 (test isolation on a live host). Before this module,
 * `src/input.ts` and `src/audio-utils.ts` each called `resolveBinary("rec", …)`
 * on their own, so any test that reached a real capture path — or merely the
 * `rec -n trim 0 0` device probe — opened Etan's microphone while he was
 * dictating. Every recorder spawn now goes through here, and the test preload
 * points it at a stub that emits silence and never touches the device.
 *
 * Contract:
 *   VOICELAYER_TEST_FAKE_REC=1   → use the stub at VOICELAYER_TEST_FAKE_REC_BIN
 *   VOICELAYER_TEST_REAL_MIC=1   → opt back in to the real device; wins over the
 *                                  stub, and is the ONLY way a test opens the mic
 */

import { resolveBinary } from "./resolve-binary";

/** Homebrew/Intel fallbacks for `rec`. */
export const REC_CANDIDATES = ["/opt/homebrew/bin/rec", "/usr/local/bin/rec"];

const FAKE_REC_ENV = "VOICELAYER_TEST_FAKE_REC";
const FAKE_REC_BIN_ENV = "VOICELAYER_TEST_FAKE_REC_BIN";
const REAL_MIC_ENV = "VOICELAYER_TEST_REAL_MIC";

/** True when the caller has explicitly opted this process in to the real mic. */
export function isRealMicOptIn(env: NodeJS.ProcessEnv = process.env): boolean {
  return env[REAL_MIC_ENV]?.trim() === "1";
}

/** True when recorder spawns should be served by the silence stub. */
export function isFakeRecorderActive(
  env: NodeJS.ProcessEnv = process.env,
): boolean {
  return env[FAKE_REC_ENV]?.trim() === "1" && !isRealMicOptIn(env);
}

/**
 * Resolve the binary to spawn for microphone capture and device probes.
 * Returns null exactly when the real `rec` is wanted and cannot be found —
 * callers already translate that into the "sox not installed" error.
 */
export function resolveRecorderBinary(
  env: NodeJS.ProcessEnv = process.env,
): string | null {
  if (isFakeRecorderActive(env)) {
    const stub = env[FAKE_REC_BIN_ENV]?.trim();
    // Missing stub is treated like a missing binary: callers already map null
    // to "sox not installed". Throwing here used to escape the device probe's
    // catch and crash `detectNativeInputFormat` (and would have spawned PATH
    // `rec` when that probe still had a `|| "rec"` fallback).
    return stub || null;
  }
  return resolveBinary("rec", REC_CANDIDATES);
}
