/**
 * c8-M2 round 3 (RM-memory-r2 R2-1): the polish byte budget through a real take lifecycle.
 *
 * The over-budget sample arrives while the take is still transcribing (voice busy). The restart must stay owed,
 * happen once the voice path is idle, happen exactly once, and the next take must be polished by the fresh
 * server. A take arriving while the restart runs waits for it (the polish deadline still bounds that wait).
 * Fake polish processes only; no model.
 */
import { afterEach, describe, expect, it } from "bun:test";
import * as polish from "../stt-polish-server";
import { setRecordingState } from "../recording-state";

const P = polish as unknown as Record<string, any>;

function fakeServers(opts: { stopDelayMs?: number } = {}) {
  const spawned: number[] = [];
  let nextPid = 5000;
  let current = 0;
  let readyChecks = 0;
  const options = {
    env: { QA_VOICE_STT_POLISH: "on" },
    findBinary: () => "/tmp/mlx_lm.server",
    // Answers only while a server process is up (a stopped server does not answer), after one cold check.
    isEndpointReady: async () => current !== 0 && ++readyChecks >= 1,
    findPortOwnerPids: () => (current ? [current] : []),
    startupTimeoutMs: 2_000,
    sleep: (ms: number) => Bun.sleep(Math.min(ms, 5)),
    appendEvent: () => {}, log: () => {},
    probeCacheCaps: async () => true,
    spawn: () => {
      const pid = ++nextPid;
      spawned.push(pid);
      let exit!: (code: number) => void;
      const exited = new Promise<number>(resolve => { exit = resolve; });
      current = pid;
      return {
        pid, exited,
        kill: () => { setTimeout(() => { if (current === pid) current = 0; exit(0); }, opts.stopDelayMs ?? 0); },
        stderr: new ReadableStream<Uint8Array>({ start(c) { c.close(); } }),
      };
    },
  };
  return { options, spawned, currentPid: () => current };
}

async function until(check: () => boolean, ms: number): Promise<boolean> {
  const end = Date.now() + ms;
  while (Date.now() < end) { if (check()) return true; await Bun.sleep(10); }
  return check();
}

afterEach(() => {
  setRecordingState("idle");
  P.setPolishRssProbeForTests?.(null);
  P.setPolishBudgetPollMsForTests?.(null);
  polish.resetSTTPolishServerManagerForTests();
});

describe("c8-M2 r3 polish budget: over budget during a take, restart after it, next take polished", () => {
  it("keeps the restart owed while busy, restarts exactly once when idle, and the next take uses the new server", async () => {
    polish.resetSTTPolishServerManagerForTests();
    P.setPolishBudgetPollMsForTests?.(20);
    const servers = fakeServers();
    let footprint = 2400;
    P.setPolishRssProbeForTests?.(async () => footprint);
    await polish.ensureSTTPolishServer(servers.options);
    expect(servers.spawned).toHaveLength(1);
    // Warm use while idle: the baseline.
    await polish.withSTTPolishServer(async () => "warm", servers.options);
    await Bun.sleep(30);

    // A take is transcribing; its polish leaves the server far over budget.
    setRecordingState("transcribing");
    footprint = 2400 + 1811;
    await polish.withSTTPolishServer(async () => "polished take 1", servers.options);
    await Bun.sleep(150);
    expect(servers.spawned).toHaveLength(1); // never restarted under a busy take

    // The take ends: the owed restart runs once, and the server comes back.
    setRecordingState("idle");
    footprint = 2400;
    expect(await until(() => servers.spawned.length === 2, 2_000)).toBe(true);
    await Bun.sleep(150);
    expect(servers.spawned).toHaveLength(2); // exactly once

    // The next take is polished by the fresh server.
    let usedPid = 0;
    const text = await polish.withSTTPolishServer(async () => { usedPid = servers.currentPid(); return "polished take 2"; }, servers.options);
    expect(text).toBe("polished take 2");
    expect(usedPid).toBe(servers.spawned[1]!);
  });

  it("a take that arrives while the restart runs waits for the new server instead of using the dying one", async () => {
    polish.resetSTTPolishServerManagerForTests();
    P.setPolishBudgetPollMsForTests?.(20);
    const servers = fakeServers({ stopDelayMs: 300 });
    let footprint = 2400;
    P.setPolishRssProbeForTests?.(async () => footprint);
    await polish.ensureSTTPolishServer(servers.options);
    await polish.withSTTPolishServer(async () => "warm", servers.options);
    await Bun.sleep(30);
    footprint = 2400 + 1811;
    await polish.withSTTPolishServer(async () => "big take", servers.options); // idle: restart starts now
    await Bun.sleep(40); // the old server is still stopping (300 ms)
    footprint = 2400;
    let usedPid = -1;
    await polish.withSTTPolishServer(async () => { usedPid = servers.currentPid(); return "next take"; }, servers.options);
    expect(servers.spawned).toHaveLength(2);
    expect(usedPid).toBe(servers.spawned[1]!);
  });
});

describe("c8-M2 r4 polish budget edge paths (RM-memory-r3)", () => {
  it("R3-1 a first use with no warm-up that is already oversized makes a restart owed (baseline = model-only footprint)", async () => {
    polish.resetSTTPolishServerManagerForTests();
    P.setPolishBudgetPollMsForTests?.(20);
    const servers = fakeServers();
    let footprint = 2434; // the settled model, measured after ready and before any request
    P.setPolishRssProbeForTests?.(async () => footprint);
    await polish.ensureSTTPolishServer(servers.options);
    footprint = 2434 + 1811; // the very first polish is a long take
    await polish.withSTTPolishServer(async () => "first, large", servers.options);
    expect(await until(() => servers.spawned.length === 2, 2_000)).toBe(true);
  });

  it("R4-1 launch readings that never agree still give a model-only baseline, so an oversized first use owes a restart", async () => {
    polish.resetSTTPolishServerManagerForTests();
    P.setPolishBudgetPollMsForTests?.(20);
    const servers = fakeServers();
    let reads = 0;
    let used = false;
    P.setPolishRssProbeForTests?.(async () => (used ? 4245 : reads++ % 2 === 0 ? 2400 : 2440));
    const options = { ...servers.options, sleep: async () => {} };
    await polish.ensureSTTPolishServer(options);
    expect(reads).toBeGreaterThanOrEqual(40);
    used = true;
    await polish.withSTTPolishServer(async () => "first, large", options);
    expect(await until(() => servers.spawned.length === 2, 2_000)).toBe(true);
  });

  it("R3-2 an owed restart superseded by polish Off (or shutdown) is abandoned, never relaunched", async () => {
    polish.resetSTTPolishServerManagerForTests();
    P.setPolishBudgetPollMsForTests?.(20);
    let enabled = true;
    P.setPolishEnabledProbeForTests?.(() => enabled);
    const servers = fakeServers({ stopDelayMs: 200 });
    let footprint = 2434;
    P.setPolishRssProbeForTests?.(async () => footprint);
    await polish.ensureSTTPolishServer(servers.options);
    await polish.withSTTPolishServer(async () => "warm", servers.options);
    await Bun.sleep(30);
    footprint = 2434 + 1811;
    await polish.withSTTPolishServer(async () => "big", servers.options); // idle: the restart starts stopping
    await Bun.sleep(40);
    // He turns polish Off while the budget stop is in flight: Settings saves Off and stops the server too.
    enabled = false;
    void polish.stopSTTPolishServerAndWait().catch(() => {});
    await Bun.sleep(600);
    expect(servers.spawned).toHaveLength(1);
    expect(servers.currentPid()).toBe(0);
    P.setPolishEnabledProbeForTests?.(null);
  });

  it("R3-3 a failed unload settles the restart: a waiting take proceeds, and a later use gets a fresh server", async () => {
    polish.resetSTTPolishServerManagerForTests();
    P.setPolishBudgetPollMsForTests?.(20);
    let stuck = true;
    const exits: Array<() => void> = [];
    const servers = fakeServers();
    const spawn = servers.options.spawn;
    servers.options.spawn = () => {
      const child = spawn();
      let exit!: () => void;
      // Exiting also stops the fake listener (a dead server no longer owns the port).
      const exited = new Promise<number>(resolve => { exit = () => { child.kill(); resolve(0); }; });
      exits.push(exit);
      return { ...child, exited, kill: () => { if (!stuck) exit(); } }; // ignores TERM and KILL while stuck
    };
    let footprint = 2434;
    P.setPolishRssProbeForTests?.(async () => footprint);
    await polish.ensureSTTPolishServer(servers.options);
    await polish.withSTTPolishServer(async () => "warm", servers.options);
    await Bun.sleep(30);
    footprint = 2434 + 1811;
    await polish.withSTTPolishServer(async () => "big", servers.options); // restart starts; the unload will fail
    await Bun.sleep(20);
    const waiter = polish.withSTTPolishServer(async () => "waiting take", { ...servers.options, loadOnDemand: false });
    const result = await Promise.race([waiter, Bun.sleep(8_000).then(() => "HUNG")]);
    expect(result).toBe("waiting take");
    // The wedged server finally exits; the next use gets a fresh one.
    stuck = false; for (const exit of exits) exit();
    footprint = 2434;
    await Bun.sleep(50);
    await polish.withSTTPolishServer(async () => "next", servers.options);
    expect(servers.spawned.length).toBeGreaterThanOrEqual(2);
  }, 20_000);
});
