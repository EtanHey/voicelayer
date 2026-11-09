// Bun defaults NODE_ENV to test before importing modules, even without a bunfig.
// Keep that boundary if a suite later temporarily replaces process.env.
const testProcess = process.env.NODE_ENV === "test";

/** Refuse unpreloaded tests before resolving or accessing any resident path. */
export function assertTestIsolation(env: NodeJS.ProcessEnv = process.env): void {
  const unisolatedProcess = (testProcess || process.env.NODE_ENV === "test") &&
    process.env.VOICELAYER_TEST_ISOLATED !== "1";
  const unisolatedEnv = env.NODE_ENV === "test" && env.VOICELAYER_TEST_ISOLATED !== "1";
  if (unisolatedProcess || unisolatedEnv) {
    throw new Error("[voicelayer] bun test requires the isolation preload (VOICELAYER_TEST_ISOLATED=1); run from the repo root or load src/__tests__/setup/preload.ts");
  }
}

/** Test-only safety contract. Never fall back to a user's paths after losing a redirect. */
export function requireIsolatedOverride(
  env: Record<string, string | undefined>,
  name: string,
): void {
  assertTestIsolation(env);
  if (env.VOICELAYER_TEST_ISOLATED === "1" && !env[name]?.trim()) {
    throw new Error(`[voicelayer] isolated test requires ${name}`);
  }
}
