import { afterEach, beforeEach, expect, test } from "bun:test";
import { existsSync, mkdirSync, readFileSync, readdirSync, renameSync, rmSync, symlinkSync, writeFileSync } from "fs";
import { join } from "path";
import { testTmp } from "./setup/test-tmp";
import { getCacheDir } from "../paths";
import { migrateLegacyParakeetRuntime, provisionParakeetRuntime, type ParakeetRuntimeDependencies } from "../parakeet-runtime";
import { parakeetPython, readRecognizerAssets, PARAKEET_FILES } from "../recognizer-assets";
import { ParakeetServer, parakeetCommand } from "../parakeet-server";

const root = testTmp("parakeet-runtime"), state = join(root, "state"), cache = join(root, "cache");
const name = "parakeet-0.6.3-00000000-0000-4000-8000-000000000001";
const legacy = join(state, "runtimes", name), target = join(cache, "voicelayer", "runtimes", name);
const pointer = join(state, "parakeet-runtime.json");
const keys = ["VOICELAYER_STATE_DIR", "XDG_CACHE_HOME", "VOICELAYER_PARAKEET_PYTHON", "VOICELAYER_PARAKEET_MODEL"] as const;
const saved = Object.fromEntries(keys.map(key => [key, process.env[key]]));
const signal = () => new AbortController().signal;
function venv(directory: string) {
  mkdirSync(join(directory, "bin"), { recursive: true });
  writeFileSync(join(directory, "bin", "python"), "python-fixture");
  writeFileSync(join(directory, "retained"), "keep every byte");
}
function oldPointer() {
  venv(legacy);
  writeFileSync(pointer, JSON.stringify({ version: 1, python: join(legacy, "bin", "python"), mlx_audio: "0.6.3" }) + "\n");
}
beforeEach(() => {
  mkdirSync(state, { recursive: true });
  process.env.VOICELAYER_STATE_DIR = state;
  process.env.XDG_CACHE_HOME = cache;
  delete process.env.VOICELAYER_PARAKEET_PYTHON;
  delete process.env.VOICELAYER_PARAKEET_MODEL;
});
afterEach(() => {
  for (const key of keys) { if (saved[key] === undefined) delete process.env[key]; else process.env[key] = saved[key]; }
  rmSync(root, { recursive: true, force: true });
});

test("default provisioning remains denied under test preload", async () => {
  await expect(provisionParakeetRuntime(signal())).rejects.toThrow("runtime-network-denied-in-tests");
  expect(readdirSync(state)).toEqual([]);
  expect(existsSync(cache)).toBe(false);
});

test("cache resolver refuses to fall back to real cache in isolated tests", () => {
  expect(() => getCacheDir({ VOICELAYER_TEST_ISOLATED: "1" })).toThrow("requires XDG_CACHE_HOME");
});

test("provisioning stages and publishes in cache; state contains only the pointer", async () => {
  const calls: string[][] = [];
  const deps: ParakeetRuntimeDependencies = {
    findPython: () => "/stub/python3",
    run: async args => {
      expect(readdirSync(state)).toEqual([]);
      expect(existsSync(join(state, "runtimes"))).toBe(false);
      calls.push(args);
      expect(args[1]).toBe("-B");
      if (args.includes("venv")) {
        const staging = args.at(-1)!;
        expect(staging.startsWith(join(cache, "voicelayer", "runtimes", ".parakeet-"))).toBe(true);
        venv(staging);
      } else expect(args[0].startsWith(join(cache, "voicelayer", "runtimes", ".parakeet-"))).toBe(true);
    },
  };
  await provisionParakeetRuntime(signal(), deps);
  expect(calls).toHaveLength(4);
  expect(readdirSync(state)).toEqual(["parakeet-runtime.json"]);
  const executable = parakeetPython();
  expect(executable?.startsWith(join(cache, "voicelayer", "runtimes", "parakeet-0.6.3-"))).toBe(true);
  expect(existsSync(executable!)).toBe(true);
  expect(readdirSync(join(cache, "voicelayer", "runtimes"))).toHaveLength(1);
});

test("failed provisioning removes cache staging and never writes state", async () => {
  await expect(provisionParakeetRuntime(signal(), {
    findPython: () => "/stub/python3", run: async () => { throw new Error("stub-failed"); },
  })).rejects.toThrow("stub-failed");
  expect(readdirSync(state)).toEqual([]);
  expect(readdirSync(join(cache, "voicelayer", "runtimes"))).toEqual([]);
});

test("legacy runtime migrates before existing-Python validation, retaining bytes", async () => {
  oldPointer();
  const calls: string[][] = [];
  await provisionParakeetRuntime(signal(), { findPython: () => { throw new Error("must not provision"); }, run: async args => { calls.push(args); } });
  expect(calls).toHaveLength(1);
  expect(calls[0][0]).toBe(join(target, "bin", "python"));
  expect(readFileSync(join(target, "retained"), "utf8")).toBe("keep every byte");
  expect(existsSync(legacy)).toBe(false);
  expect(readdirSync(state)).toEqual(["parakeet-runtime.json"]);
  expect(migrateLegacyParakeetRuntime()).toBe("unchanged");
});

test("failed publication restores legacy runtime and exact old pointer", () => {
  oldPointer(); const original = readFileSync(pointer, "utf8");
  expect(() => migrateLegacyParakeetRuntime(() => { throw new Error("publication-denied"); })).toThrow("publication-denied");
  expect(readFileSync(pointer, "utf8")).toBe(original);
  expect(readFileSync(join(legacy, "retained"), "utf8")).toBe("keep every byte");
  expect(existsSync(target)).toBe(false);
  expect(migrateLegacyParakeetRuntime()).toBe("migrated");
});

test("interrupted rename converges from old pointer and already-moved runtime", () => {
  oldPointer(); mkdirSync(join(cache, "voicelayer", "runtimes"), { recursive: true }); renameSync(legacy, target);
  expect(migrateLegacyParakeetRuntime()).toBe("migrated");
  expect(parakeetPython()).toBe(join(target, "bin", "python"));
  expect(readFileSync(join(target, "retained"), "utf8")).toBe("keep every byte");
  expect(readdirSync(state)).toEqual(["parakeet-runtime.json"]);
});

test("conflicting destination refuses without deleting either runtime or pointer", () => {
  oldPointer(); venv(target); const original = readFileSync(pointer, "utf8");
  expect(() => migrateLegacyParakeetRuntime()).toThrow("migration-conflict");
  expect(readFileSync(pointer, "utf8")).toBe(original);
  expect(existsSync(join(legacy, "retained"))).toBe(true);
  expect(existsSync(join(target, "retained"))).toBe(true);
});

test("custom Python is never moved even when it is inside the legacy runtime", async () => {
  oldPointer(); const original = readFileSync(pointer, "utf8");
  process.env.VOICELAYER_PARAKEET_PYTHON = join(legacy, "bin", "python");
  expect(migrateLegacyParakeetRuntime()).toBe("unchanged");
  await provisionParakeetRuntime(signal(), { findPython: () => null, run: async args => { expect(args[0]).toBe(process.env.VOICELAYER_PARAKEET_PYTHON!); } });
  expect(existsSync(legacy)).toBe(true); expect(existsSync(cache)).toBe(false);
  expect(readFileSync(pointer, "utf8")).toBe(original);
});

test("missing custom Python refuses without provisioning or removing legacy files", async () => {
  oldPointer(); process.env.VOICELAYER_PARAKEET_PYTHON = join(root, "absent-custom-python");
  await expect(provisionParakeetRuntime(signal(), { findPython: () => { throw new Error("must not provision"); }, run: async () => { throw new Error("must not spawn"); } })).rejects.toThrow("configured-python-missing");
  expect(existsSync(legacy)).toBe(true); expect(existsSync(cache)).toBe(false);
});

test("symlinked legacy runtime is never relocated", () => {
  venv(join(root, "custom")); mkdirSync(join(state, "runtimes")); symlinkSync(join(root, "custom"), legacy);
  writeFileSync(pointer, JSON.stringify({ version: 1, python: join(legacy, "bin", "python") }));
  expect(() => migrateLegacyParakeetRuntime()).toThrow("migration-invalid");
  expect(existsSync(join(root, "custom", "retained"))).toBe(true);
});

test.each([false, true])("first Load recovers interrupted rename=%s before resolving command; status and health stay read-only", async interrupted => {
  oldPointer(); const model = join(root, "model"); mkdirSync(model);
  for (const file of PARAKEET_FILES) writeFileSync(join(model, file), "fixture");
  process.env.VOICELAYER_PARAKEET_MODEL = model;
  if (interrupted) { mkdirSync(join(cache, "voicelayer", "runtimes"), { recursive: true }); renameSync(legacy, target); }
  const server = new ParakeetServer({
    command: () => {
      expect(parakeetCommand()?.[0]).toBe(join(target, "bin", "python"));
      return [process.execPath, "-e", `for await (const line of console) { const r=JSON.parse(line); console.log(JSON.stringify({id:r.id,ok:true,ready:true,protocol:1,pid:process.pid})); }`];
    }, startupMs: 3000,
  });
  try {
    expect(server.isAvailable()).toBe(true);
    expect(readRecognizerAssets("parakeet").assets_present).toBe(!interrupted);
    expect(await server.health()).toBe(false);
    expect(existsSync(legacy)).toBe(!interrupted); expect(existsSync(target)).toBe(interrupted);
    await server.start();
    expect(await server.health()).toBe(true);
    expect(parakeetPython()).toBe(join(target, "bin", "python"));
    expect(existsSync(legacy)).toBe(false);
  } finally { await server.shutdown(); }
});
