import { afterEach, beforeEach, expect, spyOn, test } from "bun:test";
import * as fs from "fs";
import { join } from "path";
import * as gate from "../update-gate-admission";
import * as storage from "../update-gate-storage";
import { readUpdateGateFile, withUpdateGateLock } from "../update-gate-storage";
const initial = { version: 1, kind: "OPEN", generation: 0, released: null };
const lease = { generation: 1, operationId: "10000000-0000-4000-8000-000000000001", ownerId: "20000000-0000-4000-8000-000000000001", targetSha: "a".repeat(40) };
const original = process.env.VOICELAYER_UPDATE_GATE_PATH;
let path: string;
const mocks: Array<{ mockRestore(): void }> = [];
beforeEach(() => {
  expect(process.env.VOICELAYER_TEST_ISOLATED).toBe("1");
  path = join(fs.mkdtempSync(join(process.env.VOICELAYER_TEST_RUN_ROOT!, "failopen-")), "gate.json");
  process.env.VOICELAYER_UPDATE_GATE_PATH = path;
  mocks.push(spyOn(console, "error").mockImplementation(() => {}));
});
afterEach(() => { mocks.splice(0).reverse().forEach(m => m.mockRestore()); process.env.VOICELAYER_UPDATE_GATE_PATH = original; });
function fixture() { fs.writeFileSync(path, JSON.stringify(initial)); fs.mkdirSync(path + ".admissions"); }
function refusesUpdate() {
  expect(gate.updateVoiceGate({ kind: "REQUEST", lease })).toEqual({ kind: "REFUSED", reason: "UNKNOWN" });
  expect(gate.acknowledgeVoiceDrain(lease, () => true)).toBeNull();
}
for (const failure of ["unsafe-ledger", "bootstrap-write", "registration-write", "registration-rename", "diagnostic-directory"]) {
  test(`R1 ${failure}: voice survives and owned lock releases; updater refuses`, () => {
    if (failure === "unsafe-ledger") { fs.writeFileSync(path, JSON.stringify(initial)); fs.writeFileSync(path + ".admissions", "unsafe"); }
    if (failure.startsWith("registration")) fixture();
    if (failure === "diagnostic-directory") { fs.writeFileSync(path, "{broken"); fs.mkdirSync(path + ".voice-diag.json"); }
    if (failure.endsWith("write")) mocks.push(spyOn(fs, "writeFileSync").mockImplementationOnce(() => { throw Error("synthetic write failure"); }));
    if (failure.endsWith("rename")) mocks.push(spyOn(fs, "renameSync").mockImplementationOnce(() => { throw Error("synthetic rename failure"); }));
    let continued = false;
    expect(() => gate.withVoiceAdmission(() => { continued = true; })).not.toThrow();
    expect(continued).toBe(true);
    expect(fs.existsSync(path + ".lock")).toBe(false);
    expect(console.error).toHaveBeenCalled();
    refusesUpdate();
  });
}
for (const method of ["lstatSync", "mkdirSync", "linkSync", "fsyncSync"] as const) test(`R1 bootstrap ${method} failure never escapes`, () => {
  const real = fs[method] as (...args: unknown[]) => unknown;
  let fired = false;
  const fail = spyOn(fs, method).mockImplementation(((...args: unknown[]) => {
    if (!fired && (method !== "lstatSync" || args[0] === path + ".admissions")) {
      fired = true; throw Error("synthetic IO error");
    }
    return real(...args);
  }) as never); mocks.push(fail);
  expect(() => gate.initializeVoiceGate()).not.toThrow();
  fail.mockRestore();
  expect(gate.withVoiceAdmission(() => "voice")).toBe("voice");
  expect(fs.existsSync(path + ".lock")).toBe(false); refusesUpdate();
});
test("R1 post-publication media-sync failure keeps OPEN bytes but updater UNKNOWN", () => {
  const real = storage.persistUpdateGateState;
  mocks.push(spyOn(storage, "persistUpdateGateState").mockImplementationOnce((...args) => {
    real(...args); throw Error("UPDATE_GATE_MEDIA_SYNC_FAILED");
  }));
  expect(gate.withVoiceAdmission(() => "voice")).toBe("voice");
  expect(JSON.parse(fs.readFileSync(path, "utf8"))).toEqual(initial);
  expect(fs.existsSync(path + ".lock")).toBe(false); refusesUpdate();
});
test("R1 unlink failure during release never escapes its lock body", () => {
  fixture(); const retained = gate.withVoiceAdmission(() => gate.captureVoiceAdmission());
  mocks.push(spyOn(fs, "unlinkSync").mockImplementationOnce(() => { throw Error("synthetic unlink failure"); }));
  expect(() => retained.release()).not.toThrow();
  expect(fs.existsSync(path + ".lock")).toBe(false); refusesUpdate();
});
test("R3 failed diagnostic write leaves refusal evidence without costing voice", () => {
  fixture(); fs.mkdirSync(path + ".lock");
  mocks.push(spyOn(fs, "writeFileSync").mockImplementation(() => { throw Error("synthetic disk full"); }));
  expect(gate.withVoiceAdmission(() => "voice")).toBe("voice");
  expect(fs.lstatSync(path + ".voice-diag.json").isDirectory()).toBe(true); refusesUpdate();
});
test("R3/N1 existing stale lock admits immediately without blocking timers or reaping evidence", async () => {
  fixture(); fs.mkdirSync(path + ".lock"); fs.writeFileSync(path + ".lock/owner", "do not reap");
  const sleep = spyOn(Bun, "sleepSync"); mocks.push(sleep);
  let control = false;
  setTimeout(() => { control = true; }, 0);
  const start = performance.now();
  expect(gate.withVoiceAdmission(() => "dictation")).toBe("dictation");
  expect(performance.now() - start).toBeLessThan(50);
  expect(sleep).not.toHaveBeenCalled();
  await Bun.sleep(5); expect(control).toBe(true);
  expect(fs.readFileSync(path + ".lock/owner", "utf8")).toBe("do not reap");
  expect(readUpdateGateFile()).toEqual({ kind: "UNKNOWN" }); refusesUpdate();
});
test("R3 a transient collision leaves durable UNKNOWN after the other owner unlocks", () => {
  fixture();
  withUpdateGateLock(() => expect(gate.withVoiceAdmission(() => "voice")).toBe("voice"));
  expect(fs.existsSync(path + ".lock")).toBe(false); refusesUpdate();
});
test("N2 thrown updater proof returns structured UNKNOWN and releases the lock", () => {
  fixture(); gate.updateVoiceGate({ kind: "REQUEST", lease });
  expect(gate.updateVoiceGate({ kind: "PREPARE", lease, native: { lease, activeOperations: 0, openArchives: 0 }, daemon: { lease, activeOperations: 0, openArchives: 0 } }, () => { throw Error("synthetic proof failure"); })).toEqual({ kind: "REFUSED", reason: "UNKNOWN" });
  expect(fs.existsSync(path + ".lock")).toBe(false);
});
test("N3 preserves first-seen diagnostic bytes and rate-limits repeated UNKNOWN logs", () => {
  fs.writeFileSync(path, "{broken");
  gate.withVoiceAdmission(() => {});
  const first = fs.readFileSync(path + ".voice-diag.json", "utf8");
  expect(JSON.parse(first)).toMatchObject({ pid: process.pid, at: expect.any(String) });
  for (let n = 0; n < 5; n++) gate.withVoiceAdmission(() => {});
  expect(fs.readFileSync(path + ".voice-diag.json", "utf8")).toBe(first);
  expect(console.error).toHaveBeenCalledTimes(1);
});
for (const name of ["daemon.ts", "mcp-server-daemon.ts", "mcp-server.ts"]) test(`R2 ${name} guards bootstrap and continues startup`, () => {
  const source = fs.readFileSync(join(import.meta.dir, "..", name), "utf8");
  const main = source.slice(source.indexOf("async function main()"));
  const guarded = main.match(/try\s*\{\s*initializeVoiceGate\(\);\s*\}\s*catch\s*\{[^}]*\}/)?.[0];
  expect(guarded).toBeDefined();
  const run = new Function("initializeVoiceGate", "console", `${guarded}; return 'continued';`);
  expect(run(() => { throw Error("gate unavailable"); }, console)).toBe("continued");
  expect(console.error).toHaveBeenCalled();
  if (name !== "mcp-server.ts") expect(main.indexOf(guarded!)).toBeGreaterThan(main.lastIndexOf("acquireProcessLock("));
  if (name === "mcp-server-daemon.ts") expect(main.indexOf(guarded!)).toBeGreaterThan(main.indexOf("if (isVoicelayerDisabled())"));
});
for (const kind of ["OPEN", "DRAINING"]) test(`R3 diagnostic-marked ${kind} admits unregistered until recovery`, () => {
  fixture();
  if (kind === "DRAINING") fs.writeFileSync(path, JSON.stringify({ version: 1, kind, lease }));
  fs.mkdirSync(path + ".voice-diag.json");
  expect(gate.withVoiceAdmission(() => { expect(fs.readdirSync(path + ".admissions")).toEqual([]); return "voice"; })).toBe("voice");
  refusesUpdate();
});
test("R3 diagnostic dangling symlink is UNKNOWN evidence in every process", () => {
  fixture(); fs.symlinkSync(path + "-absent", path + ".voice-diag.json");
  expect(gate.updateVoiceGate({ kind: "REQUEST", lease })).toEqual({ kind: "REFUSED", reason: "UNKNOWN" });
});
test("R3 path-validation IO fault stays UNKNOWN without bypassing path isolation", () => {
  const fail = spyOn(fs, "lstatSync").mockImplementationOnce(() => { throw Error("synthetic validation IO failure"); }); mocks.push(fail);
  expect(() => gate.initializeVoiceGate()).not.toThrow(); fail.mockRestore();
  expect(gate.withVoiceAdmission(() => "voice")).toBe("voice"); refusesUpdate();
});
test("N1 async admission retries transient contention while Stop/Cancel timers run", async () => {
  fixture(); fs.mkdirSync(path + ".lock");
  let control = false;
  const unlock = setTimeout(() => { control = true; fs.rmdirSync(path + ".lock"); }, 15);
  try {
    expect(await gate.withAsyncVoiceAdmission(() => {
      expect(control).toBe(true);
      expect(fs.readdirSync(path + ".admissions")).toHaveLength(1);
      return "voice";
    })).toBe("voice");
    expect(fs.existsSync(path + ".voice-diag.json")).toBe(false);
    expect(gate.updateVoiceGate({ kind: "REQUEST", lease }).kind).toBe("APPLIED");
  } finally { clearTimeout(unlock); if (fs.existsSync(path + ".lock")) fs.rmdirSync(path + ".lock"); }
});
test("R3 async timeout admits unregistered without reaping or retrying voice work", async () => {
  fixture(); fs.mkdirSync(path + ".lock"); let calls = 0, control = false;
  const tick = setTimeout(() => { control = true; }, 1);
  try {
    expect(await gate.withAsyncVoiceAdmission(() => { calls++; expect(control).toBe(true); return "voice"; })).toBe("voice");
    expect(calls).toBe(1); expect(fs.existsSync(path + ".lock")).toBe(true);
    expect(fs.existsSync(path + ".voice-diag.json")).toBe(true); refusesUpdate();
  } finally { clearTimeout(tick); }
});
test("N1 async retry observes closure before running any voice work", async () => {
  fixture(); fs.mkdirSync(path + ".lock"); let calls = 0;
  const close = setTimeout(() => { fs.writeFileSync(path, JSON.stringify({ version: 1, kind: "DRAINING", lease })); fs.rmdirSync(path + ".lock"); }, 10);
  try {
    await expect(gate.withAsyncVoiceAdmission(() => { calls++; })).rejects.toThrow("UPDATE_BUSY");
    expect(calls).toBe(0); expect(fs.existsSync(path + ".voice-diag.json")).toBe(false);
  } finally { clearTimeout(close); }
});
test("N1 never retries a voice body that throws a lock-shaped error", async () => {
  fixture(); let calls = 0;
  await expect(gate.withAsyncVoiceAdmission(() => { calls++; throw Error("UPDATE_GATE_LOCKED"); })).rejects.toThrow("UPDATE_GATE_LOCKED");
  expect(calls).toBe(1); expect(fs.readdirSync(path + ".admissions")).toEqual([]);
});
