import { test, expect } from "bun:test";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { withVoiceAdmission } from "../update-gate-admission";
import { readInstallerGateState } from "../update-gate-storage";
import type { InstallerParticipant } from "../update-gate-installer-participant";
import type { UpdateGateLease } from "../update-gate";

const installerPath = fileURLToPath(new URL("../update-gate-installer.ts", import.meta.url));
const storagePath = fileURLToPath(new URL("../update-gate-storage.ts", import.meta.url));
type Mode = "collision" | "malformed" | "diagnostic";
type Event = { event: string; kind?: string; error?: string; gate?: string; lock?: boolean; value?: boolean };

// This creates an instrumented *copy*, never rewrites the loaded production module
// or its shared dependencies. Actual ACK, G1, state parsing and retry functions run.
function instrument(source: string, key: string): string {
  const anchors = 'resolve(import.meta.dir, "../.test-tmp")';
  expect(source.split(anchors)).toHaveLength(3);
  const original = source.replaceAll(anchors, JSON.stringify(resolve(process.cwd(), ".test-tmp")))
    .replace(/from "(\.\/[^"\n]+)"/g, (_, path: string) => `from ${JSON.stringify(resolve(dirname(installerPath), path))}`)
    .replace('import("./update-gate-bootstrap")', `import(${JSON.stringify(resolve(dirname(installerPath), "update-gate-bootstrap"))})`)
    .replace("acknowledgeVoiceDrain, updateVoiceGate", "acknowledgeVoiceDrain as originalAck, updateVoiceGate")
    .replace("readInstallerGateState, readUpdateGateFile }", "readInstallerGateState as originalAtomic, readUpdateGateFile as originalObserve }")
    .replace("installerGateContended as contended", "installerGateContended as originalContended");
  const probeImport = source.includes("installerGateContended as contended") ? ""
    : `import { installerGateContended as originalContended } from ${JSON.stringify(resolve(dirname(storagePath), "update-gate-installer-participant"))};\n`;
  return original + probeImport + `
import { existsSync as testExists } from "node:fs";
const d = (globalThis as unknown as Record<string, {
  mode: string; armed: boolean; injected: boolean; request: string; ready: string; release: string;
  events: Array<{event: string; kind?: string; error?: string; gate?: string; lock?: boolean; value?: boolean}>;
}>)[${JSON.stringify(key)}]!;
function acknowledgeVoiceDrain(...args: Parameters<typeof originalAck>) {
  const ack = originalAck(...args);
  if (!ack && !d.injected) { d.armed = true; d.events.push({event: "actual-null-ack"}); }
  return ack;
}
function injectAfterNegativeProbe(value: boolean) {
  if (!d.armed || d.injected) return;
  d.events.push({event: "actual-negative-probe", value});
  if (value) throw Error("fixture requires uncontended probe");
  d.injected = true;
  if (d.mode === "collision") {
    writeFileSync(d.request, "acquire");
    const deadline = performance.now() + 2000;
    while (!testExists(d.ready)) {
      if (performance.now() > deadline) throw Error("holder acquisition timeout");
      Bun.sleepSync(1);
    }
    d.events.push({event: "holder-acquired", lock: testExists(updateGateFilePath()+".lock"),
      gate: JSON.parse(readFileSync(updateGateFilePath(), "utf8")).kind});
  } else if (d.mode === "malformed") writeFileSync(updateGateFilePath(), "{}");
  else writeFileSync(updateGateFilePath()+".voice-diag.json", "diagnostic retained");
}
// Old branch probes first; the fixed branch calls atomic directly. Both inject
// only AFTER the actual negative probe, before their actual storage operation.
function contended() {
  const value = originalContended(); injectAfterNegativeProbe(value); return value;
}
function readUpdateGateFile(...args: Parameters<typeof originalObserve>) {
  const value = originalObserve(...args);
  if (d.armed) {
    d.events.push({event: "observation", kind: value.kind,
      gate: d.mode === "malformed" ? "MALFORMED" : JSON.parse(readFileSync(updateGateFilePath(), "utf8")).kind});
    d.armed = false;
    if (d.mode === "collision") writeFileSync(d.release, "release");
  }
  return value;
}
function readInstallerGateState(...args: Parameters<typeof originalAtomic>) {
  if (d.armed && !d.injected) injectAfterNegativeProbe(originalContended());
  try {
    const value = originalAtomic(...args);
    if (d.armed) { d.events.push({event: "atomic-read", kind: value.kind}); d.armed = false; }
    return value;
  } catch (error) {
    if (d.armed) {
      d.events.push({event: "atomic-acquisition-failed", error: String(error)});
      if (d.mode === "collision") writeFileSync(d.release, "release");
    }
    throw error;
  }
}
`;
}

async function scenario(mode: Mode) {
  if (process.env.VOICELAYER_TEST_ISOLATED !== "1" || !process.env.VOICELAYER_TEST_RUN_ROOT)
    throw Error("mandatory normal preload missing");
  const saved = { ...process.env };
  const root = mkdtempSync(join(process.env.VOICELAYER_TEST_RUN_ROOT, "drain-"));
  const gate = join(root, "gate"), marker = join(root, "INSTALLER_RAN"), proof = join(root, "proof");
  const d = { mode, armed: false, injected: false, request: join(root, "request"), ready: join(root, "ready"),
    release: join(root, "release"), events: [] as Event[] };
  const key = `drain-readback:${root}`;
  (globalThis as unknown as Record<string, typeof d>)[key] = d;
  writeFileSync(gate, JSON.stringify({ version: 1, kind: "OPEN", generation: 0, released: null }));
  mkdirSync(gate + ".admissions");
  writeFileSync(proof, JSON.stringify({ phase: "idle", ready: true }));
  Object.assign(process.env, { VOICELAYER_UPDATE_GATE_PATH: gate, VOICELAYER_TEST_INSTALL_PROOF: proof,
    VOICELAYER_UPDATE_TARGET_SHA: "a".repeat(40), VOICELAYER_INSTALL_OPERATION: "", VOICELAYER_SUPERVISED_BOOTSTRAP: "" });
  let finish!: () => void;
  const work = withVoiceAdmission(() => new Promise<void>(done => { finish = done; }));
  const holderSource = `import {existsSync,writeFileSync} from "node:fs";
    import {withUpdateGateLock} from ${JSON.stringify(storagePath)};
    const deadline=performance.now()+2000;
    while(!existsSync(${JSON.stringify(d.request)})) {
      if(performance.now()>deadline)throw Error("holder request timeout");await Bun.sleep(1);
    }
    withUpdateGateLock(()=>{
      writeFileSync(${JSON.stringify(d.ready)},JSON.stringify({pid:process.pid}));
      const deadline=performance.now()+2000;
      while(!existsSync(${JSON.stringify(d.release)})) {
        if(performance.now()>deadline)throw Error("holder release timeout");Bun.sleepSync(1);
      }
    });`;
  const holder = mode === "collision" ? Bun.spawn([process.execPath, "-e", holderSource],
    { env: process.env, stdout: "pipe", stderr: "pipe" }) : undefined;
  const holderOut = holder ? new Response(holder.stdout).text() : Promise.resolve("");
  const holderErr = holder ? new Response(holder.stderr).text() : Promise.resolve("");
  const messages: string[] = [], originalError = console.error;
  console.error = (...args: unknown[]) => { messages.push(args.map(String).join(" ")); originalError(...args); };
  let error: unknown, result: number | undefined, refreshes = 0, quits = 0;
  let lease: UpdateGateLease | undefined;
  const participant: InstallerParticipant = {
    async refresh(current) {
      lease = current; refreshes++;
      if (refreshes === 2) { finish(); await work; }
      const ack = { lease: current, activeOperations: 0 as const, openArchives: 0 as const };
      return { phase: "idle", ready: true, native: ack, daemon: ack };
    },
    verify: () => true,
    async quit(current) {
      const held = readInstallerGateState();
      expect(held.kind).toBe("COMMITTED");
      if (held.kind !== "COMMITTED") throw Error("quit before COMMIT");
      expect(held.lease).toEqual(current);
      expect(readdirSync(gate + ".admissions")).toHaveLength(0);
      expect(existsSync(marker)).toBe(false); quits++;
    },
  };
  try {
    const copy = join(root, "installer-copy.ts");
    writeFileSync(copy, instrument(readFileSync(installerPath, "utf8"), key));
    const { runGatedInstall } = await import(copy);
    // The only installer command is a harmless write in this fixture. It checks
    // durable authorization itself; no real installer, CLI shell or live RPC runs.
    const command = `import {readFileSync,writeFileSync} from "node:fs";
      const gate=JSON.parse(readFileSync(process.env.VOICELAYER_UPDATE_GATE_PATH,"utf8"));
      const owner=JSON.parse(process.env.VOICELAYER_INSTALL_OPERATION);
      if(gate.kind!=="COMMITTED" || JSON.stringify(gate.lease)!==JSON.stringify(owner.lease))process.exit(72);
      writeFileSync(${JSON.stringify(marker)},"authorized");`;
    try { result = await runGatedInstall([process.execPath, "-e", command], participant); }
    catch (caught) { error = caught; }
    if (holder) { expect(await holder.exited).toBe(0); expect(await holderOut).toBe(""); expect(await holderErr).toBe(""); }
    expect(d.injected).toBe(true);
    expect(d.events.find(e => e.event === "actual-null-ack")).toBeDefined();
    expect(d.events.find(e => e.event === "actual-negative-probe")?.value).toBe(false);
    if (mode === "collision") {
      expect(d.events.find(e => e.event === "holder-acquired")).toMatchObject({ lock: true, gate: "DRAINING" });
      // Both outcome and the failed real mkdir are required: green cannot skip.
      expect(String(error)).toBe("undefined");
      expect(result).toBe(0);
      expect(d.events.filter(e => e.event === "atomic-acquisition-failed").length).toBeGreaterThan(0);
      expect(d.events.filter(e => e.event === "atomic-acquisition-failed").every(e => e.error === "Error: UPDATE_GATE_LOCKED")).toBe(true);
      expect(d.events.find(e => e.event === "atomic-read")?.kind).toBe("DRAINING");
      expect(messages.some(m => m.includes("Waiting for update-gate lock"))).toBe(true);
      expect(refreshes).toBe(4); expect(quits).toBe(1);
      expect(readFileSync(marker, "utf8")).toBe("authorized");
      expect(JSON.parse(readFileSync(gate, "utf8"))).toMatchObject({ kind: "COMMITTED", lease });
    } else {
      expect(String(error)).toContain("RECOVERY_REQUIRED: Cancel could not restore admission");
      expect(result).toBeUndefined(); expect(refreshes).toBe(1); expect(quits).toBe(0);
      expect(existsSync(marker)).toBe(false);
      const reads = d.events.filter(e => e.event === "observation" || e.event === "atomic-read");
      expect(reads).toHaveLength(1); expect(reads[0]?.kind).toBe("UNKNOWN");
      expect(d.events.filter(e => e.event === "atomic-acquisition-failed")).toHaveLength(0);
      expect(messages.some(m => m.includes("Waiting for update-gate lock"))).toBe(false);
      expect(existsSync(gate + ".controller")).toBe(false);
      if (mode === "malformed") expect(readFileSync(gate, "utf8")).toBe("{}");
      else {
        expect(readFileSync(gate + ".voice-diag.json", "utf8")).toBe("diagnostic retained");
        expect(JSON.parse(readFileSync(gate, "utf8"))).toMatchObject({ kind: "DRAINING", lease });
      }
      expect(readdirSync(gate + ".admissions")).toHaveLength(1);
    }
  } finally {
    writeFileSync(d.release, "release"); finish(); await work;
    if (holder && holder.exitCode === null) { holder.kill(); await holder.exited; }
    console.error = originalError;
    expect(readdirSync(gate + ".admissions")).toHaveLength(0);
    // Emit neutral fixture facts even on red. No transcript or private input.
    console.log(JSON.stringify({ mode, root, result, error: String(error), refreshes, quits,
      events: d.events, messages, holderExit: holder?.exitCode, holderStderr: await holderErr,
      installerRan: existsSync(marker), gate: readFileSync(gate, "utf8"), ledger: readdirSync(gate + ".admissions") }));
    delete (globalThis as unknown as Record<string, unknown>)[key];
    for (const key of Object.keys(process.env)) if (!(key in saved)) delete process.env[key];
    Object.assign(process.env, saved);
  }
}

for (const mode of ["collision", "malformed", "diagnostic"] as const)
  test(`drain readback: ${mode}`, () => scenario(mode), 30_000);
