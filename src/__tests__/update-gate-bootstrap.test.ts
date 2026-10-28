import { afterEach, expect, test } from "bun:test";
import { Database } from "bun:sqlite";
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, statSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { bootstrapUpdateGate, readTrustedUpdateGate } from "../update-gate-bootstrap";
import { readUpdateGate, transitionUpdateGate } from "../update-gate";
import { TEST_TMP, testSocket } from "./setup/test-tmp";
import { withChildFixtureEnv } from "./setup/child-env";

const roots: string[] = [];
const children: ReturnType<typeof Bun.spawn>[] = [];
afterEach(async () => {
  for (const child of children.splice(0)) { child.kill("SIGKILL"); await child.exited; }
  for (const root of roots.splice(0)) rmSync(root, { recursive: true, force: true });
});
function fixture() {
  const root = mkdtempSync(join(TEST_TMP, "bootstrap-"));
  roots.push(root);
  return join(root, "update-admission.sqlite");
}
function state(path: string) {
  const db = new Database(path);
  try { return db.transaction(() => readTrustedUpdateGate(db)).immediate(); }
  finally { db.close(); }
}
const modulePath = join(import.meta.dir, "..", "update-gate-bootstrap.ts");
function contender(path: string, hold = false, useDefault = false) {
  const script = `import {bootstrapUpdateGate} from ${JSON.stringify(modulePath)};
    console.log(JSON.stringify(bootstrapUpdateGate(${useDefault ? "" : JSON.stringify(path)})));
    ${hold ? "setInterval(() => {}, 1000);" : ""}`;
  const env = { ...process.env, VOICELAYER_STATE_DIR: join(path, "..") };
  const child = withChildFixtureEnv(env, () => Bun.spawn([process.execPath, "-e", script], {
    env, stdout: "pipe", stderr: "pipe",
  }));
  children.push(child);
  return child;
}

test("fresh production bootstrap satisfies slice-2 OPEN-only refusal with only the s1 schema", () => {
  const path = fixture();
  expect(readUpdateGate(undefined).kind === "OPEN").toBe(false);
  expect(bootstrapUpdateGate(path).kind).toBe("READY");
  expect(readUpdateGate(state(path))).toEqual({ version: 1, kind: "OPEN", generation: 0, released: null });
  expect(readUpdateGate(state(path)).kind === "OPEN").toBe(true);
  const db = new Database(path);
  db.transaction(() => {
    const gate = readUpdateGate(readTrustedUpdateGate(db));
    if (gate.kind !== "OPEN") throw new Error(`Voice operation refused: update gate ${gate.kind}`);
    db.query("INSERT INTO admissions VALUES (?, ?)").run(crypto.randomUUID(), process.pid);
  }).immediate();
  expect(db.query<{ count: number }, []>("SELECT count(*) AS count FROM admissions").get()?.count).toBe(1);
  db.close();
  expect(bootstrapUpdateGate(path).kind).toBe("REFUSED");
});

test("default production path uses the isolated preload state directory", async () => {
  const path = fixture();
  const child = contender(path, true, true);
  const reader = new Response(child.stdout).body!.getReader();
  try {
    const line = await reader.read();
    expect(JSON.parse(new TextDecoder().decode(line.value)).kind).toBe("READY");
    expect(state(path).kind).toBe("OPEN");
  } finally { reader.releaseLock(); }
});

test.each(["DRAINING", "PREPARED", "COMMITTED"])("crashed %s stays closed with recovery instructions", async phase => {
  const path = fixture();
  const child = contender(path);
  expect(await child.exited).toBe(0);
  const lease = { generation: 1, operationId: crypto.randomUUID(), ownerId: crypto.randomUUID(), targetSha: "a".repeat(40) };
  const ack = { lease, activeOperations: 0, openArchives: 0 };
  let current: unknown = { version: 1, kind: "OPEN", generation: 0, released: null };
  for (const command of [{ kind: "REQUEST", lease }, { kind: "PREPARE", lease, native: ack, daemon: ack }, { kind: "COMMIT", lease }]) {
    const result = transitionUpdateGate(current, command);
    if (result.kind === "REFUSED") throw new Error(result.reason);
    current = result.state;
    if (result.state.kind === phase) break;
  }
  const db = new Database(path);
  db.query("UPDATE gate SET state=? WHERE id=1").run(JSON.stringify(current));
  db.close();
  const before = readFileSync(path);
  expect(bootstrapUpdateGate(path)).toMatchObject({ kind: "REFUSED", reason: expect.stringContaining("recovery") });
  expect(state(path).kind).toBe(phase);
  expect(readFileSync(path)).toEqual(before);
});

test.each(["broken", "partial header", "unreadable", "malformed state", "missing owner"])("%s stays UNKNOWN", kind => {
  const path = fixture();
  if (kind === "unreadable") {
    rmSync(join(path, ".."), { recursive: true });
    writeFileSync(join(path, ".."), "not a directory");
  } else if (kind === "broken" || kind === "partial header") writeFileSync(path, kind === "partial header" ? "SQLite format 3" : "not sqlite");
  else {
    bootstrapUpdateGate(path);
    const db = new Database(path);
    db.exec(kind === "missing owner" ? "DELETE FROM gate_owner" : "UPDATE gate SET state='{}'");
    db.close();
  }
  expect(bootstrapUpdateGate(path)).toMatchObject({ kind: "REFUSED", reason: expect.stringContaining("UNKNOWN") });
});

test.each(["create", "close", "rename"])("crash after %s publishes no partial gate and restart opens", async boundary => {
  const path = fixture();
  const script = `import * as fs from "node:fs"; import {mock} from "bun:test";
    const originalOpen = fs.openSync, originalClose = fs.closeSync, originalRename = fs.renameSync;
    let created;
    mock.module("node:fs", () => ({...fs,
      openSync: (...args) => { const fd = originalOpen(...args); if (args[1] === "wx") { created = fd; if (${JSON.stringify(boundary)} === "create") process.kill(process.pid, "SIGKILL"); } return fd; },
      closeSync: fd => { originalClose(fd); if (${JSON.stringify(boundary)} === "close" && fd === created) process.kill(process.pid, "SIGKILL"); },
      renameSync: (...args) => { originalRename(...args); process.kill(process.pid, "SIGKILL"); },
    }));
    const {bootstrapUpdateGate} = await import(${JSON.stringify(modulePath)});
    bootstrapUpdateGate(${JSON.stringify(path)});`;
  const child = Bun.spawn([process.execPath, "-e", script], { env: process.env, stdout: "pipe", stderr: "pipe" });
  children.push(child);
  await child.exited;
  expect(child.signalCode).toBe("SIGKILL");
  if (existsSync(path)) expect(statSync(path).size).toBeGreaterThan(0);
  expect(bootstrapUpdateGate(path).kind).toBe("READY");
  expect(state(path).kind).toBe("OPEN");
  expect(statSync(path).mode & 0o777).toBe(0o600);
});

test("legacy empty create recovers but an empty file with a recovery journal refuses", () => {
  const path = fixture();
  writeFileSync(path, "");
  writeFileSync(`${path}-journal`, "unfinished transaction");
  expect(bootstrapUpdateGate(path).kind).toBe("REFUSED");
  expect(readFileSync(`${path}-journal`, "utf8")).toBe("unfinished transaction");
  rmSync(`${path}-journal`);
  expect(bootstrapUpdateGate(path).kind).toBe("READY");
  expect(state(path).kind).toBe("OPEN");
});

test("concurrent recovery of an incomplete create has only one live owner", async () => {
  const path = fixture();
  writeFileSync(path, "");
  const reports = await Promise.all([contender(path, true), contender(path, true)].map(async child => {
    const reader = new Response(child.stdout).body!.getReader();
    try { return JSON.parse(new TextDecoder().decode((await reader.read()).value)); }
    finally { reader.releaseLock(); }
  }));
  expect(reports.filter(report => report.kind === "READY")).toHaveLength(1);
  expect(reports.filter(report => report.kind === "REFUSED")).toHaveLength(1);
  expect(state(path).kind).toBe("OPEN");
});

test.each(["fresh", "corrupt", "non-file", "unwritable"])("real daemon serves ping with %s gate and reports refusal after listening", async kind => {
  const path = fixture();
  if (kind === "corrupt") writeFileSync(path, "not sqlite");
  if (kind === "non-file") mkdirSync(path);
  if (kind === "unwritable") { writeFileSync(path, ""); chmodSync(path, 0); }
  const root = join(path, "..");
  const socketPath = testSocket(`bg-${kind}.sock`);
  const env = { ...process.env, VOICELAYER_STATE_DIR: root, VOICELAYER_TMP_ROOT: join(root, "tmp"),
    VOICELAYER_CONTROL_LAYER_BASE: join(root, "orc"), QA_VOICE_RECORDINGS_DIR: join(root, "archive"),
    VOICELAYER_MCP_SOCKET_PATH: socketPath, VOICELAYER_ALLOW_ORPHAN_DAEMON: "1", QA_VOICE_STT_BACKEND: "whisper" };
  const child = withChildFixtureEnv(env, () => Bun.spawn([process.execPath, "--preload", join(import.meta.dir, "setup/preload.ts"),
    join(import.meta.dir, "../mcp-server-daemon.ts")], { env, stdout: "ignore", stderr: "pipe" }));
  children.push(child);
  let logs = "";
  for await (const chunk of child.stderr) {
    logs += new TextDecoder().decode(chunk);
    if (logs.includes("MCP daemon listening") && (kind === "fresh" || logs.includes("recovery required"))) break;
  }
  expect(logs).toContain("MCP daemon listening");
  if (kind !== "fresh") {
    expect(logs).toContain("UNKNOWN");
    expect(logs.indexOf("MCP daemon listening")).toBeLessThan(logs.indexOf("recovery required"));
    if (kind === "corrupt") expect(readFileSync(path, "utf8")).toBe("not sqlite");
  }
  const reply = await new Promise<string>((resolve, reject) => {
    Bun.connect({ unix: socketPath, socket: {
      open(socket) { socket.write('{"type":"ping"}\n'); },
      data(socket, data) { resolve(data.toString()); socket.end(); }, error(_socket, error) { reject(error); },
    } }).catch(reject);
  });
  expect(JSON.parse(reply).type).toBe("pong");
  expect(child.exitCode).toBeNull();
  if (kind === "fresh") expect(state(path).kind).toBe("OPEN");
}, 20_000);

test("a dead generation is UNKNOWN until a new daemon fences it; old generation cannot be trusted", async () => {
  const path = fixture();
  const child = contender(path);
  expect(await child.exited).toBe(0);
  const previous = JSON.parse(await new Response(child.stdout).text());
  expect(previous.kind).toBe("READY");
  expect(state(path).kind).toBe("UNKNOWN");
  const next = bootstrapUpdateGate(path);
  expect(next.kind).toBe("READY");
  if (next.kind !== "READY") throw new Error(next.reason);
  expect(next.daemonId).not.toBe(previous.daemonId);
  const db = new Database(path);
  expect(readTrustedUpdateGate(db, previous.daemonId).kind).toBe("UNKNOWN");
  db.close();
  expect(state(path).kind).toBe("OPEN");
});

test("simultaneous live daemon generations cannot both claim the gate", async () => {
  const path = fixture();
  const contenders = [contender(path, true), contender(path, true)];
  const reports = await Promise.all(contenders.map(async child => {
    for await (const line of new Response(child.stdout).body!.pipeThrough(new TextDecoderStream())) {
      return JSON.parse(line);
    }
    throw new Error("missing bootstrap result");
  }));
  expect(reports.filter(report => report.kind === "READY")).toHaveLength(1);
  expect(reports.filter(report => report.kind === "REFUSED")).toHaveLength(1);
  expect(state(path).kind).toBe("OPEN");
});

test("a reused PID cannot authorize its older kernel generation", () => {
  const path = fixture();
  bootstrapUpdateGate(path);
  const db = new Database(path);
  const row = db.query<{ owner: string }, []>("SELECT owner FROM gate_owner").get()!;
  const owner = JSON.parse(row.owner);
  db.query("UPDATE gate_owner SET owner=?").run(JSON.stringify({ ...owner, startUs: owner.startUs - 1 }));
  expect(readTrustedUpdateGate(db).kind).toBe("UNKNOWN");
  db.close();
  expect(bootstrapUpdateGate(path).kind).toBe("READY");
});

test("restart cannot clear unresolved admissions or overwrite their evidence", async () => {
  const path = fixture();
  const child = contender(path);
  expect(await child.exited).toBe(0);
  const db = new Database(path);
  db.query("INSERT INTO admissions VALUES (?, ?)").run("unfinished", child.pid);
  db.close();
  const before = readFileSync(path);
  expect(bootstrapUpdateGate(path)).toMatchObject({ kind: "REFUSED", reason: expect.stringContaining("unresolved") });
  expect(readFileSync(path)).toEqual(before);
  expect(state(path).kind).toBe("UNKNOWN");
});
