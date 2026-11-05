// G5: these pre-completion fixtures retain COMMITTED; child exit 0 alone returns refusal (1).
import { afterEach, expect, test } from "bun:test";
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, existsSync, rmdirSync } from "node:fs";
import { join } from "node:path";
import { createInstallerParticipant, requestInstallerControl, type InstallerParticipantDependencies } from "../update-gate-installer-participant";
import { acknowledgeVoiceDrain, updateVoiceGate } from "../update-gate-admission";
import { type UpdateGateLease } from "../update-gate";
import { createServer } from "node:net";

const originalGate = process.env.VOICELAYER_UPDATE_GATE_PATH;
const PROCESS_READ_MS = 15;
// M4 baseline/stress8 cases <=3.53s; hosted case timed out at 14.243s.
// 14.243s * 1.5 margin = 21.365s, rounded up for this process-reader fixture.
const SLOW_PROCESS_READERS_TEST_TIMEOUT_MS = 30_000;
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
    processIdentity: pid => exited ? null : pid === 101 ? "birth /Applications/VoiceBar.app/Contents/MacOS/VoiceBar" : "birth /opt/homebrew/bin/bun",
    processParent: () => 101,
    participantsExited: () => exitUnknown ? "UNKNOWN" : exited,
    now: () => now,
    sleep: async () => { now += 100; },
  };
  expect(updateVoiceGate({ kind: "REQUEST", lease }).kind).toBe("APPLIED");
  const participant = createInstallerParticipant(deps);
  const commit = async () => {
    const proof = await participant.refresh(lease);
    expect(proof.ready).toBe(true);
    expect(participant.withProcessProof!(() => updateVoiceGate({ kind: "PREPARE", lease, native: proof.native, daemon: proof.daemon }, participant.verify)).kind).toBe("APPLIED");
    await participant.refresh(lease);
    expect(participant.withProcessProof!(() => updateVoiceGate({ kind: "COMMIT", lease }, participant.verify)).kind).toBe("APPLIED");
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
  expect(() => g.participant.withProcessProof!(() => g.participant.verify({ version: 1, kind: "DRAINING", lease: g.lease }))).toThrow("UNKNOWN");
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

test.each([
  { verified: true, contention: "none" }, { verified: false, contention: "none" },
  { verified: true, contention: "quit-authorization" }, { verified: true, contention: "exit-verification" },
])("controller installs only after verified exit (%j)", async ({ verified, contention }) => {
  const { runGatedInstall } = await import("../update-gate-installer");
  const f = fixture();
  // The real controller creates its own lease from OPEN, never this fixture's lease.
  expect(updateVoiceGate({ kind: "CANCEL", lease: f.lease }).kind).toBe("APPLIED");
  const proofPath = f.gate + ".proof", marker = f.gate + ".installed";
  const savedProof = process.env.VOICELAYER_TEST_INSTALL_PROOF, savedTarget = process.env.VOICELAYER_UPDATE_TARGET_SHA;
  process.env.VOICELAYER_UPDATE_TARGET_SHA = "a".repeat(40);
  writeFileSync(proofPath, JSON.stringify({ phase: "idle", ready: true }));
  process.env.VOICELAYER_TEST_INSTALL_PROOF = proofPath;
  let now = 0, exited = false, ownedLock = false;
  const hold = () => { mkdirSync(f.gate + ".lock"); ownedLock = true; };
  const actions: string[] = [];
  const participant = createInstallerParticipant({
    request: async (action, lease) => {
      actions.push(action);
      if (action === "quit") {
        if (contention === "exit-verification") hold();
        exited = verified; throw Object.assign(Error("disconnect"), { issued: true, replyLost: true });
      }
      if (contention === "quit-authorization" && JSON.parse(readFileSync(f.gate, "utf8")).kind === "COMMITTED") hold();
      const ack = { lease, activeOperations: 0, openArchives: 0 };
      return { kind: "ACKNOWLEDGED", native: ack, daemon: ack, identities: f.identities };
    },
    processIdentity: pid => exited ? null : pid === f.identities.native.pid ? "birth /Applications/VoiceBar.app/Contents/MacOS/VoiceBar" : "birth /opt/homebrew/bin/bun",
    processParent: () => f.identities.native.pid,
    participantsExited: () => exited,
    now: () => now, sleep: async () => {
      now += 100;
      if (ownedLock) { rmdirSync(f.gate + ".lock"); ownedLock = false; }
    },
  });
  try {
    const command = [process.execPath, "-e", `await Bun.write(${JSON.stringify(marker)}, 'installed')`];
    // Injected participants require the same live preload capability and proof.
    const run = runGatedInstall(command, participant);
    if (verified) expect(await run).toBe(1); else await expect(run).rejects.toThrow("UNKNOWN");
    expect(existsSync(marker)).toBe(verified);
    expect(actions).toEqual(["drain", "drain", "drain", "quit"]);
    expect(JSON.parse(readFileSync(f.gate, "utf8")).kind).toBe("COMMITTED");
  } finally {
    if (ownedLock) rmdirSync(f.gate + ".lock");
    process.env.VOICELAYER_TEST_INSTALL_PROOF = savedProof; process.env.VOICELAYER_UPDATE_TARGET_SHA = savedTarget;
  }
});

test("exit observer refuses replacement owners, PID reuse and unavailable process evidence", async () => {
  const { observeInstallerExit } = await import("../update-gate-installer-participant");
  const f = fixture();
  const proof = { identities: f.identities, native: "native-birth", daemon: "daemon-birth" };
  expect(observeInstallerExit(proof, { identity: () => null, table: () => "123 /usr/bin/other\n" })).toBe(true);
  for (const table of ["123 /Applications/VoiceBar.app/Contents/MacOS/VoiceBar\n", "123 VoiceBar\n"]) {
    expect(observeInstallerExit(proof, { identity: () => null, table: () => table })).toBe("UNSAFE");
  }
  for (const table of ["", "malformed process row"]) {
    expect(observeInstallerExit(proof, { identity: () => null, table: () => table })).toBe("UNKNOWN");
  }
  expect(observeInstallerExit(proof, { identity: () => "reused-birth", table: () => "" })).toBe("UNSAFE");
  expect(observeInstallerExit(proof, { identity: pid => pid === 101 ? proof.native : null, table: () => "123 /usr/bin/other\n" })).toBe(false);
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
      processIdentity: pid => exited ? null : pid === f.identities.native.pid ? "birth /Applications/VoiceBar.app/Contents/MacOS/VoiceBar" : "birth /opt/homebrew/bin/bun",
      processParent: () => f.identities.native.pid,
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

// G4 Claude fix round: all paths use the preload's private gate and synthetic processes.
test.each(["quit-authorization", "exit-verification"])("post-COMMIT %s lock contention waits without repeating quit", async moment => {
  const f = fixture(); await f.commit();
  let owned = false, sleeps = 0;
  const hold = () => { mkdirSync(f.gate + ".lock"); owned = true; };
  if (moment === "quit-authorization") hold();
  f.deps.request = async action => {
    f.calls.push(action);
    if (moment === "exit-verification") hold();
    f.exit(); return { kind: "UNKNOWN" };
  };
  f.deps.sleep = async () => {
    sleeps++; if (owned) { rmdirSync(f.gate + ".lock"); owned = false; }
  };
  try {
    await f.participant.quit(f.lease);
    expect(sleeps).toBeGreaterThan(0);
    expect(f.calls.filter(action => action === "quit")).toHaveLength(1);
    expect(existsSync(f.gate + ".voice-diag.json")).toBe(false);
  } finally { if (owned) rmdirSync(f.gate + ".lock"); }
});

test("post-COMMIT drain UNKNOWN is retried before one quit and installation", async () => {
  const { runGatedInstall } = await import("../update-gate-installer");
  const f = fixture(); updateVoiceGate({ kind: "CANCEL", lease: f.lease });
  const savedProof = process.env.VOICELAYER_TEST_INSTALL_PROOF, savedTarget = process.env.VOICELAYER_UPDATE_TARGET_SHA;
  process.env.VOICELAYER_TEST_INSTALL_PROOF = f.gate + ".proof";
  process.env.VOICELAYER_UPDATE_TARGET_SHA = "a".repeat(40);
  writeFileSync(process.env.VOICELAYER_TEST_INSTALL_PROOF, JSON.stringify({ phase: "idle", ready: true }));
  const marker = f.gate + ".installed";
  let committedRefreshes = 0, quits = 0, ready = false;
  try {
    const result = await runGatedInstall([process.execPath, "-e", `await Bun.write(${JSON.stringify(marker)}, 'installed')`], {
      async refresh(lease) {
        const committed = JSON.parse(readFileSync(f.gate, "utf8")).kind === "COMMITTED";
        ready = !committed || ++committedRefreshes >= 3;
        const ack = { lease, activeOperations: 0 as const, openArchives: 0 as const };
        return { phase: ready ? "idle" : "waiting for live participants", ready, ...(ready ? { native: ack, daemon: ack } : {}) };
      },
      verify: () => ready,
      async quit() { quits++; if (!ready) throw Error("UNKNOWN: not refreshed"); },
    });
    expect(result).toBe(1); expect(existsSync(marker)).toBe(true);
    expect(committedRefreshes).toBe(3); expect(quits).toBe(1);
  } finally { process.env.VOICELAYER_TEST_INSTALL_PROOF = savedProof; process.env.VOICELAYER_UPDATE_TARGET_SHA = savedTarget; }
});

test("slow process readers stay outside G1 lock and its 2 ms verifier budget", async () => {
  const f = fixture(), read = f.deps.processIdentity;
  let readsUnderLock = 0, maximumVerifierMs = 0;
  f.deps.processIdentity = pid => {
    if (existsSync(f.gate + ".lock")) readsUnderLock++;
    Bun.sleepSync(15); return read(pid);
  };
  const verify = f.participant.verify;
  f.participant.verify = state => {
    const start = performance.now(), result = verify(state);
    maximumVerifierMs = Math.max(maximumVerifierMs, performance.now() - start);
    return result;
  };
  await f.commit();
  // Measure the entire acknowledgement call (including acquisition/snapshot/release),
  // excluding only the deliberately slow process samples bracketing it.
  const windows: number[] = [];
  for (let i = 0; i < 25; i++) {
    await f.participant.refresh(f.lease);
    f.participant.withProcessProof!(() => {
      const start = performance.now();
      const ack = acknowledgeVoiceDrain(f.lease, f.participant.verify);
      windows.push(performance.now() - start);
      expect(ack).not.toBeNull();
    });
  }
  windows.sort((a, b) => a - b);
  // The property: no 15 ms process read runs inside the acknowledgement window.
  // Half of one read (7.5 ms) still catches a single read moving inside, while a
  // tight 2 ms wall-clock bound failed on a loaded dev Mac (2.2-3.0 ms, #673).
  expect(windows[12]).toBeLessThan(PROCESS_READ_MS / 2);
  expect(windows[24]).toBeLessThan(50);
  f.deps.request = async () => { f.exit(); return { kind: "UNKNOWN" }; };
  f.deps.participantsExited = () => {
    if (existsSync(f.gate + ".lock")) readsUnderLock++;
    Bun.sleepSync(15); return true;
  };
  await f.participant.quit(f.lease);
  expect(readsUnderLock).toBe(0);
  expect(maximumVerifierMs).toBeLessThan(2);
}, SLOW_PROCESS_READERS_TEST_TIMEOUT_MS);

test("same-birth defunct participant waits for reaping under the exit deadline", async () => {
  const { observeInstallerExit } = await import("../update-gate-installer-participant");
  const f = fixture(); await f.commit();
  const birth = "Sat Oct 31 09:10:11 2026";
  const proof = { identities: f.identities, native: `${birth} /Applications/VoiceBar.app/Contents/MacOS/VoiceBar`, daemon: `${birth} /opt/homebrew/bin/bun` };
  let polls = 0;
  f.deps.request = async () => ({ kind: "UNKNOWN" });
  f.deps.participantsExited = () => observeInstallerExit(proof, {
    identity: pid => ++polls <= 2 && pid === f.identities.daemon.pid ? `${birth} <defunct>` : null,
    table: () => "123 /usr/bin/other\n",
  });
  await f.participant.quit(f.lease);
  expect(polls).toBeGreaterThan(2);
  expect(observeInstallerExit(proof, { identity: () => "Fri Oct 30 09:10:11 2026 <defunct>", table: () => "" })).toBe("UNSAFE");
});

test.each(["empty-ps", "unreaped", "teardown", "defunct"])("healthy quit polls through %s before verified exit", async observation => {
  const { observeInstallerExit } = await import("../update-gate-installer-participant");
  const f = fixture(); await f.commit();
  const birth = "Sat Oct 31 09:10:11 2026";
  const proof = { identities: f.identities, native: `${birth} /Applications/VoiceBar.app/Contents/MacOS/VoiceBar`, daemon: `${birth} /opt/homebrew/bin/bun` };
  let samples = 0, sleeps = 0;
  f.deps.request = async () => ({ kind: "UNKNOWN" });
  f.deps.sleep = async () => { sleeps++; };
  f.deps.participantsExited = () => {
    const exiting = samples++ < 2;
    return observeInstallerExit(proof, {
      identity: pid => {
        if (!exiting) return null;
        if (observation === "empty-ps") throw Error("UNKNOWN: participant process identity unavailable");
        if (observation === "defunct") return `${birth} <defunct>`;
        return `${birth} (${pid === 101 ? "VoiceBar" : "bun"})`;
      },
      table: () => "123 /usr/bin/other\n",
    });
  };
  await f.participant.quit(f.lease);
  expect(sleeps).toBe(1);
  expect(samples).toBe(4);
  expect(JSON.parse(readFileSync(f.gate, "utf8")).kind).toBe("COMMITTED");
});

test("every exit poll rechecks the held COMMITTED lease before accepting gone", async () => {
  const f = fixture(); await f.commit();
  let polls = 0;
  f.deps.request = async () => ({ kind: "UNKNOWN" });
  f.deps.participantsExited = () => ++polls <= 2 ? "UNKNOWN" : true;
  f.deps.sleep = async () => {
    const state = JSON.parse(readFileSync(f.gate, "utf8"));
    state.kind = "OPEN"; state.generation = 1; state.released = f.lease;
    delete state.lease; delete state.native; delete state.daemon;
    writeFileSync(f.gate, JSON.stringify(state));
  };
  await expect(f.participant.quit(f.lease)).rejects.toThrow("held lease");
  expect(polls).toBe(4);
});

test("uncertain exit exhausts its deadline and names availability recovery", async () => {
  const f = fixture(); await f.commit();
  let sleeps = 0;
  f.deps.request = async () => ({ kind: "UNKNOWN" });
  f.deps.participantsExited = () => "UNKNOWN";
  f.deps.sleep = async () => { sleeps++; f.advance(); };
  await expect(f.participant.quit(f.lease)).rejects.toThrow("successor verifies abandoned COMMITTED recovery automatically");
  expect(sleeps).toBe(3);
  expect(JSON.parse(readFileSync(f.gate, "utf8")).kind).toBe("COMMITTED");
});

test("empty ps while the pid exists is unavailable identity, never gone", async () => {
  const { installerProcessIdentity } = await import("../update-gate-installer-participant");
  const sample = () => ({ exitCode: 1, stdout: "" });
  expect(() => installerProcessIdentity(101, { sample, exists: () => true })).toThrow("identity unavailable");
  expect(installerProcessIdentity(101, { sample, exists: () => false })).toBeNull();
  expect(() => installerProcessIdentity(101, { sample, exists: () => { throw Error("EPERM"); } })).toThrow("EPERM");
});

test.each(["reuse", "competitor"])("%s refuses immediately even during uncertain teardown", async fault => {
  const { observeInstallerExit } = await import("../update-gate-installer-participant");
  const f = fixture(); await f.commit();
  const proof = { identities: f.identities, native: "native-birth", daemon: "daemon-birth" };
  let sleeps = 0;
  f.deps.request = async () => ({ kind: "UNKNOWN" });
  f.deps.sleep = async () => { sleeps++; };
  f.deps.participantsExited = () => observeInstallerExit(proof, {
    identity: pid => {
      if (pid === 101) throw Error("identity unavailable");
      return fault === "reuse" ? "birth /usr/bin/other" : proof.daemon;
    },
    table: () => "999 /Applications/VoiceBar.app/Contents/MacOS/VoiceBar\n",
  });
  await expect(f.participant.quit(f.lease)).rejects.toThrow("PID reused or competing VoiceBar");
  expect(sleeps).toBe(0);
});

test("stale receipt never pins identities for a later fresh drain", async () => {
  const f = fixture(), request = f.deps.request;
  f.deps.request = async (action, lease) => { const reply = await request(action, lease); f.advance(); return reply; };
  await expect(f.participant.refresh(f.lease)).rejects.toThrow("stale");
  f.deps.request = request;
  f.reply({ kind: "ACKNOWLEDGED", native: f.ack, daemon: f.ack, identities: {
    ...f.identities, daemon: { ...f.identities.daemon, incarnation: crypto.randomUUID() },
  } });
  expect((await f.participant.refresh(f.lease)).ready).toBe(true);
});

test("installer rejects native impostors and daemons outside the native process family", async () => {
  const f = fixture(); f.deps.processIdentity = pid => `birth /usr/bin/impostor-${pid} VoiceBar`;
  await expect(f.participant.refresh(f.lease)).rejects.toThrow("UNKNOWN");
  const g = fixture();
  g.deps.processIdentity = pid => pid === 101 ? "birth /Applications/VoiceBar.app/Contents/MacOS/VoiceBar" : "birth /opt/homebrew/bin/bun";
  g.deps.processParent = () => 999;
  await expect(g.participant.refresh(g.lease)).rejects.toThrow("UNKNOWN");
});

test("production installer refuses MCP socket overrides before opening a connection", async () => {
  const module = await import("../update-gate-installer-participant");
  expect(typeof module.assertInstallerSocketPath).toBe("function");
  const check = module.assertInstallerSocketPath;
  expect(() => check({})).not.toThrow();
  for (const env of [{ VOICELAYER_MCP_SOCKET_PATH: "/tmp/foreign.sock" }, { QA_VOICE_MCP_SOCKET_PATH: "/tmp/foreign.sock" }, { VOICELAYER_TMP_ROOT: "/tmp/foreign" }]) {
    expect(() => check(env)).toThrow("noncanonical MCP socket");
  }
});

test("installer docs disclose that native receipts rely on the daemon HMAC verification", () => {
  for (const path of ["docs/update-gate-installers.md", "docs/update-gate-admission.md"]) {
    const text = readFileSync(path, "utf8");
    expect(text).toContain("installer trusts the daemon");
    expect(text).toContain("HMAC-verified native ACK");
  }
});

test("R1 acquisition never samples identities after its durable COMMIT write", async () => {
  const f = fixture(), proof = await f.participant.refresh(f.lease);
  expect(updateVoiceGate({ kind: "PREPARE", lease: f.lease, native: proof.native, daemon: proof.daemon }, f.participant.verify).kind).toBe("APPLIED");
  const identity = f.deps.processIdentity;
  f.deps.processIdentity = pid => {
    if (JSON.parse(readFileSync(f.gate, "utf8")).kind === "COMMITTED") throw Error("postcommit identity sample forbidden");
    return identity(pid);
  };
  const result = await f.participant.withAcquisitionProof!(() => updateVoiceGate({ kind: "COMMIT", lease: f.lease }, f.participant.verify));
  expect(result.kind).toBe("APPLIED");
  expect(JSON.parse(readFileSync(f.gate, "utf8")).kind).toBe("COMMITTED");
  expect(existsSync(f.gate + ".lock")).toBe(false);
});

for (const delay of [960, 1200]) test(`R2 durable COMMIT at +${delay}ms outlives its sample budget`, async () => {
  const f = fixture(); let now = 0; f.deps.now = () => now;
  const proof = await f.participant.refresh(f.lease);
  expect(updateVoiceGate({ kind: "PREPARE", lease: f.lease, native: proof.native, daemon: proof.daemon }, f.participant.verify).kind).toBe("APPLIED");
  const result = await f.participant.withAcquisitionProof!(() => {
    const result = updateVoiceGate({ kind: "COMMIT", lease: f.lease }, f.participant.verify);
    now = delay; return result;
  });
  expect(result.kind).toBe("APPLIED");
  expect(JSON.parse(readFileSync(f.gate, "utf8")).kind).toBe("COMMITTED");
});

test("R2 participant COMMIT readback retries a 700ms holder without a post-sample", async () => {
  const f = fixture(), proof = await f.participant.refresh(f.lease);
  expect(updateVoiceGate({ kind: "PREPARE", lease: f.lease, native: proof.native, daemon: proof.daemon }, f.participant.verify).kind).toBe("APPLIED");
  f.deps.sleep = ms => Bun.sleep(ms ?? 100);
  const result = await f.participant.withAcquisitionProof!(() => {
    const result = updateVoiceGate({ kind: "COMMIT", lease: f.lease }, f.participant.verify);
    mkdirSync(f.gate + ".lock"); setTimeout(() => rmdirSync(f.gate + ".lock"), 700);
    f.deps.processIdentity = () => { throw Error("postcommit sample forbidden"); };
    return result;
  });
  expect(result.kind).toBe("APPLIED");
  expect(existsSync(f.gate + ".lock")).toBe(false);
});

test.each(["new", "old-native", "old-daemon", "old-birth", "wrong-bundle", "dead", "stale"])("G5 successor proof: %s", async fault => {
  const f = fixture(); await f.commit();
  const successor = f.participant.successor!();
  const identities = { native: { pid: 201, incarnation: crypto.randomUUID() }, daemon: { pid: 202, incarnation: crypto.randomUUID() } };
  if (fault === "old-native") identities.native.incarnation = f.identities.native.incarnation;
  if (fault === "old-daemon") identities.daemon.incarnation = f.identities.daemon.incarnation;
  if (fault === "old-birth") { identities.native.pid = 101; identities.native.incarnation = crypto.randomUUID(); }
  f.reply({ kind: "ACKNOWLEDGED", native: f.ack, daemon: f.ack, identities });
  f.deps.processParent = () => identities.native.pid;
  f.deps.processIdentity = pid => fault === "dead" ? null : pid === identities.native.pid
    ? `${fault === "old-birth" ? "birth" : "Tue Nov  3 15:54:30 2026"} /${fault === "wrong-bundle" ? "tmp/Copy.app" : "Applications/VoiceBar.app"}/Contents/MacOS/VoiceBar` : "birth /opt/homebrew/bin/bun";
  if (fault === "stale") { const request = f.deps.request; f.deps.request = async (action, lease) => { const reply = await request(action, lease); f.advance(); return reply; }; }
  if (fault === "new") {
    expect((await successor.refresh(f.lease)).ready).toBe(true);
    expect(successor.verify(JSON.parse(readFileSync(f.gate, "utf8")))).toBe(true);
    f.advance(); expect(successor.verify(JSON.parse(readFileSync(f.gate, "utf8")))).toBe(false);
  } else {
    await expect(successor.refresh(f.lease)).rejects.toThrow("UNKNOWN");
    expect(successor.verify(JSON.parse(readFileSync(f.gate, "utf8")))).toBe(false);
  }
});

test("G5 completion samples identities before publication and never after OPEN", async () => {
  const f = fixture(); await f.commit();
  const successor = f.participant.successor!();
  const identities = { native: { pid: 201, incarnation: crypto.randomUUID() }, daemon: { pid: 202, incarnation: crypto.randomUUID() } };
  f.reply({ kind: "ACKNOWLEDGED", native: f.ack, daemon: f.ack, identities });
  f.deps.processParent = () => 201;
  f.deps.processIdentity = pid => {
    if (JSON.parse(readFileSync(f.gate, "utf8")).kind === "OPEN") throw Error("post-COMPLETE identity sample forbidden");
    expect(existsSync(f.gate + ".lock")).toBe(false);
    return "Tue Nov  3 15:54:30 2026 " + (pid === 201 ? "/Applications/VoiceBar.app/Contents/MacOS/VoiceBar" : "/opt/homebrew/bin/bun");
  };
  await successor.refresh(f.lease);
  const result = await successor.withCompletionProof!(() => updateVoiceGate({ kind: "COMPLETE", lease: f.lease,
    installerExitCode: 0, installedSha: f.lease.targetSha, participantsVerified: true }, successor.verify));
  expect(result.kind).toBe("APPLIED");
  expect(JSON.parse(readFileSync(f.gate, "utf8")).kind).toBe("OPEN");
});
