import { mkdirSync } from "node:fs";
import { join } from "node:path";

// Keep fixtures inside the preload run so dead-run cleanup sweeps them.
export function bundleFixtureRoot(): string {
  const runRoot = process.env.VOICELAYER_TEST_RUN_ROOT;
  if (!runRoot) throw new Error("Bundle fixtures require the isolated test preload");
  const root = join(runRoot, "fixtures.noindex");
  mkdirSync(root, { recursive: true });
  return root;
}
