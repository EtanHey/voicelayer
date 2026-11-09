import { isBunTestProcess } from "./bun-test-process";

// Process-local identity survives test env mutations but cannot be inherited.
const testProcess = isBunTestProcess();

/** Refuse unpreloaded tests before resolving or accessing any resident path. */
export function assertTestIsolation(): void {
  if (testProcess && process.env.VOICELAYER_TEST_ISOLATED !== "1") {
    throw new Error("[voicelayer] bun test requires the isolation preload (VOICELAYER_TEST_ISOLATED=1); run from the repo root or load src/__tests__/setup/preload.ts");
  }
}

/** Test-only safety contract. Never fall back to a user's paths after losing a redirect. */
export function requireIsolatedOverride(
  env: Record<string, string | undefined>,
  name: string,
): void {
  assertTestIsolation();
  if (env.VOICELAYER_TEST_ISOLATED === "1" && !env[name]?.trim()) {
    throw new Error(`[voicelayer] isolated test requires ${name}`);
  }
}
