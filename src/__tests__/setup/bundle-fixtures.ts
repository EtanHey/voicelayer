import { mkdirSync } from "node:fs";
import { resolve } from "node:path";

// App-shaped test fixtures belong to the checkout, just like real build output.
export function bundleFixtureRoot(): string {
  const root = resolve(import.meta.dir, "../../../.build.noindex/test-bundles");
  mkdirSync(root, { recursive: true });
  return root;
}
