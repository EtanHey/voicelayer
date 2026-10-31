import { afterEach, expect, test } from "bun:test";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { runGatedInstall } from "../update-gate-installer";
import { createInstallerParticipant, type InstallerParticipantDependencies } from "../update-gate-installer-participant";

const saved = { ...process.env };
afterEach(() => { for (const key of ["VOICELAYER_UPDATE_GATE_PATH", "VOICELAYER_TEST_INSTALL_PROOF", "VOICELAYER_UPDATE_TARGET_SHA"]) {
  if (saved[key] === undefined) delete process.env[key]; else process.env[key] = saved[key];
} });
function fixture() {
  const root = mkdtempSync(join(process.env.VOICELAYER_TEST_RUN_ROOT!, "g4c-")), gate = join(root, "g");
  mkdirSync(gate + ".admissions");
  writeFileSync(gate, JSON.stringify({ version: 1, kind: "OPEN", generation: 0, released: null }));
  const proof = join(root, "proof"); writeFileSync(proof, JSON.stringify({ phase: "idle", ready: true }));
  Object.assign(process.env, { VOICELAYER_UPDATE_GATE_PATH: gate, VOICELAYER_TEST_INSTALL_PROOF: proof, VOICELAYER_UPDATE_TARGET_SHA: "a".repeat(40) });
  let now = 0;
  const deps: InstallerParticipantDependencies = {
    request: async (_action, lease) => { const ack = { lease, activeOperations: 0, openArchives: 0 };
      return { kind: "ACKNOWLEDGED", native: ack, daemon: ack, identities: {
        native: { pid: 101, incarnation: "11111111-1111-4111-8111-111111111111" },
        daemon: { pid: 102, incarnation: "22222222-2222-4222-8222-222222222222" } } }; },
    processIdentity: pid => { Bun.sleepSync(3); return pid === 101 ? "birth /Applications/VoiceBar.app/Contents/MacOS/VoiceBar" : "birth /bun"; },
    processParent: () => 101, participantsExited: () => true, now: () => now,
    sleep: async (ms = 100) => { now += ms; await Bun.sleep(ms); },
  };
  const participant = createInstallerParticipant(deps); participant.quit = async () => {};
  return { root, gate, deps, participant, advance: (ms: number) => { now += ms; } };
}
for (const phase of ["OPEN", "DRAINING", "PREPARED"]) test(`G4c real 1.5 ms contender: 0/20 refusals at ${phase}`, async () => {
  let refused = 0;
  for (let i = 0; i < 20; i++) {
    const f = fixture(), trigger = join(f.root, "trigger"), held = join(f.root, "held");
    const holder = Bun.spawn([process.execPath, "-e", `
      const fs=require('node:fs'), [gate,trigger,held]=${JSON.stringify([f.gate, trigger, held])};
      const deadline=performance.now()+5000;
      while(!fs.existsSync(trigger)&&performance.now()<deadline) Bun.sleepSync(0.1);
      if(!fs.existsSync(trigger)) process.exit(2);
      const end=performance.now()+120;
      while(performance.now()<end){try{fs.mkdirSync(gate+'.lock');fs.writeFileSync(held,'held');Bun.sleepSync(1.5);fs.rmdirSync(gate+'.lock');}catch{}Bun.sleepSync(2.5);}
    `], { env: process.env, stdout: "ignore", stderr: "pipe" });
    // REQUEST runs with the contender already active; later phases trigger
    // precisely inside their proof bracket, after the before-sample.
    let triggered = false;
    const start = () => {
      if (triggered || JSON.parse(readFileSync(f.gate, "utf8")).kind !== phase) return;
      triggered = true; writeFileSync(trigger, "go");
      const end = performance.now() + 2000;
      while (!existsSync(held) && performance.now() < end) Bun.sleepSync(0.1);
      expect(existsSync(held)).toBe(true);
    };
    if (phase === "OPEN") { start(); }
    else {
      let calls = 0;
      const intercept = <T>(read: () => T) => () => {
        calls++; if (calls === (phase === "DRAINING" ? 2 : 3)) start(); return read();
      };
      const sync = f.participant.withProcessProof!, asyncProof = f.participant.withAcquisitionProof;
      f.participant.withProcessProof = read => sync(intercept(read));
      if (asyncProof) f.participant.withAcquisitionProof = read => asyncProof(intercept(read));
    }
    try { await runGatedInstall(["/usr/bin/true"], f.participant); } catch { refused++; }
    if (!triggered) writeFileSync(trigger, "finish");
    expect(await holder.exited).toBe(0);
  }
  console.log(`${phase}: ${refused}/20 refusals`); expect(refused).toBe(0);
}, 60000);

test("G4c precommit contention stays within receipt lifetime without identity resampling", async () => {
  const f = fixture(); let reads = 0, sleeps = 0;
  const parent = f.deps.processParent;
  f.deps.processParent = pid => { reads++; return parent(pid); };
  const request = f.deps.request;
  f.deps.request = async (action, lease) => {
    const result = await request(action, lease); f.advance(600); return result;
  };
  f.deps.sleep = async ms => { expect(ms).toBe(2); sleeps++; f.advance(ms ?? 0); };
  // Hold the first precommit acknowledgement; its receipt is already 600 ms old.
  // An independent timer releases the lock for Cancel.
  const holder = join(f.root, "held");
  const child = Bun.spawn([process.execPath, "-e", `const fs=require('node:fs'),g=${JSON.stringify(f.gate)},h=${JSON.stringify(holder)};
    const end=performance.now()+5000;while(performance.now()<end){if(JSON.parse(fs.readFileSync(g,'utf8')).kind==='DRAINING'){try{fs.mkdirSync(g+'.lock');fs.writeFileSync(h,'held');Bun.sleepSync(100);fs.rmdirSync(g+'.lock');break;}catch{}}Bun.sleepSync(0.1);}`],
    { env: process.env, stdout: "ignore", stderr: "pipe" });
  const refresh = f.participant.refresh;
  f.participant.refresh = async lease => { const result = await refresh(lease); const end = performance.now() + 2000;
    while (!existsSync(holder) && performance.now() < end) Bun.sleepSync(0.1); return result; };
  await expect(runGatedInstall(["/usr/bin/true"], f.participant)).rejects.toThrow("lock acquisition timed out");
  expect(await child.exited).toBe(0);
  expect(sleeps).toBeGreaterThan(0); expect(sleeps).toBeLessThanOrEqual(99);
  expect(reads).toBeLessThanOrEqual(4);
  expect(JSON.parse(readFileSync(f.gate, "utf8")).kind).toBe("OPEN");
});

test("foreign controller arriving after REQUEST makes COMMIT false and Cancel restores OPEN", async () => {
  const f = fixture(), refresh = f.participant.refresh;
  const stale = JSON.stringify({ version: 1, lease: { generation: 7, operationId: crypto.randomUUID() },
    pid: process.pid, identity: "old birth /bun" });
  f.participant.refresh = async lease => {
    const proof = await refresh(lease);
    if (JSON.parse(readFileSync(f.gate, "utf8")).kind === "PREPARED") writeFileSync(f.gate + ".controller", stale);
    return proof;
  };
  await expect(runGatedInstall(["/usr/bin/true"], f.participant)).rejects.toThrow("commit refused");
  expect(JSON.parse(readFileSync(f.gate, "utf8")).kind).toBe("OPEN");
  expect(readFileSync(f.gate + ".controller", "utf8")).toBe(stale);
  expect(existsSync(f.gate + ".lock")).toBe(false);
  expect(existsSync(f.gate + ".voice-diag.json")).toBe(false);
});

test.each([900, 975])("receipt age %d reserves 50 ms for the measured post-sample", async age => {
  const f = fixture(); let now = 0;
  f.deps.now = () => now;
  f.deps.sleep = async ms => { now += ms ?? 0; };
  const request = f.deps.request;
  f.deps.request = async (action, lease) => { const result = await request(action, lease); now += age; return result; };
  const lease = { generation: 1, operationId: crypto.randomUUID(), ownerId: crypto.randomUUID(), targetSha: "a".repeat(40) };
  await f.participant.refresh(lease);
  let reads = 0;
  await expect(f.participant.withAcquisitionProof!(() => { reads++; throw Error("UPDATE_GATE_LOCKED"); })).rejects.toThrow("lock acquisition timed out");
  expect(now).toBeLessThanOrEqual(Math.max(950, age));
  if (age > 950) expect(reads).toBe(0);
});

for (const source of [undefined, "supervised-bootstrap", "forged"]) test(`R2 nested validator authenticates operation source: ${source}`, async () => {
  const { validateInstallerOperation } = await import("../update-gate-installer");
  const f = fixture(), operation = join(f.root, "operation.json");
  await runGatedInstall([process.execPath, "-e", `await Bun.write(${JSON.stringify(operation)}, process.env.VOICELAYER_INSTALL_OPERATION)`], f.participant);
  const owner = JSON.parse(readFileSync(operation, "utf8"));
  if (source !== undefined) owner.source = source;
  const prior = process.env.VOICELAYER_INSTALL_OPERATION;
  process.env.VOICELAYER_INSTALL_OPERATION = JSON.stringify(owner);
  try {
    if (source === undefined) await validateInstallerOperation();
    else await expect(validateInstallerOperation()).rejects.toThrow("controller receipt mismatch");
  } finally {
    if (prior === undefined) delete process.env.VOICELAYER_INSTALL_OPERATION;
    else process.env.VOICELAYER_INSTALL_OPERATION = prior;
  }
});
