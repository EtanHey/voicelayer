import { expect, test } from "bun:test";
import { mkdirSync, existsSync, mkdtempSync, readFileSync, symlinkSync, writeFileSync } from "fs";
import { join } from "path";
import { updateGateFilePath } from "../paths";
import { applyUpdateGateCommand, readUpdateGateFile, withUpdateGateLock } from "../update-gate-storage";
import { withChildFixtureEnv } from "./setup/child-env";

const initial = { version: 1, kind: "OPEN", generation: 0, released: null };
const lease = { generation: 1, operationId: "10000000-0000-4000-8000-000000000001",
  ownerId: "20000000-0000-4000-8000-000000000001", targetSha: "a".repeat(40) };
const ack = { lease, activeOperations: 0, openArchives: 0 };
const request = { kind: "REQUEST", lease };
const prepare = { kind: "PREPARE", lease, native: ack, daemon: ack };
const commit = { kind: "COMMIT", lease };
function fixture() {
  const dir = mkdtempSync(join(process.env.VOICELAYER_TEST_RUN_ROOT!, "gate-"));
  const env = { ...process.env, VOICELAYER_UPDATE_GATE_PATH: join(dir, "gate.json") };
  writeFileSync(env.VOICELAYER_UPDATE_GATE_PATH, JSON.stringify(initial));
  mkdirSync(env.VOICELAYER_UPDATE_GATE_PATH + ".admissions");
  return env;
}

test("missing, malformed and contradictory disk state stays UNKNOWN; transactions cannot initialize it", () => {
  const env = fixture();
  for (const value of ["{", JSON.stringify({ ...initial, version: 2 }), JSON.stringify({ ...initial, generation: 9 })]) {
    writeFileSync(env.VOICELAYER_UPDATE_GATE_PATH, value);
    expect(readUpdateGateFile(env)).toEqual({ kind: "UNKNOWN" });
    expect(applyUpdateGateCommand(request, env)).toEqual({ kind: "REFUSED", reason: "UNKNOWN" });
    expect(readFileSync(env.VOICELAYER_UPDATE_GATE_PATH, "utf8")).toBe(value);
  }
  env.VOICELAYER_UPDATE_GATE_PATH += "-missing";
  expect(readUpdateGateFile(env)).toEqual({ kind: "UNKNOWN" });
  expect(applyUpdateGateCommand(request, env)).toEqual({ kind: "REFUSED", reason: "UNKNOWN" });
  expect(existsSync(env.VOICELAYER_UPDATE_GATE_PATH)).toBe(false);
});

test("durable duplicate request/commit replay after restart never applies twice", () => {
  const env = fixture();
  for (const command of [request, prepare, commit]) {
    const applied = applyUpdateGateCommand(command, env, () => true);
    expect(applied.kind).toBe("APPLIED");
    const disk = JSON.parse(readFileSync(env.VOICELAYER_UPDATE_GATE_PATH, "utf8"));
    expect(applyUpdateGateCommand(command, env)).toEqual({ kind: "UNCHANGED", state: disk });
  }
  expect(readUpdateGateFile(env).kind).toBe("COMMITTED");
  expect(applyUpdateGateCommand({ kind: "CANCEL", lease }, env).kind).toBe("REFUSED");
  const child = withChildFixtureEnv(env, () => Bun.spawnSync([process.execPath, "-e", `
    import { applyUpdateGateCommand } from ${JSON.stringify(join(import.meta.dir, "..", "update-gate-storage.ts"))};
    console.log(applyUpdateGateCommand(${JSON.stringify(commit)}).kind);
  `], { env: process.env, stdout: "pipe", stderr: "pipe" }));
  expect(child.exitCode).toBe(0);
  expect(new TextDecoder().decode(child.stdout).trim()).toBe("UNCHANGED");
});

test("persisted preparation is insufficient: COMMIT needs current verification inside the lock", () => {
  const env = fixture();
  applyUpdateGateCommand(request, env);
  applyUpdateGateCommand(prepare, env, () => true);
  for (const verify of [undefined, () => false]) {
    expect(applyUpdateGateCommand(commit, env, verify)).toEqual({ kind: "REFUSED", reason: "UNKNOWN" });
  }
  expect(applyUpdateGateCommand(commit, env, () => {
    expect(readUpdateGateFile(env)).toEqual({ kind: "UNKNOWN" });
    return true; // Synthetic participant/target evidence; G2 supplies live probes.
  }).kind).toBe("APPLIED");
});

test("persistence failure retains the lock and the previous closed generation", () => {
  const env = fixture();
  applyUpdateGateCommand(request, env);
  applyUpdateGateCommand(prepare, env, () => true);
  expect(() => applyUpdateGateCommand(commit, env, () => {
    writeFileSync(join(env.VOICELAYER_UPDATE_GATE_PATH + ".lock", "state.json"), "collision");
    return true;
  })).toThrow();
  expect(readUpdateGateFile(env)).toEqual({ kind: "UNKNOWN" });
  expect(() => applyUpdateGateCommand(commit, env)).toThrow("LOCKED");
  expect(JSON.parse(readFileSync(env.VOICELAYER_UPDATE_GATE_PATH, "utf8")).kind).toBe("PREPARED");
});

test("obsolete owner cannot reopen or commit the next persisted generation", () => {
  const env = fixture();
  applyUpdateGateCommand(request, env);
  applyUpdateGateCommand({ kind: "CANCEL", lease }, env);
  const newer = { ...lease, generation: 2, ownerId: "20000000-0000-4000-8000-000000000002" };
  expect(applyUpdateGateCommand({ ...request, lease: newer }, env).kind).toBe("APPLIED");
  for (const command of [request, prepare, commit, { kind: "CANCEL", lease }]) {
    expect(applyUpdateGateCommand(command, env).kind).toBe("REFUSED");
  }
  expect(readUpdateGateFile(env)).toEqual({ version: 1, kind: "DRAINING", lease: newer });
});

test("preload redirects the gate; missing, blank, escaping and symlink paths fail closed", () => {
  expect(updateGateFilePath()).toStartWith(process.env.VOICELAYER_TEST_RUN_ROOT! + "/");
  for (const value of [undefined, " "]) expect(() => updateGateFilePath({ ...process.env,
    VOICELAYER_UPDATE_GATE_PATH: value })).toThrow("requires VOICELAYER_UPDATE_GATE_PATH");
  const env = fixture();
  const link = join(env.VOICELAYER_UPDATE_GATE_PATH, "..", "link");
  symlinkSync(join(env.VOICELAYER_UPDATE_GATE_PATH, ".."), link);
  for (const path of [join(process.env.VOICELAYER_TEST_RUN_ROOT!, "..", "escaped.json"), join(link, "gate.json")]) {
    expect(() => withUpdateGateLock(() => {}, { ...env, VOICELAYER_UPDATE_GATE_PATH: path })).toThrow();
  }
  const child = Bun.spawnSync([process.execPath, "-e", "console.log(process.env.VOICELAYER_UPDATE_GATE_PATH)"], {
    env: { ...process.env, VOICELAYER_UPDATE_GATE_PATH: "ignored-child-override" }, stdout: "pipe", stderr: "pipe",
  });
  expect(child.exitCode).toBe(0);
  expect(new TextDecoder().decode(child.stdout).trim()).toBe(updateGateFilePath());
});

test("orphaned lock and callback failure never age into permission; observations under lock are UNKNOWN", () => {
  const env = fixture();
  withUpdateGateLock(() => expect(readUpdateGateFile(env)).toEqual({ kind: "UNKNOWN" }), env);
  expect(existsSync(env.VOICELAYER_UPDATE_GATE_PATH + ".lock")).toBe(false);
  expect(() => withUpdateGateLock(() => { throw new Error("interrupted"); }, env)).toThrow("interrupted");
  expect(() => applyUpdateGateCommand(request, env)).toThrow("LOCKED");
  expect(readFileSync(env.VOICELAYER_UPDATE_GATE_PATH, "utf8")).toBe(JSON.stringify(initial));
});

test("async critical sections fail closed and retain their lock", () => {
  const env = fixture();
  expect(() => withUpdateGateLock(async () => {}, env)).toThrow("ASYNC");
  expect(() => applyUpdateGateCommand(request, env)).toThrow("LOCKED");
});

test("every existing lock entry, including a dangling symlink, refuses observation and acquisition", () => {
  for (const kind of ["file", "dangling-link"]) {
    const env = fixture();
    const lock = env.VOICELAYER_UPDATE_GATE_PATH + ".lock";
    if (kind === "file") writeFileSync(lock, "not a lock directory");
    else symlinkSync(env.VOICELAYER_UPDATE_GATE_PATH + "-absent", lock);
    expect(readUpdateGateFile(env)).toEqual({ kind: "UNKNOWN" });
    expect(() => applyUpdateGateCommand(request, env)).toThrow("LOCKED");
  }
});

test("two Bun processes race the same lock and generation: exactly one commits", async () => {
  const env = fixture();
  const source = `import { writeFileSync } from 'fs';
    import { withUpdateGateLock } from ${JSON.stringify(join(import.meta.dir, "..", "update-gate-storage.ts"))};
    import { transitionUpdateGate } from ${JSON.stringify(join(import.meta.dir, "..", "update-gate.ts"))};
    import { readFileSync } from 'fs';
    writeFileSync(process.env.VOICELAYER_UPDATE_GATE_PATH + '.' + process.argv.at(-1), 'ready');
    await Bun.stdin.text();
    try { withUpdateGateLock(path => {
      Bun.sleepSync(150);
      let s = JSON.parse(readFileSync(path, 'utf8'));
      const lease = ${JSON.stringify(lease)}; lease.ownerId = process.argv.at(-1);
      const ack = { lease, activeOperations:0, openArchives:0 };
      for (const command of [{kind:'REQUEST',lease}, {kind:'PREPARE',lease,native:ack,daemon:ack}, {kind:'COMMIT',lease}]) {
        const r = transitionUpdateGate(s, command); if (r.kind !== 'APPLIED') throw Error('refused'); s = r.state;
      }
      writeFileSync(path, JSON.stringify(s));
    }); console.log('COMMITTED'); } catch(e) { console.log('REFUSED'); }`;
  const ids = [lease.ownerId, "20000000-0000-4000-8000-000000000002"];
  const children = withChildFixtureEnv(env, () => ids.map(id => Bun.spawn([process.execPath, "-e", source, id], {
    env: process.env, stdin: "pipe", stdout: "pipe", stderr: "pipe",
  })));
  try {
    const deadline = Date.now() + 3000;
    while (!ids.every(id => existsSync(env.VOICELAYER_UPDATE_GATE_PATH + "." + id))) {
      if (Date.now() > deadline) throw new Error("racers did not reach barrier");
      await Bun.sleep(5);
    }
    children.forEach(child => child.stdin.end("go"));
    const outputs = await Promise.all(children.map(async child => {
      const output = await new Response(child.stdout).text();
      expect(await child.exited).toBe(0);
      expect(await new Response(child.stderr).text()).toBe("");
      return output.trim();
    }));
    expect(outputs.sort()).toEqual(["COMMITTED", "REFUSED"]);
    // The loser must not release the winner's critical section or overwrite it.
    expect(JSON.parse(readFileSync(env.VOICELAYER_UPDATE_GATE_PATH, "utf8")).kind).toBe("COMMITTED");
  } finally { children.forEach(child => child.kill()); }
}, 5000);
