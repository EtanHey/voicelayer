// Fixture subprocesses must never inherit a hook's repository selection.
export function fixtureGitEnv(): Record<string, string | undefined> {
  return Object.fromEntries(
    Object.entries(process.env).filter(([key]) => !key.startsWith("GIT_")),
  );
}
