/**
 * Select a fixture's isolated paths in the parent before the synchronous spawn
 * boundary. The preload then forwards those current keys, rather than accepting
 * conflicting child-only overrides. Restore immediately, never across an await.
 */
export function withChildFixtureEnv<T>(env: NodeJS.ProcessEnv, spawn: () => T): T {
  const previous = new Map(Object.keys(env).map(key => [key, process.env[key]]));
  try {
    for (const [key, value] of Object.entries(env)) {
      if (value === undefined) delete process.env[key];
      else process.env[key] = value;
    }
    return spawn();
  } finally {
    for (const [key, value] of previous) {
      if (value === undefined) delete process.env[key];
      else process.env[key] = value;
    }
  }
}
