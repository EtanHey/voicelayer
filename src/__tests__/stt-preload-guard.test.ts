import { test, expect, spyOn } from "bun:test";
import { readFileSync, existsSync, mkdirSync, writeFileSync, symlinkSync, mkdtempSync, rmSync, copyFileSync } from "node:fs";
import { join, dirname, delimiter, basename } from "node:path";
import { tmpdir } from "node:os";
import { installSttSpawnGuard, trustedParentRunRoot, assertNoInstalledStt } from "./setup/stt-spawn-guard";
import { testTmp } from "./setup/test-tmp";

test("plain preload denies PATH and installed absolute STT with private callsite logs", async () => {
  if (process.env.QA_VOICE_GOLDEN_LIVE === "1") return;
  expect(existsSync(process.env.QA_VOICE_WHISPER_MODEL!)).toBe(false);
  const commands = [["whisper-cli", "-m", "never-opened.bin"],
    ["/opt/homebrew/bin/whisper-server", "--port", "1"],
    ["/bin/sh", "-c", "whisper-cpp --help"]];
  for (const cmd of commands) {
    const p = Bun.spawn(cmd, { env: process.env, stdout: "pipe", stderr: "pipe" });
    const [code, err] = await Promise.all([p.exited, new Response(p.stderr).text(), new Response(p.stdout).text()]);
    expect(code).toBe(78); expect(err).toContain("STT_LIVE_OPT_IN_REQUIRED");
  }
  const rows = readFileSync(process.env.VOICELAYER_TEST_STT_STUB_LOG!, "utf8").trim().split("\n").map(line => JSON.parse(line));
  expect(rows.some((x) => x.engine === "whisper-server" && x.callsite.includes("stt-preload-guard.test.ts"))).toBe(true);
});

test("preload permits an isolated fake engine but denies a symlink escape", async () => {
  if (process.env.QA_VOICE_GOLDEN_LIVE === "1") return;
  const root = testTmp("stt-guard-fixture"); mkdirSync(root, { recursive: true });
  const fixture = join(root, "whisper-cli"); writeFileSync(fixture, "#!/bin/sh\nprintf FAKE_ONLY\n", { mode: 0o700 });
  const result = Bun.spawnSync([fixture], { env: process.env });
  expect(result.exitCode).toBe(0); expect(result.stdout.toString()).toBe("FAKE_ONLY");
  const escape = join(root, "whisper-server"); symlinkSync("/bin/echo", escape);
  const denied = Bun.spawnSync([escape, "must-not-run"], { env: process.env });
  expect(denied.exitCode).toBe(78); expect(denied.stdout.toString()).toBe("");
});

test("kernel denial covers absolute shell, Bun-e and Node routes; inherited roots and prompt logs stay bounded", () => {
  if (process.env.QA_VOICE_GOLDEN_LIVE === "1" || process.platform !== "darwin") return;
  const root = mkdtempSync(join(tmpdir(), "voicelayer-denied-stt-"));
  const outside = join(root, "whisper-cli"); const marker = join(root, "EXECUTED");
  writeFileSync(outside, `#!/bin/sh\nprintf EXECUTED > '${marker}'\n`, { mode: 0o700 });
  try {
    expect(trustedParentRunRoot(root)).toBeUndefined();
    expect(trustedParentRunRoot("/opt/homebrew")).toBeUndefined();
    expect(trustedParentRunRoot(process.env.VOICELAYER_TEST_RUN_ROOT)).toBe(process.env.VOICELAYER_TEST_RUN_ROOT);
    const directNode = require("node:child_process").spawnSync(outside, [], { env: process.env });
    expect(directNode.status === 78 || directNode.error?.code === "EPERM").toBe(true);
    const shell = Bun.spawnSync(["/bin/sh", "-c", `'${outside}'`], { env: process.env });
    expect(shell.exitCode).not.toBe(0);
    for (const code of [
      `try{const p=Bun.spawnSync([process.argv[1]],{env:process.env});process.exit(p.exitCode??1)}catch{process.exit(78)}`,
      `const p=require('node:child_process').spawnSync(process.argv[1],[],{env:process.env});process.exit(p.error?78:(p.status??1))`,
    ]) expect(Bun.spawnSync([process.execPath, "-e", code, outside], { env: process.env }).exitCode).not.toBe(0);
    expect(existsSync(marker)).toBe(false);
    const refused = Bun.spawnSync(["whisper-cli", "--prompt", "--PRIVATE_PROMPT_SENTINEL"], { env: process.env });
    expect(refused.exitCode).toBe(78);
    const last = readFileSync(process.env.VOICELAYER_TEST_STT_STUB_LOG!, "utf8").trim().split("\n").at(-1)!;
    expect(last).not.toContain("--PRIVATE_PROMPT_SENTINEL"); expect(JSON.parse(last)).toMatchObject({ denied: true, exitCode: 78, options: { prompt: true } });
  } finally { rmSync(root, { recursive: true, force: true }); }
});

test("descendant fixture exception admits own nested roots but refuses unrelated lookalikes", () => {
  if (process.env.QA_VOICE_GOLDEN_LIVE === "1" || process.platform !== "darwin") return;
  const external = mkdtempSync(join(tmpdir(), "voicelayer-unrelated-guard-"));
  const own = join(process.env.VOICELAYER_TEST_RUN_ROOT!, "fixture-boundary");
  const paths = [join(own, "whisper-cli"),
    join(own, "nested-repo", ".test-tmp", `${process.pid}-aabb`, "whisper-cli"),
    join(external, ".test-tmp", `${process.pid}-aabb`, "whisper-cli")];
  try {
    for (const p of paths) { mkdirSync(dirname(p), { recursive: true }); writeFileSync(p, "#!/bin/sh\nprintf SYNTHETIC_MARKER_ONLY\n", { mode: 0o700 }); }
    for (const p of paths.slice(0, 2)) {
      const x = Bun.spawnSync(["/bin/sh", "-c", "exec \"$1\"", "guard-control", p], { env: process.env });
      expect(x.exitCode).toBe(0); expect(x.stdout.toString()).toBe("SYNTHETIC_MARKER_ONLY");
    }
    const refused = Bun.spawnSync(["/bin/sh", "-c", "exec \"$1\"", "guard-control", paths[2]], { env: process.env });
    expect(refused.exitCode).not.toBe(0);
    expect(refused.stdout.toString()).toBe("");
  } finally { rmSync(external, { recursive: true, force: true }); }
});

for (const coldCompletes of [true, false]) test(`cold probe is bounded and reports raw failures: ${coldCompletes}`, () => {
  if (process.env.QA_VOICE_GOLDEN_LIVE === "1" || process.platform !== "darwin") return;
  const root = mkdtempSync(join(process.env.VOICELAYER_TEST_RUN_ROOT!, "cold-probe-"));
  const keys = ["PATH", "QA_VOICE_WHISPER_MODEL", "VOICELAYER_TEST_STT_STUB_LOG", "VOICELAYER_TEST_STT_GUARD_ROOT", "VOICELAYER_PARAKEET_PYTHON"];
  const saved = keys.map(k => process.env[k]);
  delete process.env.VOICELAYER_PARAKEET_PYTHON;
  const timeouts: number[] = [];
  const spawn = spyOn(Bun, "spawnSync").mockImplementation(((command: string[], options: { timeout: number }) => {
    timeouts.push(options.timeout);
    if (command[0].endsWith("voicelayer-test-stt-kernel-canary-v3")) throw Object.assign(Error("denied fixture canary"), { code: "EPERM" });
    if (coldCompletes && options.timeout >= 10000) return { exitCode: 77, signalCode: null, success: false };
    throw Object.assign(Error("cold synthetic timeout"), { code: "ETIMEDOUT" });
  }) as never);
  try {
    if (coldCompletes) expect(() => installSttSpawnGuard(root)).not.toThrow();
    else expect(() => installSttSpawnGuard(root)).toThrow(/ETIMEDOUT/);
    expect(timeouts.length).toBeGreaterThanOrEqual(2);
    expect(timeouts.every(t => t >= 10000 && t <= 30000)).toBe(true);
  } finally {
    spawn.mockRestore();
    keys.forEach((k, i) => { if (saved[i] === undefined) delete process.env[k]; else process.env[k] = saved[i]; });
  }
});


test("inherited verification cache skips neutral execution and still requires kernel denial", () => {
  if (process.env.QA_VOICE_GOLDEN_LIVE === "1" || process.platform !== "darwin") return;
  const parent = process.env.VOICELAYER_TEST_RUN_ROOT!;
  const cachedRoot = process.env.VOICELAYER_TEST_STT_GUARD_ROOT!;
  expect(cachedRoot).toBeTruthy();
  const root = mkdtempSync(join(parent, "cached-guard-"));
  const keys = ["PATH", "QA_VOICE_WHISPER_MODEL", "VOICELAYER_TEST_STT_STUB_LOG", "VOICELAYER_TEST_STT_GUARD_ROOT", "VOICELAYER_PARAKEET_PYTHON"];
  const saved = keys.map(k => process.env[k]);
  const commands: string[][] = [];
  const original = Bun.spawnSync;
  const spawn = spyOn(Bun, "spawnSync").mockImplementation(((...args: Parameters<typeof Bun.spawnSync>) => {
    commands.push(args[0] as string[]);
    return Reflect.apply(original, Bun, args);
  }) as never);
  try {
    installSttSpawnGuard(root, parent);
    expect(commands).toEqual([[join(cachedRoot, "voicelayer-test-stt-kernel-canary-v3")]]);
    expect(process.env.VOICELAYER_TEST_STT_GUARD_ROOT).toBe(cachedRoot);
    expect(existsSync(join(root, "stt-neutral-exec-probe"))).toBe(false);
  } finally {
    spawn.mockRestore();
    keys.forEach((k, i) => { if (saved[i] === undefined) delete process.env[k]; else process.env[k] = saved[i]; });
  }
});

test("malformed inherited verification cache takes the full enforcement check", () => {
  if (process.env.QA_VOICE_GOLDEN_LIVE === "1" || process.platform !== "darwin") return;
  const parent = process.env.VOICELAYER_TEST_RUN_ROOT!;
  const root = mkdtempSync(join(parent, "uncached-guard-"));
  const keys = ["PATH", "QA_VOICE_WHISPER_MODEL", "VOICELAYER_TEST_STT_STUB_LOG", "VOICELAYER_TEST_STT_GUARD_ROOT", "VOICELAYER_PARAKEET_PYTHON"];
  const saved = keys.map(k => process.env[k]);
  const commands: string[][] = [];
  const original = Bun.spawnSync;
  const spawn = spyOn(Bun, "spawnSync").mockImplementation(((...args: Parameters<typeof Bun.spawnSync>) => {
    commands.push(args[0] as string[]);
    return Reflect.apply(original, Bun, args);
  }) as never);
  try {
    process.env.VOICELAYER_TEST_STT_GUARD_ROOT = "/opt/homebrew";
    installSttSpawnGuard(root, parent);
    expect(commands).toEqual([[join(root, "stt-neutral-exec-probe")], [join(root, "voicelayer-test-stt-kernel-canary-v3")]]);
    expect(process.env.VOICELAYER_TEST_STT_GUARD_ROOT).toBeUndefined();
  } finally {
    spawn.mockRestore();
    keys.forEach((k, i) => { if (saved[i] === undefined) delete process.env[k]; else process.env[k] = saved[i]; });
  }
});

test("non-darwin admission ignores verified inherited stubs but refuses real and tampered tools", () => {
  if (process.env.QA_VOICE_GOLDEN_LIVE === "1") return;
  const parentBin = process.env.PATH!.split(delimiter).find(path => basename(path) === "stt-disabled-bin")!;
  const root = mkdtempSync(join(tmpdir(), "stt-child-roots-")), child = join(root, "child");
  const lookalike = join(root, "stt-disabled-bin"); mkdirSync(child); mkdirSync(lookalike);
  try {
    expect(() => assertNoInstalledStt([parentBin], [child])).not.toThrow();
    for (const tool of ["whisper-cli", "whisper-cpp", "whisper-server"]) copyFileSync(join(parentBin, tool), join(lookalike, tool));
    expect(() => assertNoInstalledStt([lookalike], [child])).not.toThrow();
    writeFileSync(join(lookalike, "whisper-server"), "#!/bin/sh\nexit 0\n", { mode: 0o700 });
    expect(() => assertNoInstalledStt([lookalike], [child])).toThrow("installed Whisper");
    writeFileSync(join(root, "whisper-cli"), "#!/bin/sh\nexit 0\n", { mode: 0o700 });
    expect(() => assertNoInstalledStt([root], [child])).toThrow("installed Whisper");
  } finally { rmSync(root, { recursive: true, force: true }); }
});

for (const missing of [false, true]) test(`denial keeps its message and exit 78 when logging fails: missing=${missing}`, () => {
  const denied = join(import.meta.dir, "setup/stt-denied.ts");
  const code = `${missing ? "delete process.env.VOICELAYER_TEST_STT_STUB_LOG" : "process.env.VOICELAYER_TEST_STT_STUB_LOG=process.argv[1]"};await import(process.argv[2]);`;
  const result = Bun.spawnSync([process.execPath, "-e", code, process.env.VOICELAYER_TEST_RUN_ROOT!, denied], { env: process.env });
  expect(result.exitCode).toBe(78);
  expect(result.stderr.toString()).toContain("STT_GUARD_LOG_UNAVAILABLE");
  expect(result.stderr.toString()).toContain("STT_LIVE_OPT_IN_REQUIRED");
});

for (const kind of ["directory", "non-executable file"]) test(`non-darwin admission ignores ${kind} named whisper-cli`, () => {
  if (process.env.QA_VOICE_GOLDEN_LIVE === "1") return;
  const root = mkdtempSync(join(tmpdir(), "stt-non-engine-"));
  const path = join(root, "whisper-cli");
  try {
    if (kind === "directory") mkdirSync(path);
    else writeFileSync(path, "not an executable engine\n", { mode: 0o600 });
    expect(() => assertNoInstalledStt([root], [])).not.toThrow();
  } finally { rmSync(root, { recursive: true, force: true }); }
});
