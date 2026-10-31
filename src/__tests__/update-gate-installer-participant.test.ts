import { afterEach, expect, test } from "bun:test";
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, existsSync } from "node:fs";
import { join } from "node:path";
import { createInstallerParticipant, requestInstallerControl, type InstallerParticipantDependencies } from "../update-gate-installer-participant";
import { updateVoiceGate } from "../update-gate-admission";
import { type UpdateGateLease } from "../update-gate";
import { createServer } from "node:net";

const originalGate = process.env.VOICELAYER_UPDATE_GATE_PATH;
afterEach(() => { process.env.VOICELAYER_UPDATE_GATE_PATH = originalGate; });
function fixture() {
  const root = mkdtempSync(join(process.env.VOICELAYER_TEST_RUN_ROOT!, "ip-")), gate = join(root, "g");
  process.env.VOICELAYER_UPDATE_GATE_PATH = gate;
  mkdirSync(gate + ".admissions");
  writeFileSync(gate, JSON.stringify({ version: 1, kind: "OPEN", generation: 0, released: null }));
  const lease: UpdateGateLease = { generation: 1, operationId: crypto.randomUUID(), ownerId: crypto.randomUUID(), targetSha: "a".repeat(40) };
  const identities = { native: { pid: 101, incarnation: crypto.randomUUID() }, daemon: { pid: 102, incarnation: crypto.randomUUID() } };
  const ack = { lease, activeOperations: 0, openArchives: 0 };
  let reply: unknown = { kind: "ACKNOWLEDGED", native: ack, daemon: ack, identities };
  let exited = false, exitUnknown = false, now = 0;
  const calls: string[] = [];
  const deps: InstallerParticipantDependencies = {
    request: async (action, value) => { calls.push(action); expect(value).toEqual(lease); return reply; },
    processIdentity: pid => exited ? null : `birth-and-command-${pid}`,
    participantsExited: () => exitUnknown ? "UNKNOWN" : exited,
    now: () => now,
    sleep: async () => { now += 100; },
  };
  expect(updateVoiceGate({ kind: "REQUEST", lease }).kind).toBe("APPLIED");
  const participant = createInstallerParticipant(deps);
  const commit = async () => {
    const proof = await participant.refresh(lease);
    expect(proof.ready).toBe(true);
    expect(updateVoiceGate({ kind: "PREPARE", lease, native: proof.native, daemon: proof.daemon }, participant.verify).kind).toBe("APPLIED");
    await participant.refresh(lease);
    expect(updateVoiceGate({ kind: "COMMIT", lease }, participant.verify).kind).toBe("APPLIED");
  };
  return { gate, lease, identities, ack, calls, deps, participant, commit,
    reply: (value: unknown) => { reply = value; }, exit: () => { exited = true; }, unknownExit: () => { exitUnknown = true; },
    advance: () => { now += 2000; } };
}
test("fresh G3 native and daemon receipts authorize only the matching lease", async () => {
  const f = fixture(); await f.commit();
  expect(f.calls).toEqual(["drain", "drain"]);
  expect(f.participant.verify({ version: 1, kind: "DRAINING", lease: { ...f.lease, generation: 2 } })).toBe(false);
  f.advance();
  expect(f.participant.verify({ version: 1, kind: "DRAINING", lease: f.lease })).toBe(false);
});
test.each(["missing", "generation", "operation", "malformed", "identity"])("%s evidence never authorizes preparation", async fault => {
  const f = fixture();
  const receipt = { kind: "ACKNOWLEDGED", native: f.ack, daemon: f.ack, identities: f.identities };
  if (fault === "missing") f.reply({ kind: "UNKNOWN" });
  if (fault === "generation") f.reply({ ...receipt, daemon: { ...f.ack, lease: { ...f.lease, generation: 2 } } });
  if (fault === "operation") f.reply({ ...receipt, native: { ...f.ack, lease: { ...f.lease, operationId: crypto.randomUUID() } } });
  if (fault === "malformed") f.reply({ ...receipt, native: { ...f.ack, activeOperations: 1 } });
  if (fault === "identity") f.reply({ ...receipt, identities: { ...f.identities, native: { pid: 101, incarnation: "bad" } } });
  try { await f.participant.refresh(f.lease); } catch { /* malformed evidence refuses */ }
  expect(updateVoiceGate({ kind: "PREPARE", lease: f.lease, native: f.ack, daemon: f.ack }, f.participant.verify).kind).toBe("REFUSED");
  expect(existsSync(f.gate + ".voice-diag.json")).toBe(false);
});
test("a replacement participant or process birth cannot reuse a prior receipt", async () => {
  const f = fixture(); await f.participant.refresh(f.lease);
  f.reply({ kind: "ACKNOWLEDGED", native: f.ack, daemon: f.ack, identities: { ...f.identities,
    daemon: { ...f.identities.daemon, incarnation: crypto.randomUUID() } } });
  await expect(f.participant.refresh(f.lease)).rejects.toThrow("UNKNOWN");
  expect(f.participant.verify({ version: 1, kind: "DRAINING", lease: f.lease })).toBe(false);
  const g = fixture(); await g.participant.refresh(g.lease); g.deps.processIdentity = () => "different-birth";
  expect(g.participant.verify({ version: 1, kind: "DRAINING", lease: g.lease })).toBe(false);
});
test("COMMITTED lost reply with verified exit continues under the same held lease", async () => {
  const f = fixture(); await f.commit();
  f.deps.request = async action => { f.calls.push(action); f.exit(); throw Object.assign(Error("disconnected"), { issued: true, replyLost: true }); };
  await f.participant.quit(f.lease);
  expect(f.calls).toEqual(["drain", "drain", "quit"]);
  expect(JSON.parse(readFileSync(f.gate, "utf8")).kind).toBe("COMMITTED");
});
test.each(["alive", "unknown-exit", "foreign-lease", "diagnostic", "ledger", "not-issued", "explicit-refusal"])("lost quit outcome %s stops UNKNOWN and never reopens", async fault => {
  const f = fixture(); await f.commit();
  f.deps.request = async () => {
    if (fault !== "alive") f.exit();
    if (fault === "unknown-exit") f.unknownExit();
    if (fault === "foreign-lease") {
      const state = JSON.parse(readFileSync(f.gate, "utf8")); state.lease.ownerId = crypto.randomUUID();
      state.native.lease = state.lease; state.daemon.lease = state.lease; writeFileSync(f.gate, JSON.stringify(state));
    }
    if (fault === "diagnostic") writeFileSync(f.gate + ".voice-diag.json", "fault");
    if (fault === "ledger") writeFileSync(f.gate + ".admissions/orphan.json", "{}");
    if (fault === "explicit-refusal") return { kind: "REFUSED" };
    throw Object.assign(Error("disconnected"), { issued: fault !== "not-issued", replyLost: true });
  };
  await expect(f.participant.quit(f.lease)).rejects.toThrow("UNKNOWN");
  expect(JSON.parse(readFileSync(f.gate, "utf8")).kind).toBe("COMMITTED");
});
test("even an acknowledged quit requires observed exit; precommit quit is never issued", async () => {
  const f = fixture(); await expect(f.participant.quit(f.lease)).rejects.toThrow("UNKNOWN");
  expect(f.calls).toEqual([]);
  await f.commit();
  await expect(f.participant.quit(f.lease)).rejects.toThrow("UNKNOWN");
});
test("authenticated RPC correlates replies and marks a post-write disconnect as issued", async () => {
  const socketPath = join(process.env.VOICELAYER_TEST_RUN_ROOT!, "i.sock");
  let disconnect = false;
  const server = createServer(socket => {
    socket.once("data", data => {
      const rpc = JSON.parse(data.toString());
      expect(rpc.method).toBe("voicelayer/speech"); expect(rpc.params.token).toBe("synthetic");
      expect(rpc.params.cmd).toBe("update_gate_quit");
      if (disconnect) socket.destroy();
      else socket.end(JSON.stringify({ jsonrpc: "2.0", id: rpc.id, result: { kind: "UNKNOWN" } }) + "\n");
    });
  });
  await new Promise<void>(resolve => server.listen(socketPath, resolve));
  try {
    const lease = fixture().lease;
    expect(await requestInstallerControl("quit", lease, { socketPath, token: "synthetic" })).toEqual({ kind: "UNKNOWN" });
    disconnect = true;
    await expect(requestInstallerControl("quit", lease, { socketPath, token: "synthetic" })).rejects.toMatchObject({ issued: true, replyLost: true });
  } finally { await new Promise<void>(resolve => server.close(() => resolve())); }
});

test("a malformed quit reply cannot be reclassified as a lost reply", async () => {
  const f = fixture(); await f.commit();
  f.deps.request = async () => { f.exit(); throw Object.assign(Error("malformed reply"), { issued: true, replyLost: false }); };
  await expect(f.participant.quit(f.lease)).rejects.toThrow("UNKNOWN");
});

test.each([true, false])("controller installs only after a verified lost-reply exit (%s)", async verified => {
  const { runGatedInstall } = await import("../update-gate-installer");
  const f = fixture();
  // The real controller creates its own lease from OPEN, never this fixture's lease.
  expect(updateVoiceGate({ kind: "CANCEL", lease: f.lease }).kind).toBe("APPLIED");
  const proofPath = f.gate + ".proof", marker = f.gate + ".installed";
  const savedProof = process.env.VOICELAYER_TEST_INSTALL_PROOF, savedTarget = process.env.VOICELAYER_UPDATE_TARGET_SHA;
  process.env.VOICELAYER_UPDATE_TARGET_SHA = "a".repeat(40);
  writeFileSync(proofPath, JSON.stringify({ phase: "idle", ready: true }));
  process.env.VOICELAYER_TEST_INSTALL_PROOF = proofPath;
  let now = 0, exited = false;
  const actions: string[] = [];
  const participant = createInstallerParticipant({
    request: async (action, lease) => {
      actions.push(action);
      if (action === "quit") { exited = verified; throw Object.assign(Error("disconnect"), { issued: true, replyLost: true }); }
      const ack = { lease, activeOperations: 0, openArchives: 0 };
      return { kind: "ACKNOWLEDGED", native: ack, daemon: ack, identities: f.identities };
    },
    processIdentity: pid => exited ? null : `birth-${pid}`,
    participantsExited: () => exited,
    now: () => now, sleep: async () => { now += 100; },
  });
  try {
    const command = [process.execPath, "-e", `await Bun.write(${JSON.stringify(marker)}, 'installed')`];
    // Injected participants require the same live preload capability and proof.
    const run = runGatedInstall(command, participant);
    if (verified) expect(await run).toBe(0); else await expect(run).rejects.toThrow("UNKNOWN");
    expect(existsSync(marker)).toBe(verified);
    expect(actions).toEqual(["drain", "drain", "drain", "quit"]);
    expect(JSON.parse(readFileSync(f.gate, "utf8")).kind).toBe("COMMITTED");
  } finally { process.env.VOICELAYER_TEST_INSTALL_PROOF = savedProof; process.env.VOICELAYER_UPDATE_TARGET_SHA = savedTarget; }
});

test("exit observer refuses replacement owners, PID reuse and unavailable process evidence", async () => {
  const { observeInstallerExit } = await import("../update-gate-installer-participant");
  const f = fixture();
  const proof = { identities: f.identities, native: "native-birth", daemon: "daemon-birth" };
  expect(observeInstallerExit(proof, { identity: () => null, table: () => "123 /usr/bin/other\n" })).toBe(true);
  for (const table of ["123 /Applications/VoiceBar.app/Contents/MacOS/VoiceBar\n", "123 VoiceBar\n"]) {
    expect(observeInstallerExit(proof, { identity: () => null, table: () => table })).toBe("UNKNOWN");
  }
  for (const table of ["", "malformed process row"]) {
    expect(observeInstallerExit(proof, { identity: () => null, table: () => table })).toBe("UNKNOWN");
  }
  expect(observeInstallerExit(proof, { identity: () => "reused-birth", table: () => "" })).toBe("UNKNOWN");
  expect(observeInstallerExit(proof, { identity: pid => pid === 101 ? proof.native : null, table: () => "" })).toBe(false);
  expect(observeInstallerExit(proof, { identity: () => null, table: () => { throw Error("ps failed"); } })).toBe("UNKNOWN");
  expect(observeInstallerExit(proof, { identity: () => { throw Error("permission denied"); }, table: () => "" })).toBe("UNKNOWN");
});

test("time in flight counts against receipt freshness", async () => {
  const f = fixture(), request = f.deps.request;
  f.deps.request = async (action, lease) => { const reply = await request(action, lease); f.advance(); return reply; };
  try { await f.participant.refresh(f.lease); } catch { /* stale receipt may refuse immediately */ }
  expect(updateVoiceGate({ kind: "PREPARE", lease: f.lease, native: f.ack, daemon: f.ack }, f.participant.verify).kind).toBe("REFUSED");
});

test("G3 UNKNOWN after its native disconnect requires verified exit, never an idle assumption", async () => {
  const f = fixture(); await f.commit();
  f.deps.request = async () => { f.exit(); return { kind: "UNKNOWN" }; };
  await f.participant.quit(f.lease);
  expect(JSON.parse(readFileSync(f.gate, "utf8")).kind).toBe("COMMITTED");
  const g = fixture(); await g.commit();
  g.deps.request = async () => ({ kind: "UNKNOWN" });
  await expect(g.participant.quit(g.lease)).rejects.toThrow("UNKNOWN");
});

test("installer RPC consumes G3's authenticated control receipts across an isolated socket", async () => {
  const { createVoiceDrainControl } = await import("../update-gate-native-participant");
  const { createSpeechControl } = await import("../speech-control");
  const { handleMcpRequest } = await import("../mcp-handler");
  const f = fixture(), socketPath = join(process.env.VOICELAYER_TEST_RUN_ROOT!, "g3.sock");
  let exited = false;
  const actions: string[] = [];
  const drain = createVoiceDrainControl({ request: async (lease, action = "drain") => {
    actions.push(action);
    if (action === "quit") exited = true;
    return { lease, action, id: crypto.randomUUID(), pid: f.identities.native.pid, incarnation: f.identities.native.incarnation };
  } }, () => true);
  const control = createSpeechControl("synthetic", () => { throw Error("not media"); }, drain);
  const server = createServer(socket => {
    let buffer = "";
    socket.on("data", data => {
      buffer += data.toString();
      if (!buffer.includes("\n")) return;
      const request = JSON.parse(buffer.slice(0, buffer.indexOf("\n"))); buffer = "";
      void handleMcpRequest(request, undefined, undefined, control).then(reply => socket.end(JSON.stringify(reply) + "\n"));
    });
  });
  await new Promise<void>(resolve => server.listen(socketPath, resolve));
  try {
    const participant = createInstallerParticipant({
      request: (action, lease) => requestInstallerControl(action, lease, { socketPath, token: "synthetic" }),
      processIdentity: pid => exited ? null : `birth-${pid}`,
      participantsExited: () => exited,
      now: () => performance.now(), sleep: () => Bun.sleep(1),
    });
    const proof = await participant.refresh(f.lease);
    expect(proof.ready).toBe(true);
    expect(updateVoiceGate({ kind: "PREPARE", lease: f.lease, native: proof.native, daemon: proof.daemon }, participant.verify).kind).toBe("APPLIED");
    await participant.refresh(f.lease);
    expect(updateVoiceGate({ kind: "COMMIT", lease: f.lease }, participant.verify).kind).toBe("APPLIED");
    await participant.refresh(f.lease);
    await participant.quit(f.lease);
    expect(actions).toEqual(["drain", "drain", "drain", "quit"]);
    expect(JSON.parse(readFileSync(f.gate, "utf8")).kind).toBe("COMMITTED");
  } finally { await new Promise<void>(resolve => server.close(() => resolve())); }
});
