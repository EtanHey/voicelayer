import { mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
/** Downstream installer-effect fixtures stub only the inherited-lease transport.
 * Real gate ownership and failure semantics are tested by update-gate-installer. */
export function stubInstallerTransport(root: string, path = process.env.PATH ?? "") {
  const bin = join(root, "gate-transport-bin"); mkdirSync(bin, { recursive: true });
  const next = (Bun.which("bun", { PATH: path }) ?? process.execPath).replaceAll("'", "'\\''");
  writeFileSync(join(bin, "bun"), `#!/bin/bash
if [[ "\${1:-}" == */src/update-gate-installer.ts && "\${2:-}" == --validate ]]; then exit 0; fi
exec '${next}' "$@"
`, { mode: 0o755 });
  return { PATH: `${bin}:${path}`, VOICELAYER_TEST_BUN_CANDIDATES: join(bin, "bun"), VOICELAYER_INSTALL_OPERATION: "fixture-admitted" };
}
