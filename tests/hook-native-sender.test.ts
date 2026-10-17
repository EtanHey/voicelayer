import { expect, test } from "bun:test";
import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync, symlinkSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";

const source = resolve(import.meta.dir, "hook-term-sender.c");
const script = resolve(import.meta.dir, "test_hook_orphan_daemon.sh");
const cc = Bun.which("cc");
if (!cc) console.warn("SKIP native sender compilation checks: cc toolchain missing");

test.skipIf(!cc)("native sender compiles through the Linux branch", () => {
  const result = spawnSync(cc!, ["-fsyntax-only", "-U__APPLE__", source], { encoding: "utf8" });
  expect({ status: result.status, error: result.stderr }).toEqual({ status: 0, error: "" });
});

test("only a missing compiler skips; policy runs without any compiler", () => {
  const bin = mkdtempSync(join(tmpdir(), "ho3-build-"));
  try {
    for (const name of ["python3", "dirname", "ps"]) symlinkSync(Bun.which(name)!, join(bin, name));
    const run = (mode: string) => spawnSync("/bin/bash", [script, mode], { encoding: "utf8", env: { ...process.env, PATH: bin } });
    expect(run("--native-check").status).toBe(77);
    expect(run("--policy-check").status).toBe(0);
    writeFileSync(join(bin, "cc"), "#!/bin/sh\necho intentional-source-error >&2\nexit 42\n", { mode: 0o755 });
    const failed = run("--native-check");
    expect(failed.status).toBe(1);
    expect(failed.stdout + failed.stderr).toContain("intentional-source-error");
    expect(run("--policy-check").status).toBe(0);
  } finally { rmSync(bin, { recursive: true, force: true }); }
});

test.skipIf(!cc)("interpreter parser never records combined-flag or IFS command canaries", () => {
  const dir = mkdtempSync(join(tmpdir(), "ho3-argv-"));
  try {
    const cases: [string[], string][] = [
      [["bash", "-lc", "kill${IFS}-TERM${IFS}12345;sleep${IFS}1;#CANARY.py"], "unknown"],
      [["sh", "-xc", "CANARY.sh"], "unknown"],
      [["python3", "-c", "CANARY.py"], "unknown"],
      [["python3", "-W", "CANARY.py", "/tmp/actual.py"], "unknown"],
      [["node", "--eval=CANARY.ts"], "unknown"],
      [["bun", "-pe", "CANARY.ts"], "unknown"],
      [["bash", "kill${IFS}-TERM${IFS}12345;#CANARY.py"], "unknown"],
      [["unknown", "CANARY.py"], "unknown"],
      [["python3", "/tmp/session-cleanup.py", "CANARY.py"], "session-cleanup.py"],
      [["bash", "--", "/tmp/worker.sh"], "worker.sh"],
      [["node", "/tmp/worker.js"], "worker.js"],
      [["bun", "run", "/tmp/worker.ts"], "worker.ts"],
    ];
    const rows = cases.map(([args, expected]) => `{const char *args[] = {${args.map(x => JSON.stringify(x)).join(",")}}; char out[256] = "unknown"; script_entrypoint(args, ${args.length}, out, sizeof(out)); if(strcmp(out, ${JSON.stringify(expected)})) return ${cases.findIndex(x => x[0] === args) + 1};}`).join("\n");
    const harness = join(dir, "parser.c");
    writeFileSync(harness, `#include ${JSON.stringify(source)}\nint main(void) {\n${rows}\nreturn 0;\n}\n`);
    const build = spawnSync(cc!, ["-Wall", "-Wextra", "-Werror", harness, "-o", join(dir, "parser")], { encoding: "utf8" });
    expect({ status: build.status, error: build.stderr }).toEqual({ status: 0, error: "" });
    expect(spawnSync(join(dir, "parser")).status).toBe(0);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});
