import { afterEach, beforeEach, expect, spyOn, test } from "bun:test";
import { mkdirSync, mkdtempSync, readFileSync, readdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { warmSelectedRecognizer } from "../recognizer-controller";
import { configureRecognizerBusyProbe, confirmRecognizerCleanup, noteRecognizerEffective, noteRecognizerEngine,
  persistRecognizer, setRecognizerRecovery } from "../recognizer-state";
import { ParakeetServer } from "../parakeet-server";
import * as admission from "../update-gate-admission";
import * as storage from "../update-gate-storage";
import { completeGatedInstall } from "../update-gate-installer";
import { installerProcessIdentity } from "../update-gate-installer-participant";
import * as stt from "../stt";
import { parakeetServer } from "../parakeet-server";

const saved = { ...process.env };
let root: string, server: ParakeetServer, starts: number, logs: string[];
let log: ReturnType<typeof spyOn>;
const lease = (generation = 1) => ({ generation, operationId: "10000000-0000-4000-8000-000000000001",
  ownerId: "20000000-0000-4000-8000-000000000001", targetSha: "a".repeat(40) });
const gatePath = () => process.env.VOICELAYER_UPDATE_GATE_PATH!;
function commit(generation = 1) {
  const l = lease(generation), ack = { lease: l, activeOperations: 0, openArchives: 0 };
  for (const command of [{ kind: "REQUEST", lease: l }, { kind: "PREPARE", lease: l, native: ack, daemon: ack }, { kind: "COMMIT", lease: l }])
    expect(admission.updateVoiceGate(command, () => true).kind).toBe("APPLIED");
  writeFileSync(gatePath() + ".controller", JSON.stringify({ version: 1, lease: { generation, operationId: l.operationId },
    pid: process.pid, identity: installerProcessIdentity(process.pid)! }));
}
async function complete(generation = 1) {
  const l = lease(generation), ack = { lease: l, activeOperations: 0 as const, openArchives: 0 as const };
  expect(await completeGatedInstall(l, 0, installerProcessIdentity(process.pid)!, {
    participant: { refresh: async () => ({ phase: "idle", ready: true, native: ack, daemon: ack }),
      verify: () => true, quit: async () => {}, withAcquisitionProof: async read => read() },
    installed: () => ({ sha: l.targetSha, unchanged: () => true }),
  })).toBe(true);
}
const tick = () => new Promise<void>(resolve => setImmediate(resolve));
async function until(check: () => boolean) {
  for (let i = 0; i < 200 && !check(); i++) await Bun.sleep(5);
  expect(check()).toBe(true);
}
const deps = () => ({ assetsPresent: () => true, startP: () => server.start(), startW: async () => { throw Error("unexpected Whisper start"); },
  stopP: () => server.unload(), stopW: async () => {}, reset() {} });
// On the base, execute the exact discarded boot promise from the daemon, with
// only the recognizer child replaced. This gives a behavioral RED, not an import failure.
const source = readFileSync(join(import.meta.dir, "../mcp-server-daemon.ts"), "utf8");
const bootRunner = source.includes("void runRecognizerBootWarmup(") ? (await import("../recognizer-boot-warmup")).runRecognizerBootWarmup : null;
function boot(signal = new AbortController().signal, maxWaitMs = 1000): Promise<void> {
  if (bootRunner) {
    return bootRunner(() => warmSelectedRecognizer(deps()), { signal, maxWaitMs, pollMs: 5 });
  }
  const legacy = source.match(/void withFreshAsyncVoiceAdmission\(\(\) => warmSelectedRecognizer\(\)\)\.catch\([\s\S]*?\n  \}\);/);
  expect(legacy).not.toBeNull();
  return new Function("withFreshAsyncVoiceAdmission", "warmSelectedRecognizer", "console", legacy![0].replace(/^void /, "return "))(
    admission.withFreshAsyncVoiceAdmission, () => warmSelectedRecognizer(deps()), console);
}
beforeEach(() => {
  expect(process.env.VOICELAYER_TEST_ISOLATED).toBe("1");
  root = mkdtempSync(join(process.env.VOICELAYER_TEST_RUN_ROOT!, "boot-"));
  process.env.VOICELAYER_STATE_DIR = root; delete process.env.QA_VOICE_STT_BACKEND;
  process.env.VOICELAYER_UPDATE_GATE_PATH = join(root, "gate.json");
  process.env.VOICELAYER_TEST_INSTALL_PROOF = join(root, "proof.json");
  writeFileSync(process.env.VOICELAYER_TEST_INSTALL_PROOF, JSON.stringify({ phase: "idle", ready: true }));
  writeFileSync(gatePath(), JSON.stringify({ version: 1, kind: "OPEN", generation: 0, released: null }));
  mkdirSync(gatePath() + ".admissions");
  configureRecognizerBusyProbe(() => null); setRecognizerRecovery(null);
  for (const engine of ["parakeet", "whisper"] as const) {
    confirmRecognizerCleanup(engine); noteRecognizerEngine(engine, { phase: "sleeping", available: null, error: null });
  }
  noteRecognizerEffective(null); persistRecognizer("parakeet"); starts = 0; logs = [];
  const child = join(root, "child.mjs");
  writeFileSync(child, `import {createInterface} from 'node:readline';
for await (const line of createInterface({input:process.stdin})) {
 const r=JSON.parse(line); process.stdout.write(JSON.stringify(r.op==='health'?
 {id:r.id,ok:true,ready:true,protocol:1,pid:process.pid}:
 {id:r.id,ok:true,text:'Keep every spoken word.',complete:true,input_frames:16000,covered_frames:16000,sample_rate:16000,last_token_end_s:1,inference_s:0.01,language:null})+'\\n');
}`);
  server = new ParakeetServer({ command: [process.execPath, child], startupMs: 3000, requestMs: 1000, stopMs: 1000,
    idleSeconds: () => 600, unloadWhenIdle: () => true, isBusy: () => false,
    onState: phase => { if (phase === "loading") starts++; } });
  log = spyOn(console, "error").mockImplementation((...args) => { logs.push(args.join(" ")); });
});
afterEach(async () => {
  await server.shutdown(); log.mockRestore();
  for (const key of ["VOICELAYER_STATE_DIR", "VOICELAYER_UPDATE_GATE_PATH", "VOICELAYER_TEST_INSTALL_PROOF", "QA_VOICE_STT_BACKEND"])
    if (saved[key] === undefined) delete process.env[key]; else process.env[key] = saved[key];
});

test("COMMITTED boot warms once after verified COMPLETE without relaunch or dictation", async () => {
  commit(); const pending = boot();
  await tick(); await tick();
  expect(starts).toBe(0); expect(readdirSync(gatePath() + ".admissions")).toEqual([]);
  // Successor/drain proof remains available while the boot task is deferred.
  expect(admission.acknowledgeVoiceDrain(lease(), () => true)).not.toBeNull();
  await complete(); await pending;
  expect(starts).toBe(1);
  expect(logs.some(line => line.includes('"event":"recognizer_boot_warmup"') && line.includes('"outcome":"accept"'))).toBe(true);
  expect(readdirSync(gatePath() + ".admissions")).toEqual([]);
  expect(events()).toContainEqual(expect.objectContaining({ event: "recognizer_boot_warmup_failure", stage: "admission",
    reason: "UPDATE_BUSY", body_entered: false, outcome: "deferred", pid: process.pid, at: expect.any(String) }));
  expect(events()).toContainEqual(expect.objectContaining({ event: "recognizer_boot_warmup_deferred", outcome: "accept", reason: null }));
});

function events() { return logs.filter(line => line.startsWith("[voicelayer] {")).map(line => JSON.parse(line.slice("[voicelayer] ".length))); }
const deferred = () => events().some(event => event.outcome === "deferred");
test("ordinary OPEN boot warms immediately with no deferred diagnostic", async () => {
  await boot(); expect(starts).toBe(1);
  expect(events()).toEqual([expect.objectContaining({ event: "recognizer_boot_warmup", engine: "parakeet", outcome: "accept" })]);
});
test("shutdown before OPEN abandons deferred work without a start", async () => {
  commit(); const owner = new AbortController(), pending = boot(owner.signal);
  await until(deferred); owner.abort(); await pending;
  await complete(); await tick();
  expect(starts).toBe(0); expect(readdirSync(gatePath() + ".admissions")).toEqual([]);
  expect(events()).toContainEqual(expect.objectContaining({ event: "recognizer_boot_warmup_deferred", outcome: "abandoned", reason: "OWNER_SHUTDOWN" }));
});
test("closed gate has a bounded visible abandonment and retains COMMITTED", async () => {
  commit(); await boot(undefined, 30);
  expect(starts).toBe(0); expect(storage.readInstallerGateState().kind).toBe("COMMITTED");
  expect(readdirSync(gatePath() + ".admissions")).toEqual([]);
  expect(events()).toContainEqual(expect.objectContaining({ outcome: "abandoned", reason: "WAIT_TIMEOUT" }));
  await complete(); await tick(); expect(starts).toBe(0);
});
test("next update closing between OPEN observation and admission defers again", async () => {
  commit(); const pending = boot(); await until(deferred);
  const read = storage.readInstallerGateState;
  let raced = false;
  const probe = spyOn(storage, "readInstallerGateState").mockImplementation((env) => {
    const state = read(env);
    if (state.kind === "OPEN" && !raced) { raced = true; commit(2); }
    return state;
  });
  try {
    await complete(); await until(() => raced); await tick();
    expect(starts).toBe(0); expect(readdirSync(gatePath() + ".admissions")).toEqual([]);
    await complete(2); await pending; expect(starts).toBe(1);
  } finally { probe.mockRestore(); await pending; }
});
test("body recheck refuses a new DRAINING update after ordinary admission", async () => {
  commit(); const pending = boot(); await until(deferred);
  const admit = admission.withFreshAsyncVoiceAdmission;
  let raced = false;
  const probe = spyOn(admission, "withFreshAsyncVoiceAdmission").mockImplementation((work, options) => admit(() => {
    if (!raced) { raced = true; expect(admission.updateVoiceGate({ kind: "REQUEST", lease: lease(2) }).kind).toBe("APPLIED"); }
    return work();
  }, options));
  try {
    await complete(); await until(() => raced); await tick();
    expect(starts).toBe(0); expect(readdirSync(gatePath() + ".admissions")).toEqual([]);
    expect(admission.updateVoiceGate({ kind: "CANCEL", lease: lease(2) }).kind).toBe("APPLIED");
    await pending; expect(starts).toBe(1);
  } finally { probe.mockRestore(); await pending; }
});
test("deferred boot resolves the still-selected engine at body start", async () => {
  commit(); const pending = boot(); await until(deferred);
  persistRecognizer("whisper"); await complete(); await pending;
  expect(starts).toBe(0);
  expect(events()).toContainEqual(expect.objectContaining({ event: "recognizer_boot_warmup", engine: "whisper", outcome: "reject" }));
  expect(events()).toContainEqual(expect.objectContaining({ event: "recognizer_boot_warmup_deferred", outcome: "abandoned", reason: "WARMUP_REJECTED" }));
});
test.each(["provider", "cancelled", "admission"])("safe fixed diagnostic and no retry for %s failure", async fault => {
  const { runRecognizerBootWarmup } = await import("../recognizer-boot-warmup");
  let calls = 0;
  const probe = fault === "provider" ? null : spyOn(admission, "withFreshAsyncVoiceAdmission").mockRejectedValue(
    fault === "cancelled" ? new admission.VoiceAdmissionCancelledError() : Error("private provider text /private/path"));
  try {
    await runRecognizerBootWarmup(async () => { calls++; throw Error("private provider text /private/path"); });
    expect(calls).toBe(fault === "provider" ? 1 : 0);
    expect(events()).toEqual([expect.objectContaining({ event: "recognizer_boot_warmup_failure", outcome: "failed",
      stage: fault === "provider" ? "warmup" : "admission", body_entered: fault === "provider",
      reason: fault === "provider" ? "WARMUP_FAILED" : fault === "cancelled" ? "ADMISSION_CANCELLED" : "ADMISSION_FAILED" })]);
    expect(logs.join("\n")).not.toContain("private");
  } finally { probe?.mockRestore(); }
});
test("UNKNOWN readback after a closed boot never authorizes loading", async () => {
  commit(); const pending = boot(undefined, 50); await until(deferred);
  writeFileSync(gatePath() + ".voice-diag.json", "fault evidence");
  await pending; expect(starts).toBe(0);
  expect(events()).toContainEqual(expect.objectContaining({ outcome: "abandoned", reason: "WAIT_TIMEOUT" }));
});
test("missing assets abandon the deferred boot without claiming success", async () => {
  const { runRecognizerBootWarmup } = await import("../recognizer-boot-warmup");
  commit(); const pending = runRecognizerBootWarmup(() => warmSelectedRecognizer({ ...deps(), assetsPresent: () => false }), { pollMs: 5 });
  await until(deferred); await complete(); await pending; expect(starts).toBe(0);
  expect(events()).toContainEqual(expect.objectContaining({ outcome: "abandoned", reason: "ASSETS_UNAVAILABLE" }));
});
test("default production owner signal cancels the deferred boot", async () => {
  const code = `import {runRecognizerBootWarmup} from './src/recognizer-boot-warmup';
import {closeRecognizerOwner} from './src/recognizer-state';
import {updateVoiceGate} from './src/update-gate-admission';
if(process.env.VOICELAYER_TEST_ISOLATED!=='1')throw Error('isolation missing');
const lease=${JSON.stringify(lease())},ack={lease,activeOperations:0,openArchives:0};
for(const command of [{kind:'REQUEST',lease},{kind:'PREPARE',lease,native:ack,daemon:ack},{kind:'COMMIT',lease}])
 if(updateVoiceGate(command,()=>true).kind!=='APPLIED')throw Error('gate setup failed');
let starts=0;const pending=runRecognizerBootWarmup(async()=>{starts++;throw Error('unexpected start');});
await Promise.resolve();closeRecognizerOwner();await pending;console.log(JSON.stringify({isolated:process.env.VOICELAYER_TEST_ISOLATED,starts}));`;
  const child = Bun.spawn([process.execPath, "--preload", join(import.meta.dir, "setup/preload.ts"), "-e", code],
    { cwd: join(import.meta.dir, "../.."), env: process.env, stdout: "pipe", stderr: "pipe" });
  const [stdout, stderr, exit] = await Promise.all([new Response(child.stdout).text(), new Response(child.stderr).text(), child.exited]);
  expect(exit).toBe(0); expect(JSON.parse(stdout)).toEqual({ isolated: "1", starts: 0 });
  expect(stderr).toContain('"reason":"OWNER_SHUTDOWN","outcome":"abandoned"');
});
test.each([false, true])("cold demand after missed boot, provider startup failure=%s", async failed => {
  commit(); await boot(undefined, 20); await complete();
  expect(starts).toBe(0);
  const wav = Buffer.alloc(32044); wav.write("RIFF"); wav.writeUInt32LE(32036, 4); wav.write("WAVEfmt ", 8);
  wav.writeUInt32LE(16, 16); wav.writeUInt16LE(1, 20); wav.writeUInt16LE(1, 22); wav.writeUInt32LE(16000, 24);
  wav.writeUInt32LE(32000, 28); wav.writeUInt16LE(2, 32); wav.writeUInt16LE(16, 34); wav.write("data", 36); wav.writeUInt32LE(32000, 40);
  for (let i = 44; i < wav.length; i += 2) wav.writeInt16LE(1000, i);
  const path = join(root, "input.wav"); writeFileSync(path, wav);
  if (failed) server = new ParakeetServer({ command: [process.execPath, "-e", "process.exit(7)"], startupMs: 1000,
    onState: phase => { if (phase === "loading") starts++; } });
  const p = spyOn(parakeetServer, "transcribe").mockImplementation(path => server.transcribe(path));
  const unload = spyOn(parakeetServer, "unload").mockImplementation(() => server.unload());
  const w = spyOn(stt.WhisperCppBackend.prototype, "transcribe").mockResolvedValue({ text: "Fixture fallback.", backend: "whisper-cpp", durationMs: 1 });
  const ws = spyOn(stt.WhisperServerBackend.prototype, "transcribe").mockRejectedValue(Error("unexpected resident Whisper"));
  try {
    stt.resetBackendCache();
    const result = await admission.withCaptureVoiceAdmission(async () => (await stt.getBackend()).transcribe(path, { language: "en" }));
    expect(starts).toBe(1); expect(ws).not.toHaveBeenCalled();
    expect(w).toHaveBeenCalledTimes(failed ? 1 : 0);
    expect(result.backend).toBe(failed ? "parakeet-resident+fallback-provider-error->whisper-cpp+qualified-fallback" : "parakeet-resident");
    expect(result.text).toBe(failed ? "Fixture fallback." : "Keep every spoken word.");
  } finally { p.mockRestore(); unload.mockRestore(); w.mockRestore(); ws.mockRestore(); stt.resetBackendCache(); }
});
