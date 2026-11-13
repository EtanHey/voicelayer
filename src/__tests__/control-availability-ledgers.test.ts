import { expect, test } from "bun:test";
import { join } from "node:path";

// The control-availability ledgers are Python: the C5 source inventory and the TLC model table that the
// Swift oracle must match. Run them in the normal suite so a stale ledger fails the push hook.
const root = join(import.meta.dir, "..", "..");

for (const file of ["test_c5_inventory.py", "test_model_table.py"]) {
  test(`control-availability ledger ${file}`, () => {
    const run = Bun.spawnSync(["python3", "-B", "-m", "unittest", "-v", join("docs", "control-availability", file)], {
      cwd: root,
      env: process.env,
    });
    const output = run.stdout.toString() + run.stderr.toString();
    if (output.includes("SKIP LOUDLY")) console.warn(output);
    expect({ exitCode: run.exitCode, output }).toMatchObject({ exitCode: 0 });
  }, 120_000);
}
