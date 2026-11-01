import { afterEach, expect, test } from "bun:test";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { join, resolve } from "node:path";
import { readInstallerController, readInstallerGateState, readUpdateGateFile } from "../update-gate-storage";
import { updateVoiceGate, withVoiceAdmission } from "../update-gate-admission";
import { sameLease } from "../update-gate";
import type { runGatedInstall as Install } from "../update-gate-installer";

const saved = { ...process.env };
const keys = ["VOICELAYER_UPDATE_GATE_PATH", "VOICELAYER_TEST_INSTALL_PROOF", "VOICELAYER_UPDATE_TARGET_SHA",
  "VOICELAYER_INSTALL_OPERATION", "VOICELAYER_SUPERVISED_BOOTSTRAP"];
afterEach(() => { for (const key of keys) {
  if (saved[key] === undefined) delete process.env[key]; else process.env[key] = saved[key];
} });
const source = resolve(import.meta.dir, "..");
type Event = { kind: string; value: unknown };
function waitFor(path: string) {
  const end = performance.now() + 2000;
  while (!existsSync(path) && performance.now() < end) Bun.sleepSync(0.1);
  expect(existsSync(path)).toBe(true);
}
function fixture() {
  expect(process.env.VOICELAYER_TEST_ISOLATED).toBe("1");
  const root = mkdtempSync(join(process.env.VOICELAYER_TEST_RUN_ROOT!, "entry-"));
  const gate = join(root, "g"), proof = join(root, "proof"), installed = join(root, "installed");
  mkdirSync(gate + ".admissions");
  writeFileSync(gate, JSON.stringify({ version: 1, kind: "OPEN", generation: 0, released: null }));
  writeFileSync(proof, JSON.stringify({ phase: "idle", ready: true }));
  Object.assign(process.env, { VOICELAYER_UPDATE_GATE_PATH: gate, VOICELAYER_TEST_INSTALL_PROOF: proof,
    VOICELAYER_UPDATE_TARGET_SHA: "a".repeat(40), VOICELAYER_INSTALL_OPERATION: "", VOICELAYER_SUPERVISED_BOOTSTRAP: "" });
  return { root, gate, installed, trace: join(root, "trace"), held: join(root, "held"),
    release: join(root, "release"), released: join(root, "released") };
}
type Fixture = ReturnType<typeof fixture>;
function events(f: Fixture): Event[] {
  return existsSync(f.trace) ? readFileSync(f.trace, "utf8").trim().split("\n").filter(Boolean).map(line => JSON.parse(line)) : [];
}

// Source wrappers coordinate a real read/release, never synthesize a result or error.
// Keep the source harness boundary; only the module's location changes.
function relocate(text: string, base: string): string {
  return text.replace(/(["'])(\.[^"']+)\1/g, (whole, _quote: string, specifier: string) => {
    const path = resolve(base, specifier);
    return existsSync(path + ".ts") || existsSync(path) ? JSON.stringify(path) : whole;
  });
}
async function controlledInstaller(f: Fixture, releaseOnRead = true): Promise<typeof Install> {
  const support = join(f.root, "support.ts"), participant = join(f.root, "participant.ts");
  writeFileSync(support, `import { appendFileSync, existsSync, readFileSync, writeFileSync } from "node:fs";
const f = ${JSON.stringify(f)};
export function record(kind: string, value: unknown) { appendFileSync(f.trace, JSON.stringify({kind,value})+"\\n"); }
export function probe(value: boolean) { record("probe", value); return value; }
export function entry<T>(read: () => T): T {
  let value: T | undefined, failure: unknown;
  record("held", existsSync(f.gate+".lock"));
  try { value = read(); record("read", value); }
  catch (error) { failure = error; record("error", error instanceof Error ? error.message : String(error)); }
  if (existsSync(f.held) && !existsSync(f.release)) {
    record("bytes", JSON.parse(readFileSync(f.gate,"utf8")));
    record("controller", existsSync(f.gate+".controller")); record("installed", existsSync(f.installed));
    if (${releaseOnRead}) {
      writeFileSync(f.release,"release");
      const end = performance.now()+2000;
      while(!existsSync(f.released) && performance.now()<end) Bun.sleepSync(0.1);
      if(!existsSync(f.released)) throw Error("ENTRY_RELEASE_TIMEOUT");
      record("released", !existsSync(f.gate+".lock"));
    }
  }
  if (failure !== undefined) throw failure;
  return value!;
}
`);
  let helper = relocate(readFileSync(join(source, "update-gate-installer-participant.ts"), "utf8"), source);
  const probe = 'export const installerGateContended = () => existsSync(updateGateFilePath() + ".lock");';
  expect(helper.split(probe)).toHaveLength(2);
  helper = helper.replace(probe, 'export const installerGateContended = () => probe(existsSync(updateGateFilePath() + ".lock"));');
  writeFileSync(participant, `import { probe } from ${JSON.stringify(support)};\n` + helper);
  let installer = readFileSync(join(source, "update-gate-installer.ts"), "utf8");
  const start = installer.indexOf("export async function runGatedInstall(");
  const before = installer.slice(0, start), body = installer.slice(start);
  const entry = /const current = await retryContention\(\(\) => (readUpdateGateFile|readInstallerGateState)\(\), (state => state.kind === "UNKNOWN"|\(\) => false)\);/g;
  expect([...body.matchAll(entry)]).toHaveLength(1);
  installer = before + body.replace(entry, 'const current = await retryContention(() => entry(() => $1()), $2);');
  installer = relocate(installer, source).replaceAll("import.meta.dir", JSON.stringify(source));
  installer = installer.replace(JSON.stringify(join(source, "update-gate-installer-participant")), JSON.stringify(participant));
  const file = join(f.root, "installer.ts");
  writeFileSync(file, `import { entry } from ${JSON.stringify(support)};\n` + installer);
  return (await import(file)).runGatedInstall;
}
function holder(f: Fixture) {
  const storage = join(source, "update-gate-storage.ts");
  const script = `import { withUpdateGateLock } from ${JSON.stringify(storage)};
import { existsSync, writeFileSync } from "node:fs";
const f=${JSON.stringify(f)};
withUpdateGateLock(() => {
  writeFileSync(f.held, String(process.pid));
  const end=performance.now()+5000;
  while(!existsSync(f.release) && performance.now()<end) Bun.sleepSync(0.1);
  if(!existsSync(f.release)) throw Error("ENTRY_HOLDER_TIMEOUT");
});
writeFileSync(f.released,"released");`;
  return Bun.spawn([process.execPath, "-e", script], { env: process.env, stdout: "pipe", stderr: "pipe", timeout: 8000 });
}
async function releaseHolder(f: Fixture, child: ReturnType<typeof holder>) {
  if (!existsSync(f.release)) writeFileSync(f.release, "cleanup-release");
  const status = await child.exited, stderr = await new Response(child.stderr).text();
  console.log("ENTRY_HOLDER " + JSON.stringify({ status, stderr }));
  expect({ status, stderr }).toEqual({ status: 0, stderr: "" });
  expect(existsSync(f.released)).toBe(true);
  expect(existsSync(f.gate + ".lock")).toBe(false); // Only the holder removed its own lock.
}
function assertRefused(f: Fixture) {
  expect(existsSync(f.installed)).toBe(false);
  expect(existsSync(f.gate + ".controller")).toBe(false);
}
function installCommand(f: Fixture): string[] {
  // A real child checks its inherited exact lease against actual COMMITTED bytes.
  return [process.execPath, "-e", `import { readFileSync, writeFileSync } from "node:fs";
const owner=JSON.parse(process.env.VOICELAYER_INSTALL_OPERATION!);
const state=JSON.parse(readFileSync(${JSON.stringify(f.gate)},"utf8"));
const controller=JSON.parse(readFileSync(${JSON.stringify(f.gate + ".controller")},"utf8"));
if(state.kind!=="COMMITTED" || JSON.stringify(state.lease)!==JSON.stringify(owner.lease) ||
controller.lease.operationId!==owner.lease.operationId || controller.lease.generation!==owner.lease.generation ||
controller.pid!==owner.pid || controller.identity!==owner.identity) throw Error("INSTALL_BEFORE_EXACT_COMMIT");
writeFileSync(${JSON.stringify(f.installed)},JSON.stringify(owner.lease),{flag:"wx"});`];
}

test("entry retries a required real G1 collision after release before the contention probe", async () => {
  const f = fixture();
  expect(withVoiceAdmission(() => "open")).toBe("open");
  const install = await controlledInstaller(f), child = holder(f);
  let result: number | undefined, failure: unknown;
  try { waitFor(f.held); result = await install(installCommand(f)); }
  catch (error) { failure = error; }
  finally { await releaseHolder(f, child); }
  const trace = events(f);
  console.log("ENTRY_COLLISION " + JSON.stringify({ trace, result: result ?? null,
    failure: failure instanceof Error ? failure.message : failure ?? null }));
  expect(trace[0]).toEqual({ kind: "held", value: true });
  expect(trace.find(e => e.kind === "bytes")?.value).toEqual({ version: 1, kind: "OPEN", generation: 0, released: null });
  expect(trace.find(e => e.kind === "controller")?.value).toBe(false);
  expect(trace.find(e => e.kind === "installed")?.value).toBe(false);
  expect(trace.find(e => e.kind === "released")?.value).toBe(true);
  // The old path gives read UNKNOWN, released true, probe false, then refusal.
  expect(trace.filter(e => e.kind === "error").map(e => e.value)).toEqual(["UPDATE_GATE_LOCKED"]);
  expect(trace.filter(e => e.kind === "probe")).toEqual([]);
  expect(trace.filter(e => e.kind === "read").map(e => (e.value as { kind: string }).kind)).toEqual(["OPEN"]);
  expect(failure).toBeUndefined(); expect(result).toBe(0);
  const current = readInstallerGateState(), lease = JSON.parse(readFileSync(f.installed, "utf8"));
  expect(current.kind).toBe("COMMITTED");
  expect(current.kind !== "UNKNOWN" && current.kind !== "OPEN" && sameLease(current.lease, lease)).toBe(true);
  expect(readInstallerController(f.gate)?.lease.operationId).toBe(lease.operationId);
  expect(() => withVoiceAdmission(() => { throw Error("VOICE_ENTERED_CLOSED_GATE"); })).toThrow("UPDATE_BUSY");
  expect(readUpdateGateFile().kind).toBe("COMMITTED");
}, 60000);

for (const fault of ["malformed", "diagnostic"]) test(`entry retains ${fault} UNKNOWN refusal`, async () => {
  const f = fixture();
  if (fault === "malformed") writeFileSync(f.gate, "{");
  else writeFileSync(f.gate + ".voice-diag.json", "sticky diagnostic");
  const bytes = readFileSync(f.gate, "utf8"), install = await controlledInstaller(f);
  expect(readInstallerGateState().kind).toBe("UNKNOWN");
  await expect(install(installCommand(f))).rejects.toThrow("UNKNOWN: gate unavailable or another update owns it");
  assertRefused(f); expect(readFileSync(f.gate, "utf8")).toBe(bytes);
  expect(events(f).filter(e => e.kind === "read")).toEqual([{ kind: "read", value: { kind: "UNKNOWN" } }]);
  if (fault === "diagnostic") expect(readFileSync(f.gate + ".voice-diag.json", "utf8")).toBe("sticky diagnostic");
  console.log("ENTRY_FAULT " + JSON.stringify({ fault, trace: events(f) }));
});

test("entry refuses an actual closed gate before installing or writing a controller", async () => {
  const f = fixture(), lease = { generation: 1, operationId: crypto.randomUUID(), ownerId: crypto.randomUUID(), targetSha: "a".repeat(40) };
  expect(updateVoiceGate({ kind: "REQUEST", lease }).kind).toBe("APPLIED");
  const bytes = readFileSync(f.gate, "utf8"), install = await controlledInstaller(f);
  await expect(install(installCommand(f))).rejects.toThrow("UNKNOWN: gate unavailable or another update owns it");
  assertRefused(f); expect(readFileSync(f.gate, "utf8")).toBe(bytes);
  expect(() => withVoiceAdmission(() => {})).toThrow("UPDATE_BUSY");
});

test("entry exhausts the unchanged contention bound without reaping a real holder", async () => {
  const f = fixture(), install = await controlledInstaller(f, false), child = holder(f);
  let failure: unknown;
  try {
    waitFor(f.held);
    try { await install(installCommand(f)); } catch (error) { failure = error; }
    expect(existsSync(f.gate + ".lock")).toBe(true);
    assertRefused(f);
    expect(readFileSync(f.held, "utf8")).toBe(String(child.pid));
  } finally { await releaseHolder(f, child); }
  console.log("ENTRY_EXHAUSTION " + JSON.stringify({ trace: events(f), failure: failure instanceof Error ? failure.message : failure }));
  expect(failure instanceof Error && failure.message).toBe("UPDATE_GATE_LOCKED");
  expect(events(f).filter(e => e.kind === "error")).toHaveLength(8);
  expect(readInstallerGateState().kind).toBe("OPEN");
}, 60000);
