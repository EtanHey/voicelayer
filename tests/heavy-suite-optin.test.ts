import { describe, expect, test } from "bun:test";
import { mkdtempSync, mkdirSync, readFileSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { spawnSync } from "node:child_process";

const hook = readFileSync(new URL("../.githooks/pre-push", import.meta.url), "utf8");
const bash = Bun.which("bash")!;
const python = Bun.which("python3")!;
const helperPath = "Gits/golems/.worktrees/hooks-live/scripts/hooks/heavy-suite.py";

type Availability = "installed" | "missing-helper" | "missing-python";

function runHook(availability: Availability, status: number, guardStatus = 0) {
  const root = mkdtempSync(join(tmpdir(), "voicelayer-heavy-hook-"));
  try {
    const home = join(root, "home");
    const bin = join(root, "bin");
    const record = join(root, "events");
    mkdirSync(home);
    mkdirSync(bin);
    mkdirSync(join(root, "scripts"));
    symlinkSync(bash, join(bin, "bash"));
    symlinkSync(Bun.which("cat")!, join(bin, "cat"));
    if (availability !== "missing-python") symlinkSync(python, join(bin, "python3"));
    const helper = join(home, helperPath);
    if (availability !== "missing-helper") {
      mkdirSync(join(helper, ".."), { recursive: true });
      // Only test hook dispatch; the fleet helper's scheduling has its own tests.
      writeFileSync(helper, `import os, subprocess, sys
assert sys.argv[1:] == ["--", "bash", "scripts/run_tests.sh"]
with open(os.environ["HOOK_RECORD"], "a") as f: f.write("helper\\n")
raise SystemExit(subprocess.call(sys.argv[2:]))
`);
    }
    const devHelper = join(home, "Gits/golems/scripts/hooks/heavy-suite.py");
    mkdirSync(join(devHelper, ".."), { recursive: true });
    writeFileSync(devHelper, "raise SystemExit(99)\n");
    writeFileSync(join(root, "hook"), hook);
    writeFileSync(join(root, "scripts/guard-no-docslocal.sh"),
      'printf "guard\\n" >> "$HOOK_RECORD"\nexit "$GUARD_STATUS"\n');
    writeFileSync(join(root, "scripts/run_tests.sh"),
      'printf "suite\\n" >> "$HOOK_RECORD"\nexit "$SUITE_STATUS"\n');
    const result = spawnSync(bash, [join(root, "hook")], {
      cwd: root,
      env: { HOME: home, PATH: bin, HOOK_RECORD: record,
        SUITE_STATUS: String(status), GUARD_STATUS: String(guardStatus) },
      encoding: "utf8", timeout: 5000,
    });
    expect(result.error).toBeUndefined();
    return { status: result.status, stdout: result.stdout, stderr: result.stderr,
      events: readFileSync(record, "utf8") };
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
}

describe("pre-push heavy-suite opt-in", () => {
  test("references only the pinned installed helper", () => {
    expect(hook).toContain(`$HOME/${helperPath}`);
    expect(hook).not.toContain("$HOME/Gits/golems/scripts/hooks/heavy-suite.py");
  });
  for (const availability of ["installed", "missing-helper", "missing-python"] as const) {
    for (const status of [0, 7]) {
      test(`${availability}: preserves suite exit ${status} and guard order`, () => {
        const result = runHook(availability, status);
        expect(result.status).toBe(status);
        expect(result.events).toBe(availability === "installed" ? "guard\nhelper\nsuite\n" : "guard\nsuite\n");
        if (availability === "installed") expect(result.stderr).toBe("");
        else expect(result.stderr).toContain("heavy-suite: helper missing; running unqueued");
        if (status !== 0) expect(result.stdout).toContain("🛑 PUSH BLOCKED — regression harness failed.");
        else expect(result.stdout).not.toContain("PUSH BLOCKED");
      });
    }
    test(`${availability}: failing docs guard never enters helper or suite`, () => {
      const result = runHook(availability, 0, 9);
      expect(result.status).toBe(1);
      expect(result.events).toBe("guard\n");
      expect(result.stderr).toBe("");
    });
  }
});
