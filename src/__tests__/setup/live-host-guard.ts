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
type SuiteBody = () => void;
type SuiteRunner = (label: string, body: SuiteBody) => void;

let announced = false;

/**
 * Test seam for the blocked branch. The real reason depends on this machine —
 * a bound `/tmp/voicelayer.sock` exists on Etan's Mac and not in CI — so the
 * only way to assert the guarded variants deterministically in both places is
 * to force the answer.
 */
let skipReasonOverride: (() => string | null) | null = null;

export function __setLiveHostSkipReasonForTests(
  override: (() => string | null) | null,
): void {
  skipReasonOverride = override;
  if (!override) announced = false;
}

function currentSkipReason(): string | null {
  return skipReasonOverride ? skipReasonOverride() : liveHostSkipReason();
}

function announce(reason: string): void {
  if (announced) return;
  announced = true;
  console.error(
    `[voicelayer] SKIPPING mic-touching suites in this file: ${reason}`,
  );
}

/**
 * Run `runner` only when the host is safe; otherwise skip loudly.
 *
 * AIDEV-NOTE: R-014 — every variant goes through here, not just the bare call.
 * Cursor caught this on PR #26: the statics used to forward straight to bun, so
 * `describe.only(…)`, `describe.if(true)(…)` and `describe.skipIf(false)(…)`
 * inside a guarded file would have run a mic-touching suite against a live
 * VoiceBar. `skipFallback` is what registers the skipped suite — `.each` needs
 * `describe.skip.each(table)` so the row-substituted labels still resolve.
 */
function guarded(
  runner: () => SuiteRunner,
  skipFallback: () => SuiteRunner,
): SuiteRunner {
  return (label, body) => {
    const reason = currentSkipReason();
    if (!reason) {
      runner()(label, body);
      return;
    }
    announce(reason);
    skipFallback()(`${label} — SKIPPED (${reason})`, body);
  };
}

const plainSkip = (): SuiteRunner => describe.skip as SuiteRunner;

const micTouchingDescribe = guarded(() => describe as SuiteRunner, plainSkip);

// AIDEV-NOTE: the statics are LAZY getters and every wrapper reads its bun
// counterpart at CALL time. `describe.only` is an accessor that THROWS under CI
// ("`.only` is disabled in CI environments"), so eagerly reading it into an
// Object.assign literal blew up at module load on every guarded file — 15 CI
// failures on the first push of this branch, invisible locally until
// `CI=true bun test`. Nothing here touches `.only` unless a suite really uses it.
//
// On a blocked host `.only` degrades to a plain skip. That un-sets bun's global
// "only" mode, so the rest of the run executes normally instead of exclusively —
// more suites run, all of them still guarded. Racing the live app is the one
// outcome this must never produce.
const statics: Record<string, unknown> = {
  // `.skip` and `.todo` never execute a body as a live suite — forward as-is.
  get skip() {
    return describe.skip;
  },
  get todo() {
    return describe.todo;
  },
  get only() {
    return guarded(() => describe.only as SuiteRunner, plainSkip);
  },
  get if() {
    return (condition: boolean): SuiteRunner =>
      guarded(() => describe.if(condition) as SuiteRunner, plainSkip);
  },
  get skipIf() {
    return (condition: boolean): SuiteRunner =>
      guarded(() => describe.skipIf(condition) as SuiteRunner, plainSkip);
  },
  get todoIf() {
    return (condition: boolean): SuiteRunner =>
      guarded(() => describe.todoIf(condition) as SuiteRunner, plainSkip);
  },
  get each() {
    return (table: readonly unknown[]): SuiteRunner =>
      guarded(
        () => describe.each(table as never) as unknown as SuiteRunner,
        () =>
          (describe.skip as unknown as { each: (t: never) => SuiteRunner }).each(
            table as never,
          ),
      );
  },
};

export const describeMicTouching: typeof describe = (() => {
  for (const key of Object.keys(statics)) {
    Object.defineProperty(micTouchingDescribe, key, {
      configurable: true,
      enumerable: true,
      get: Object.getOwnPropertyDescriptor(statics, key)!.get,
    });
  }
  return micTouchingDescribe as unknown as typeof describe;
})();
