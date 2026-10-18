/** Test-only safety contract. Never fall back to a user's paths after losing a redirect. */
export function requireIsolatedOverride(
  env: Record<string, string | undefined>,
  name: string,
): void {
  if (env.VOICELAYER_TEST_ISOLATED === "1" && !env[name]?.trim()) {
    throw new Error(`[voicelayer] isolated test requires ${name}`);
  }
}
