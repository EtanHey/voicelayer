/**
 * Belt-and-braces guard: refuse to run mic-touching suites against a live host.
 *
 * AIDEV-NOTE: R-014. On 2026-09-06 three of Etan's live push-to-talk dictations
 * were cancelled (audio kept, never transcribed) at 15:43:27 / 15:43:43 /
 * 15:45:10 — seconds after `bun test` runs at 15:43:00, 15:43:38 and 15:44:04.
 * `bunfig.toml`'s preload makes that impossible by construction, so in practice
 * this guard never fires. It exists for the run that bypasses the preload:
 * `bun test --preload= …`, a bare `bun run` of a test file, or a future harness.
 */

import { existsSync, lstatSync } from "fs";
import {
  getVoiceBarSocketPath,
  isDefaultTmpRoot,
  isDefaultVoiceBarSocketPath,
} from "../../paths";
import { describe } from "bun:test";

export const ISOLATION_ENV = "VOICELAYER_TEST_ISOLATED";

export const LIVE_HOST_SKIP_REASON =
  "live VoiceBar on this host; set VOICELAYER_TEST_ISOLATED=1";

/** A bound Unix domain socket — a file that exists AND is a socket. */
export function isBoundSocket(path: string): boolean {
  try {
    return existsSync(path) && lstatSync(path).isSocket();
  } catch {
    return false;
  }
}

export interface LiveHostProbe {
  /** Override the path treated as "the default VoiceBar socket" (tests only). */
  defaultSocketPath?: string;
  /** Override the bound-socket check (tests only). */
  isBound?: (path: string) => boolean;
}

/**
 * The reason mic-touching suites must not run here, or null when it is safe.
 *
 * Safe means any one of: isolation was declared, the socket path was
 * redirected, the ephemeral root was redirected, or nothing is listening on the
 * default socket in the first place.
 */
export function liveHostSkipReason(
  env: NodeJS.ProcessEnv = process.env,
  probe: LiveHostProbe = {},
): string | null {
  if (env[ISOLATION_ENV]?.trim() === "1") return null;
  if (!isDefaultVoiceBarSocketPath(env)) return null;
  if (!isDefaultTmpRoot(env)) return null;

  const socketPath = probe.defaultSocketPath ?? getVoiceBarSocketPath(env);
  const bound = probe.isBound ?? isBoundSocket;
  return bound(socketPath) ? LIVE_HOST_SKIP_REASON : null;
}

/**
 * `describe` for a suite that may open the microphone or write paths a resident
 * VoiceBar reads. Skips loudly instead of racing the live app.
 *
 * Drop-in for bun:test's `describe` — import it as `describe` so every suite in
 * the file, nested ones included, is covered by the one swap.
 */
let announced = false;

function micTouchingDescribe(label: string, body: () => void): void {
  const reason = liveHostSkipReason();
  if (!reason) {
    describe(label, body);
    return;
  }
  if (!announced) {
    announced = true;
    console.error(
      `[voicelayer] SKIPPING mic-touching suites in this file: ${reason}`,
    );
  }
  describe.skip(`${label} — SKIPPED (${reason})`, body);
}

// AIDEV-NOTE: forwarded LAZILY, via getters. `describe.only` is an accessor that
// THROWS under CI ("`.only` is disabled in CI environments"), so eagerly reading
// it into an Object.assign literal blew up at module load on every guarded file
// — 15 CI failures on the first push of this branch, invisible locally until
// `CI=true bun test`. A getter only touches the property if a suite really uses it.
export const describeMicTouching: typeof describe = (() => {
  const forwarded = ["skip", "only", "todo", "if", "skipIf", "todoIf", "each"];
  for (const key of forwarded) {
    Object.defineProperty(micTouchingDescribe, key, {
      configurable: true,
      enumerable: true,
      get: () => (describe as unknown as Record<string, unknown>)[key],
    });
  }
  return micTouchingDescribe as unknown as typeof describe;
})();
