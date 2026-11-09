import { existsSync, realpathSync } from "node:fs";
import { dirname, isAbsolute, join, relative, resolve, sep } from "node:path";
import { homedir } from "node:os";
import { requireIsolatedOverride } from "./test-isolation";

// Resolve existing ancestors too, so a symlink cannot redirect new caches into an app.
function resolvedDestination(path: string): string {
  if (existsSync(path)) return realpathSync(path);
  const parent = dirname(path);
  if (parent === path) throw new Error("parakeet-pycache-unresolved");
  return join(resolvedDestination(parent), relative(parent, path));
}

export function parakeetChildEnvironment(env: NodeJS.ProcessEnv = process.env): NodeJS.ProcessEnv {
  const isolated = env.VOICELAYER_TEST_ISOLATED === "1";
  requireIsolatedOverride(env, "VOICELAYER_TMP_ROOT");
  const base = isolated ? join(env.VOICELAYER_TMP_ROOT!, "cache/voicelayer") : join(homedir(), "Library/Caches/voicelayer");
  const prefix = env.VOICELAYER_PARAKEET_PYCACHE_PREFIX || join(base, "pycache");
  if (!isAbsolute(prefix)) throw new Error("parakeet-pycache-must-be-absolute");
  const destination = resolvedDestination(resolve(prefix));
  if ([resolve(prefix), destination].some(path => path.split(sep).some(part => /\.app$/i.test(part)))) {
    throw new Error("parakeet-pycache-inside-app");
  }
  if (isolated && !destination.startsWith(resolvedDestination(resolve(base)) + sep)) {
    throw new Error("parakeet-pycache-outside-test-cache");
  }
  const child: NodeJS.ProcessEnv = { ...env, PYTHONPYCACHEPREFIX: destination };
  delete child.PYTHONDONTWRITEBYTECODE;
  return child;
}
